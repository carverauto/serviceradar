//! Internal module for seeding the hash functions.
//!
//! Located here instead of `util` to make use of the non-portable mix functions.

/// Don't want to have a recursive import here, so we copy it...
const DEFAULT_SECRETS: [u64; 7] = [
    0x2d358dccaa6c78a5,
    0x8bb84b93962eacc9,
    0x4b33a62ed433d4a3,
    0x4d5a2da51de1aa47,
    0xa0761d6478bd642f,
    0xe7037ed1a0b428db,
    0x90ed1765281c388c,
];

pub(crate) mod seed {
    use crate::inner::mix_np::rapid_mix_np;
    use super::DEFAULT_SECRETS;

    #[inline]
    pub fn get_seed() -> u64 {
        // this would all be so much easier if the rust std exposed how it does RandomState
        // we take the stack pointer as a rather poor but cheap source of entropy
        let mut seed = 0;
        let arbitrary = core::ptr::addr_of!(seed) as u64;

        // with std we avoid using global atomics
        #[cfg(feature = "std")] {
            use core::cell::Cell;

            thread_local! {
                static RANDOM_SEED: Cell<u64> = const {
                    Cell::new(0)
                }
            }

            seed = RANDOM_SEED.with(|cell| {
                let mut seed = cell.get();
                seed = rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[1], arbitrary ^ DEFAULT_SECRETS[0]);
                cell.set(seed);
                seed
            });
        }

        // without std we fall back to a global atomic and accept the chance of
        // race conditions, but don't consider this an issue
        //
        // Most targets without atomics can still do atomic load/store, but just can't
        // do atomic compare-and-swap instructions. So this should still compile/work...
        #[cfg(not(feature = "std"))] {
            use core::sync::atomic::{AtomicUsize, Ordering};
            static RANDOM_SEED: AtomicUsize = AtomicUsize::new(0);

            seed = RANDOM_SEED.load(Ordering::Relaxed) as u64;
            seed = rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[1], arbitrary ^ DEFAULT_SECRETS[0]);
            RANDOM_SEED.store(seed as usize, Ordering::Relaxed);
        }

        seed ^ rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[2], DEFAULT_SECRETS[1])
    }

    #[cfg(test)]
    mod tests {
        use super::get_seed;

        #[test]
        fn test_get_seed() {
            let seed1 = get_seed();
            let seed2 = get_seed();
            assert_ne!(seed1, seed2, "get_seed should return different values on subsequent calls");
        }
    }
}

#[cfg(not(target_has_atomic = "ptr"))]
pub(crate) mod secrets {
    #[inline(always)]
    pub fn get_secrets() -> &'static [u64; 7] {
        // This is a no-op for platforms that do not support atomic pointers.
        // The secrets are not used, so we return an empty slice.
        &crate::inner::seed::DEFAULT_RAPID_SECRETS.secrets
    }

    #[derive(Copy, Clone, Debug, Eq, PartialEq)]
    pub struct GlobalSecrets {
        _only_uses_default_secrets: (),
    }

    impl GlobalSecrets {
        /// Set up the global secrets if they are not already initialized.
        #[inline(always)]
        pub fn new() -> Self {
            Self {
                _only_uses_default_secrets: (),
            }
        }

        /// Get the global secrets, which are guaranteed to be initialized, but these will
        /// be the default rapidhash secrets as this target does not support atomic pointers.
        #[inline(always)]
        pub fn get(self) -> &'static [u64; 7] {
            get_secrets()
        }

        /// Get the fixed seed, which is guaranteed to be initialized.
        #[inline(always)]
        pub fn get_global_seed(self) -> u64 {
            // rapidhash v1 seed as default
            0xbdd89aa982704029
        }
    }
}

#[cfg(target_has_atomic = "ptr")]
pub(crate) mod secrets {
    use core::cell::UnsafeCell;
    use core::sync::atomic::{AtomicUsize, Ordering};
    use crate::util::mix::rapid_mix;
    use super::DEFAULT_SECRETS;

    /// A hacky sync-friendly, std-free, OnceCell that sadly needs unsafe inspired by foldhash's
    /// `seed.rs` which includes some similar bodges.
    struct SecretStorage {
        state: AtomicUsize,
        seed: UnsafeCell<u64>,
        secrets: UnsafeCell<[u64; 7]>,
    }

    unsafe impl Sync for SecretStorage {}

    static SECRET_STORAGE: SecretStorage = SecretStorage {
        state: AtomicUsize::new(0),
        seed: UnsafeCell::new(0),
        secrets: UnsafeCell::new([0; 7]),
    };

    enum SecretStorageStates {
        Uninitialized = 0,
        Initializing = 1,
        Initialized = 2,
    }

    #[derive(Copy, Clone, Debug, Eq, PartialEq)]
    pub struct GlobalSecrets {
        _private: (),
    }

    impl GlobalSecrets {
        /// Set up the global secrets if they are not already initialized.
        #[inline(always)]
        pub fn new() -> Self {
            if SECRET_STORAGE.state.load(Ordering::Acquire) != SecretStorageStates::Initialized as usize {
                initialize_secrets();
            }

            Self { _private: () }
        }

        /// Get the global secrets, which are guaranteed to be initialized.
        #[inline(always)]
        pub fn get(self) -> &'static [u64; 7] {
            // SAFETY: The secrets are guaranteed to be initialized before being accessed
            // as we cannot construct this struct without first calling `new()`
            unsafe { &*SECRET_STORAGE.secrets.get() }
        }

        /// Get the fixed seed, which is guaranteed to be initialized.
        #[inline(always)]
        pub fn get_global_seed(self) -> u64 {
            // SAFETY: The secrets are guaranteed to be initialized before being accessed
            // as we cannot construct this struct without first calling `new()`
            unsafe { *SECRET_STORAGE.seed.get() }
        }
    }

    /// Get the global secrets, slow(ish).
    ///
    /// Short for `GlobalSecrets::new().get()`.
    #[inline(always)]
    pub fn get_secrets() -> &'static [u64; 7] {
        GlobalSecrets::new().get()
    }

    #[cold]
    #[inline(never)]
    fn initialize_secrets() {
        let seed = generate_random();
        let secrets = create_secrets(seed);

        const INITIALIZED: usize = SecretStorageStates::Initialized as usize;

        loop {
            match SECRET_STORAGE.state.compare_exchange_weak(
                SecretStorageStates::Uninitialized as usize,
                SecretStorageStates::Initializing as usize,
                Ordering::Acquire,
                Ordering::Acquire,
            ) {
                // This thread is the first to initialize, so we can safely set the secrets
                Ok(_) => {
                    unsafe {
                        *SECRET_STORAGE.seed.get() = seed;
                        *SECRET_STORAGE.secrets.get() = secrets;
                    }
                    SECRET_STORAGE.state.store(SecretStorageStates::Initialized as usize, Ordering::Release);
                    break;
                }

                // Another thread has initialized for us, so we're done.
                Err(INITIALIZED) => {
                    return;
                }

                // We are spinning here until the other thread is done initializing. This should
                // be very fast, as the initializing thread should only be copying the already
                // generated secrets for a few instructions.
                _ => core::hint::spin_loop(),
            }
        }
    }

    fn create_secrets(mut seed: u64) -> [u64; 7] {
        let mut secrets = [0u64; 7];

        for i in 0..secrets.len() {
            const HI: u64 = 0xFFFF << 48;
            const MI: u64 = 0xFFFF << 24;
            const LO: u64 = 0xFFFF;

            seed = rapid_mix::<true>(seed ^ DEFAULT_SECRETS[0], DEFAULT_SECRETS[i]);

            // ensure at least one high, middle, and low bit is set for a semi-decent secret
            if (seed & HI) == 0 {
                seed |= 1u64 << 63;
            }

            if (seed & MI) == 0 {
                seed |= 1u64 << 31;
            }

            if (seed & LO) == 0 {
                seed |= 1u64;
            }

            secrets[i] = seed;
        }

        secrets
    }

    /// Generate a random number, trying our best to make this a good random number.
    ///
    /// To only be called sparingly as it's fairly slow.
    pub fn generate_random() -> u64 {
        #[cfg(feature = "rand")]
        {
            rand::random()
        }

        #[cfg(not(feature = "rand"))]
        {
            // trying out best to generate a good random number on all platforms
            let mut seed = DEFAULT_SECRETS[0];
            let stack_ptr = core::ptr::addr_of!(seed) as u64;
            let static_ptr = &DEFAULT_SECRETS as *const _ as usize as u64;
            let function_ptr = generate_random as *const () as usize as u64;

            seed = rapid_mix::<true>(seed ^ DEFAULT_SECRETS[4], stack_ptr ^ DEFAULT_SECRETS[1]);
            seed = rapid_mix::<true>(seed ^ DEFAULT_SECRETS[5], function_ptr ^ DEFAULT_SECRETS[2]);
            seed = rapid_mix::<true>(seed ^ DEFAULT_SECRETS[6], static_ptr ^ DEFAULT_SECRETS[3]);

            #[cfg(feature = "std")]
            {
                // we can allocate to add extra noise
                let box_ptr = &*Box::new(1u64) as *const _ as usize as u64;
                seed = rapid_mix::<true>(seed ^ DEFAULT_SECRETS[4], box_ptr ^ DEFAULT_SECRETS[1]);
            }

            #[cfg(all(
                feature = "std",
                not(any(
                    miri,
                    all(target_family = "wasm", target_os = "unknown"),
                    target_os = "zkvm"
                ))
            ))]
            {
                // we can use the system time for extra noise
                seed = crate::rng::rapidrng_time(&mut seed);
            }

            // final avalanche step
            seed = rapid_mix::<true>(seed ^ DEFAULT_SECRETS[6], DEFAULT_SECRETS[0]);
            seed
        }
    }

    #[cfg(test)]
    mod tests {
        extern crate std;

        use std::collections::BTreeSet;
        use super::*;

        #[test]
        fn test_get_secrets() {
            let secrets1 = get_secrets();
            let secrets2 = get_secrets();
            assert_eq!(secrets1, secrets2, "get_secrets should return the same value on subsequent calls");
        }

        #[test]
        fn test_get_global_seed() {
            let global_secrets = GlobalSecrets::new();
            let seed1 = global_secrets.get_global_seed();
            let seed2 = global_secrets.get_global_seed();
            assert_eq!(seed1, seed2, "get_fixed_seed should return the same value on subsequent calls");
        }

        #[test]
        fn test_create_secrets() {
            let seed = super::generate_random();
            let secrets1 = super::create_secrets(seed);
            let secrets2 = super::create_secrets(seed);
            assert_eq!(secrets1, secrets2, "create_secrets should return the same value for the same seed");

            #[cfg(feature = "std")] {
                let secrets3 = super::create_secrets(seed + 1);
                assert_ne!(secrets1, secrets3, "create_secrets should not return the same value for different seeds");
            }

            // Check that the secrets are well-formed
            for secret in secrets1.iter() {
                const HI: u64 = 0xFFFF << 48;
                const MI: u64 = 0xFFFF << 24;
                const LO: u64 = 0xFFFF;

                assert_ne!(*secret & HI, 0, "Secret should have a high bit set");
                assert_ne!(*secret & MI, 0, "Secret should have a middle bit set");
                assert_ne!(*secret & LO, 0, "Secret should have a low bit set");
            }

            // Check that the secrets are unique
            let mut unique_secrets = BTreeSet::new();
            for secret in secrets1.iter() {
                unique_secrets.insert(*secret);
            }

            assert_eq!(unique_secrets.len(), secrets1.len(), "Secrets should be unique across both calls");
        }

        #[test]
        #[cfg(feature = "std")]
        fn test_generate_random() {
            let random1 = super::generate_random();
            let random2 = super::generate_random();
            assert_ne!(random1, random2, "generate_random should return different values on subsequent calls");
        }
    }
}
