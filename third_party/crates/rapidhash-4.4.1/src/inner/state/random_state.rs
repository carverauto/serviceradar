use core::hash::{BuildHasher};
use core::fmt::Formatter;
use crate::inner::RapidHasher;
use crate::inner::seeding::secrets::GlobalSecrets;

/// A [`std::hash::RandomState`] compatible hasher that initializes a [`RapidHasher`] with a random
/// seed and random global secrets.
///
/// This is designed to provide some HashDoS resistance by using a random seed per hashmap, and
/// a global random set of secrets.
///
/// # Portability
///
/// On most target platforms, the secrets are randomly initialized once and cached globally for the
/// lifetime of the program using a mix of ASLR and other entropy sources. The seed is randomly
/// initialized for each new instance of `RandomState` using only ASLR and a mixing step.
///
/// On targets without atomic pointer support, the global secrets will not be randomized, and
/// instead will fall back to the default secrets. This means these platforms will not have minimal
/// HashDoS resistance guarantees. If this is important for your application, please raise a GitHub
/// issue to improve support for these platforms.
///
/// # Example
/// ```rust
/// use std::collections::HashMap;
/// use std::hash::Hasher;
///
/// use rapidhash::quality::RandomState;
///
/// let mut map = HashMap::with_hasher(RandomState::default());
/// map.insert(42, "the answer");
/// ```
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct RandomState<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> {
    seed: u64,

    /// The global secrets is a zero-sized type to keep HashMap<K, V, RandomState> small.
    secrets: GlobalSecrets,
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> RandomState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Create a new random state with a random seed.
    ///
    /// The seed is always randomized by using ASLR on every new instance of RandomState.
    ///
    /// With the `rand` feature enabled, the secrets will be randomized using [rand::random].
    /// Otherwise, a mix of ASLR and some other poorer sources of entropy will be mixed together to
    /// generate the secrets. The secrets are statically cached for the lifetime of the program
    /// after their initial generation.
    ///
    /// On platforms that do not support atomic pointers, the secrets will be the default rapidhash
    /// secrets, which are not randomized. Therefore, **targets without atomic pointer support will
    /// not have minimal HashDoS resistance guarantees**.
    #[inline]
    pub fn new() -> Self {
        Self {
            seed: crate::inner::seeding::seed::get_seed(),
            secrets: GlobalSecrets::new(),
        }
    }
}

/// Warning that `RandomState` only randomizes the seed on platforms that support atomic pointers.
impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> Default for RandomState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    #[inline]
    fn default() -> Self {
        Self::new()
    }
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool>  BuildHasher for RandomState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    type Hasher = RapidHasher<'static, AVALANCHE, SPONGE, COMPACT, PROTECTED>;

    #[inline(always)]
    fn build_hasher(&self) -> Self::Hasher {
        RapidHasher::new_precomputed_seed(self.seed, self.secrets.get())
    }
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> core::fmt::Debug for RandomState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("RandomState").finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use core::hash::BuildHasher;

    type RandomState = super::RandomState<false, true, false, false>;

    #[test]
    fn test_random_state() {
        assert_eq!(core::mem::size_of::<RandomState>(), 8);

        let state1 = RandomState::new();
        let state2 = RandomState::new();

        let finish1a = state1.hash_one(b"hello");
        let finish1b = state1.hash_one(b"hello");
        let finish2a = state2.hash_one(b"hello");

        assert_eq!(finish1a, finish1b);
        assert_ne!(finish1a, finish2a);
    }

    #[test]
    fn test_debug() {
        extern crate alloc;
        let state = RandomState::new();
        let debug_str = alloc::format!("{:?}", state);
        assert_eq!(debug_str, "RandomState { .. }");
    }
}
