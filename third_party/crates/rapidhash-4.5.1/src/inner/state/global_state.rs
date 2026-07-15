use core::hash::BuildHasher;
use core::fmt::Formatter;
use crate::inner::RapidHasher;
use crate::inner::seeding::secrets::GlobalSecrets;

/// A [`BuildHasher`] that uses a global seed and secrets, randomized only once on startup.
///
/// The global seed and secrets are randomized on the first instantiation, and then every subsequent
/// instance of GlobalState will re-use the same seed and secrets, ensuring consistent hash outputs
/// for the duration of the program.
///
/// The one-time randomization is derived from OS/platform entropy when the `getrandom_04` feature is
/// enabled, or the standard library's secure RNG when the `std` feature is enabled, falling back
/// to ASLR and weaker entropy sources otherwise. Because every
/// instance shares a single seed and secret set, `GlobalState` only offers minimal HashDoS
/// resistance: an attacker cannot predict the secrets, but every map in the process shares the same
/// collision structure. Prefer [`RandomState`](crate::fast::RandomState) when each map should be
/// seeded independently.
///
/// See [`RandomState`](crate::fast::RandomState)'s portability docs for enabling true
/// randomisation on wasm32 and embedded targets via the `getrandom` feature.
///
/// # Performance
///
/// `GlobalState` is faster and smaller than `RandomState` while still providing some minimal DoS
/// resistance, and so may be preferable to `RandomState` when instantiating many hashmaps in a
/// tight loop.
///
/// # Example
/// ```rust
/// use std::collections::HashMap;
/// use std::hash::Hasher;
///
/// use rapidhash::fast::GlobalState;
///
/// let mut map = HashMap::with_hasher(GlobalState::default());
/// map.insert(42, "the answer");
/// ```
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct GlobalState<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> {
    /// The global secrets is a zero-sized type to keep HashMap<K, V, RandomState> small.
    secrets: GlobalSecrets,
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> GlobalState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Create a new global state with a global seed and secrets.
    ///
    /// The seed and secrets are randomized once, on the first instantiation of any `GlobalState`,
    /// and then cached for the lifetime of the program; all subsequent instances share them. With
    /// the `std` feature the one-time randomization is derived from the standard library's secure
    /// RNG; without `std` it falls back to ASLR and other weaker sources of entropy.
    ///
    /// Because every instance shares the same seed and secrets, all maps in the process share the
    /// same collision structure. Use [`RandomState`](crate::fast::RandomState) if you need each map
    /// to be seeded independently.
    ///
    /// On platforms which do not support atomic pointers, the secrets will be the default rapidhash
    /// secrets, which are not randomized. Therefore, **`GlobalState` on targets without atomic
    /// pointer support has no HashDoS resistance guarantees**: there is nowhere to store a
    /// randomized value, so even the `getrandom_04` feature cannot help. Prefer
    /// [`RandomState`](crate::fast::RandomState) with the `getrandom_04` feature on these targets,
    /// which draws a fresh random seed per instance instead.
    #[inline(always)]
    pub fn new() -> Self {
        Self {
            secrets: GlobalSecrets::new(),
        }
    }
}

/// Warning that `GlobalState` only randomizes the seed on platforms that support atomic pointers.
impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> Default for GlobalState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    #[inline(always)]
    fn default() -> Self {
        Self::new()
    }
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool>  BuildHasher for GlobalState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    type Hasher = RapidHasher<'static, AVALANCHE, SPONGE, COMPACT, PROTECTED>;

    #[inline(always)]
    fn build_hasher(&self) -> Self::Hasher {
        RapidHasher::new_precomputed_seed(
            self.secrets.get_global_seed(),
            self.secrets.get()
        )
    }
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> core::fmt::Debug for GlobalState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("GlobalState").finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use core::hash::BuildHasher;

    type GlobalState = super::GlobalState<false, true, false, false>;

    #[test]
    fn test_global_state() {
        let state1 = GlobalState::new();
        let state2 = GlobalState::new();

        let finish1a = state1.hash_one(b"hello");
        let finish1b = state1.hash_one(b"hello");
        let finish2a = state2.hash_one(b"hello");

        assert_eq!(finish1a, finish1b);
        assert_eq!(finish1a, finish2a);
    }

    #[test]
    fn test_debug() {
        extern crate alloc;
        let state = GlobalState::new();
        let debug_str = alloc::format!("{:?}", state);
        assert_eq!(debug_str, "GlobalState { .. }");
    }
}
