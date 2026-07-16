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
        // We take the stack pointer as a rather poor (but cheap!) source of entropy. The first
        // call benefits greatly from ASLR, but subsequent calls may have the same stack pointer,
        // and so we do further work below (on systems that support it!).
        //
        // `mut` is unused on targets where no block below applies (no std, atomics, or getrandom).
        #[allow(unused_mut)]
        let mut seed = 0;
        let arbitrary = core::ptr::addr_of!(seed) as u64;

        // With std we avoid using global atomics on the hot path, choosing a thread-local seed
        // counter. The counter must start from a unique value per thread: the OS recycles thread
        // stacks, so two threads whose first call happens at the same (reused) stack address
        // would otherwise produce identical seed sequences.
        #[cfg(feature = "std")] {
            use core::cell::Cell;

            thread_local! {
                static RANDOM_SEED: Cell<u64> = const {
                    Cell::new(0)
                }
            }

            seed = RANDOM_SEED.with(|cell| {
                let mut seed = cell.get();
                #[cfg(target_has_atomic = "ptr")] {
                    if seed == 0 {
                        seed = init_thread_seed(arbitrary);
                    }
                }
                #[cfg(not(target_has_atomic = "ptr"))] {
                    if seed == 0 {
                        seed = super::secrets::generate_random();
                    }
                }
                seed = seed.wrapping_add(DEFAULT_SECRETS[0]);
                cell.set(seed);
                seed
            });
        }

        // Without std we fall back to a global atomic and accept the chance of
        // race conditions, but two racing threads should have different stack pointers,
        // and so should generate distinct seeds.
        //
        // Most targets without atomics can still do atomic load/store, but just can't
        // do atomic compare-and-swap instructions, so we'd prefer if rust had a better way to
        // narrow down exactly what atomic functionality is available on a platform. Here, a
        // platform without CAS but does have load/store will miss out.
        #[cfg(all(not(feature = "std"), target_has_atomic = "ptr"))] {
            use core::sync::atomic::{AtomicUsize, Ordering};
            static RANDOM_SEED: AtomicUsize = AtomicUsize::new(0);

            seed = RANDOM_SEED.load(Ordering::Relaxed) as u64;
            if seed == 0 {
                // First call in the process: start the counter from the global seed, so that
                // per-map seeds include the one-time entropy (getrandom when enabled,
                // otherwise ASLR-derived).
                seed = super::secrets::GlobalSecrets::new().get_global_seed();
            }
            seed = seed.wrapping_add(DEFAULT_SECRETS[0] ^ arbitrary);
            RANDOM_SEED.store(seed as usize, Ordering::Relaxed);
        }

        // Without std or atomics there is no way to store counter state between calls, but with
        // the getrandom feature each RandomState can draw a fresh seed straight from the entropy
        // source (e.g. a custom getrandom backend over an embedded device's hardware RNG).
        // Slower than the counter paths above, but the only randomisation these targets have.
        #[cfg(all(not(feature = "std"), not(target_has_atomic = "ptr"), feature = "getrandom_04"))] {
            if let Ok(random) = getrandom_04::u64() {
                seed = random;
            }
        }

        #[cfg(all(not(feature = "std"), not(target_has_atomic = "ptr"), not(feature = "getrandom_04"), feature = "getrandom_03"))] {
            if let Ok(random) = getrandom_03::u64() {
                seed = random;
            }
        }

        // If neither atomics, std, nor getrandom were available, we're sadly left hoping that
        // stack pointer ASLR has been sufficient randomness. In that case, two RandomStates may
        // end up with the same seed, but as long as ASLR is intact, they should be different.
        seed ^ rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[2], arbitrary ^ DEFAULT_SECRETS[1])
    }

    /// Derive the starting value for a thread's seed counter, called once per thread.
    ///
    /// A global counter guarantees every thread starts from a distinct point even when thread
    /// stacks are recycled, and mixing in the global seed folds the process's one-time entropy
    /// (OS randomness under std) into every per-map seed. One relaxed `fetch_add` plus a mix:
    /// no syscalls, so thread-per-request servers only pay a few cycles per thread.
    #[cfg(all(feature = "std", target_has_atomic = "ptr"))]
    #[cold]
    fn init_thread_seed(arbitrary: u64) -> u64 {
        use core::sync::atomic::{AtomicUsize, Ordering};
        static THREAD_COUNTER: AtomicUsize = AtomicUsize::new(1);

        // Lossy add our ASLR offset to the counter. We believe this is less contentious than a
        // fetch_add. We accept a lossy add because the only reason one thread's value will be lost
        // is if it's overwritten by another thread, meaning if this thread is cached and reused, it
        // will read a different thread_counter value on each instantiation.
        let mut thread_counter = THREAD_COUNTER.load(Ordering::Relaxed) as u64;
        thread_counter = thread_counter.wrapping_add(arbitrary);
        THREAD_COUNTER.store(thread_counter as usize, Ordering::Relaxed);

        let global_seed = super::secrets::GlobalSecrets::new().get_global_seed();
        rapid_mix_np::<false>(thread_counter ^ DEFAULT_SECRETS[3], global_seed ^ DEFAULT_SECRETS[4])
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

        #[test]
        fn test_seed_collision_is_unlikely_across_threads() {
            extern crate std;
            use std::collections::BTreeSet;

            const THREADS: usize = 1024;
            let seeds: BTreeSet<u64> = (0..THREADS)
                .map(|_| std::thread::spawn(get_seed).join().unwrap())
                .collect();

            assert_eq!(seeds.len(), THREADS, "expected no seed collisions across threads, got {} unique", seeds.len());
        }
    }
}

// TODO: use compile-time generated constants here
#[cfg(not(target_has_atomic = "ptr"))]
pub(crate) mod secrets {
    #[inline(always)]
    pub fn get_secrets() -> &'static [u64; 7] {
        // Platforms without atomic pointer (CAS) support cannot safely randomize a global,
        // so we fall back to the default rapidhash secrets.
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
    use crate::inner::mix_np::rapid_mix_np;
    use crate::v1::DEFAULT_SEED;
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

    /// Initialize the global seed and secrets, racing other threads for the right to do so.
    ///
    /// All randomness generation and derivation happens *before* the CAS, so the window where
    /// the state is `Initializing` is only a handful of stores. Losing threads spin until the
    /// winner publishes; on any preemptive OS this is bounded and tiny. The remaining hazard is
    /// a single-core system without preemption — e.g. an interrupt handler creating a hasher
    /// while the interrupted code was mid-initialization — which would spin forever. That is
    /// unavoidable without heap allocation while `get()` hands out `&'static` secrets; such
    /// systems should create a hasher once at startup, before enabling interrupts.
    #[cold]
    #[inline(never)]
    fn initialize_secrets() {
        let randomness = generate_random();
        let seed = rapid_mix_np::<false>(randomness ^ DEFAULT_SECRETS[0], DEFAULT_SEED);
        let secrets = create_secrets(randomness);

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
                Err(s) if s == SecretStorageStates::Initialized as usize => {
                    return;
                }

                // We are spinning here until the other thread is done initializing. This should
                // be very fast, as the initializing thread should only be copying the already
                // generated secrets for a few instructions.
                _ => core::hint::spin_loop(),
            }
        }
    }

    fn create_secrets(seed: u64) -> [u64; 7] {
        let mut state = rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[2], DEFAULT_SECRETS[1]);
        let mut secrets = [0u64; 7];

        for i in 0..secrets.len() {
            const HI: u64 = 0xFFFF << 48;
            const MI: u64 = 0xFFFF << 24;
            const LO: u64 = 0xFFFF;

            state = rapid_mix_np::<false>(state ^ DEFAULT_SECRETS[0], seed ^ DEFAULT_SECRETS[i]);

            // ensure at least one high, middle, and low bit is set for a semi-decent secret
            if (state & HI) == 0 {
                state |= 1u64 << 63;
            }

            if (state & MI) == 0 {
                state |= 1u64 << 31;
            }

            if (state & LO) == 0 {
                state |= 1u64;
            }

            secrets[i] = state;
        }

        secrets
    }

    /// Generate a random number, trying our best to make this a good random number.
    ///
    /// This method should only be relied upon _once per process_ to create randomness, as without
    /// the `getrandom` or `std` features it relies entirely on ASLR to produce randomness.
    pub(crate) fn generate_random() -> u64 {
        // The getrandom feature sources entropy directly from the OS/platform, and is the only
        // real entropy source on wasm32 (via getrandom's `wasm_js` backend) and many no_std
        // targets. It takes priority over std, as std's RandomState silently falls back to
        // fixed keys on targets without entropy (e.g. wasm32-unknown-unknown).
        #[cfg(feature = "getrandom_04")] {
            if let Ok(random) = getrandom_04::u64() {
                return random;
            }
            // otherwise fall through to the weaker sources below
        }

        #[cfg(all(feature = "getrandom_03", not(feature = "getrandom_04")))] {
            if let Ok(random) = getrandom_03::u64() {
                return random;
            }
            // otherwise fall through to the weaker sources below
        }

        #[cfg(feature = "std")] {
            // the rust standard library doesn't directly expose the secure randomness it feeds its
            // hashers, but we can still indirectly use it by running a single hash.
            use std::hash::{BuildHasher, Hasher};

            // using the old import path for MSRV 1.71 compatibility
            use std::collections::hash_map::RandomState as StdRandomState;

            let mut hasher = StdRandomState::new().build_hasher();
            hasher.write(b"");
            hasher.finish()
        }

        #[cfg(not(feature = "std"))] {
            // Trying our best to generate a good random number on all platforms by hoping for ASLR
            // and noting that this randomness only works once, all other randomness must be derived
            // from this single u64 of randomness. Calling get_random() twice in the same thread or
            // process can return the same u64 value.
            let mut seed = DEFAULT_SECRETS[0];
            let stack_ptr = core::ptr::addr_of!(seed) as u64;
            let static_ptr = &DEFAULT_SECRETS as *const _ as usize as u64;
            let function_ptr = generate_random as *const () as usize as u64;

            seed = rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[4], stack_ptr ^ DEFAULT_SECRETS[1]);
            seed = rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[5], function_ptr ^ DEFAULT_SECRETS[2]);
            seed = rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[6], static_ptr ^ DEFAULT_SECRETS[3]);

            // final avalanche mix step
            rapid_mix_np::<false>(seed ^ DEFAULT_SECRETS[6], DEFAULT_SECRETS[0])
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
        #[cfg(any(feature = "std", feature = "getrandom_04", feature = "getrandom_03"))]
        fn test_generate_random() {
            let random1 = super::generate_random();
            let random2 = super::generate_random();
            assert_ne!(random1, random2, "generate_random should return different values on subsequent calls");
        }

        #[test]
        #[ignore]
        #[cfg(not(any(feature = "std", feature = "getrandom_04", feature = "getrandom_03")))]
        fn test_generate_random_no_std_hardcoded() {
            // I use this to check we're getting random values between test runs by flipping this
            // to an "assert_eq" ...
            let random1 = super::generate_random();
            assert_ne!(random1, 10848721480813500213, "a hardcoded test that ASLR randomisation is working");
        }
    }
}
