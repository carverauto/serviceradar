use core::hash::BuildHasher;
use core::fmt::Formatter;
use crate::inner::RapidHasher;
use crate::inner::seeding::secrets::GlobalSecrets;

/// A [`std::hash::BuildHasher`] that initializes a [`RapidHasher`] with a user-provided seed and
/// secrets.
///
/// `SeedableState` should rarely be used as providing DoS resistance requires a randomized seed and
/// secrets. Users should instead prefer either:
/// * [`crate::inner::GlobalState`], which uses a global random seed and secrets initialized once at
///   program start.
/// * [`crate::inner::RandomState`], which uses a random seed per instance and global random secrets.
///
/// The lifetime `'s` is for the reference to the secrets. When using [`SeedableState::random`] or
/// [`SeedableState::fixed`] secrets, this lifetime will be `'static`.
///
/// # Example
/// ```
/// use std::collections::HashMap;
/// use std::hash::Hasher;
///
/// use rapidhash::quality::SeedableState;
///
/// let mut map = HashMap::with_hasher(SeedableState::default());
/// map.insert(42, "the answer");
/// ```
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct SeedableState<'s, const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool = false, const PROTECTED: bool = false> {
    seed: u64,
    secrets: &'s [u64; 7],
}

impl<'s, const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> Default for SeedableState<'s, AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Create a new [SeedableState] with a random seed. See [SeedableState::random] for more details.
    #[inline]
    fn default() -> Self {
        Self::random()
    }
}

impl<'s, const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> SeedableState<'s, AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Create a new seedable state with a custom seed and automatically generated secrets.
    ///
    /// The seed will be pre-mixed to improve entropy. The global secrets are randomly generated
    /// once at program start, and then will be re-used for all subsequent calls to this function.
    ///
    /// # Example
    /// ```
    /// use core::hash::BuildHasher;
    /// use rapidhash::quality::SeedableState;
    ///
    /// let state = SeedableState::new(0);
    ///
    /// let hash: u64 = state.hash_one(b"hello");
    /// println!("hash: {hash}");
    /// ```
    pub fn new(seed: u64) -> Self {
        Self {
            seed: crate::inner::seed::rapidhash_seed(seed),
            secrets: GlobalSecrets::new().get(),
        }
    }

    /// Create a new seedable state with a random seed.
    ///
    /// This is slower than using [`crate::inner::RandomState`], please use that instead.
    #[inline]
    pub fn random() -> Self {
        Self {
            seed: crate::inner::seeding::seed::get_seed(),
            secrets: GlobalSecrets::new().get(),
        }
    }

    /// Create a new seedable state with the default seed and secrets.
    ///
    /// Using the default secrets does not offer HashDoS resistance, but they will be fixed between
    /// different runs of the program.
    ///
    /// Please note that `fast::RapidHasher` and `quality::RapidHasher` are **not guaranteed** to
    /// produce the same hash outputs between different crate versions, compiler versions, or
    /// platforms.
    ///
    /// Also see [`GlobalState`] for a faster zero-sized alternative that uses global secrets that
    /// are fixed only for the lifetime of the program.
    #[inline]
    pub fn fixed() -> Self {
        Self {
            seed: crate::inner::seed::rapidhash_seed(crate::inner::seed::DEFAULT_SEED),
            secrets: &crate::inner::seed::DEFAULT_SECRETS,
        }
    }

    /// Create a new seedable state with a custom seed and secrets.
    ///
    /// ## Warning
    /// This constructor uses the provided `seed` and `secrets` as the initial state
    /// **without any pre-mixing or validation**. Supplying low-entropy or structured
    /// values (e.g., `0`, all-zero arrays, counters, timestamps) can produce
    /// degenerate hashing (high collision rates or identical outputs).
    ///
    /// ### Requirements
    /// - `seed` and `secrets` **must not** be zero; avoid any all-zero/near-zero state.
    /// - Generate `seed` and `secrets` with a **cryptographically secure PRNG** and
    ///   treat them as **independent** for each hasher instance.
    /// - Do not derive successive seeds from predictable data (time, PID/TID, memory
    ///   addresses) or by simple incrementation.
    ///
    /// ### Recommendation
    /// If you cannot pre-mix the seed yourself, use [`SeedableState::new`] instead.
    ///
    /// ### Example (secure generation)
    /// ```rust
    /// use core::hash::BuildHasher;
    /// use rapidhash::quality::SeedableState;
    ///
    /// // randomly generate secrets
    /// let seed: u64 = rand::random();
    /// let secrets: [u64; 7] = rand::random();
    ///
    /// // create the state
    /// let state = SeedableState::custom(seed, &secrets);
    ///
    /// // hash using the state
    /// let hash: u64 = state.hash_one(b"hello");
    /// println!("hash: {hash}");
    /// ```
    #[inline]
    pub fn custom(seed: u64, secrets: &'s [u64; 7]) -> Self {
        Self {
            seed,
            secrets,
        }
    }

    /// Deprecated and renamed to [`SeedableState::custom`].
    #[deprecated(since = "4.1.0", note = "Use custom() or new() instead.")]
    #[inline]
    pub fn with_seed(seed: u64, secrets: &'s [u64; 7]) -> Self {
        Self::custom(seed, secrets)
    }
}

impl<'s, const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool>  BuildHasher for SeedableState<'s, AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    type Hasher = RapidHasher<'s, AVALANCHE, SPONGE, COMPACT, PROTECTED>;

    #[inline(always)]
    fn build_hasher(&self) -> Self::Hasher {
        RapidHasher::new_precomputed_seed(self.seed, self.secrets)
    }
}

impl<'s, const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> core::fmt::Debug for SeedableState<'s, AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("SeedableState").finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use core::hash::BuildHasher;

    type SeedableState<'s> = super::SeedableState<'s, false, true, false, false>;

    #[test]
    fn test_random_init() {
        assert_eq!(core::mem::size_of::<SeedableState>(), 16);

        let state1 = SeedableState::random();
        let state2 = SeedableState::random();

        let finish1a = state1.hash_one(b"hello");
        let finish1b = state1.hash_one(b"hello");
        let finish2a = state2.hash_one(b"hello");

        assert_eq!(finish1a, finish1b);
        assert_ne!(finish1a, finish2a);
    }

    #[test]
    fn test_fixed_init() {
        assert_eq!(core::mem::size_of::<SeedableState>(), 16);

        let state1 = SeedableState::fixed();
        let state2 = SeedableState::fixed();

        let finish1a = state1.hash_one(b"hello");
        let finish1b = state1.hash_one(b"hello");
        let finish2a = state2.hash_one(b"hello");

        assert_eq!(finish1a, finish1b);
        assert_eq!(finish1a, finish2a);
    }

    #[test]
    fn test_debug() {
        extern crate alloc;
        let state = SeedableState::random();
        let debug_str = alloc::format!("{:?}", state);
        assert_eq!(debug_str, "SeedableState { .. }");
    }
}
