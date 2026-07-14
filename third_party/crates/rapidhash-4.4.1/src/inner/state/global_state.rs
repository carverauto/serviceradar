use core::hash::BuildHasher;
use core::fmt::Formatter;
use crate::inner::RapidHasher;
use crate::inner::seeding::secrets::GlobalSecrets;

/// A [`BuildHasher`] that uses a global seed and secrets, randomized only once on startup.
///
/// The global secrets are randomized on the first instantiation, and then every subsequent instance
/// of GlobalState will re-use the same seed and secrets, ensuring consistent hash outputs for the
/// duration of the program.
#[derive(Copy, Clone, Eq, PartialEq)]
pub struct GlobalState<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> {
    /// The global secrets is a zero-sized type to keep HashMap<K, V, RandomState> small.
    secrets: GlobalSecrets,
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> GlobalState<AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Create a new global state with a global seed and secrets.
    ///
    /// The seed and secrets will be randomized on the first instantiation of `GlobalState`, but all
    /// subsequent instances will share the same seed and secrets.
    ///
    /// On platforms which do not support atomic pointers, the secrets will be the default rapidhash
    /// secrets, which are not randomized. Therefore, **targets without atomic pointer support will
    /// not have minimal HashDoS resistance guarantees**.
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
        assert_eq!(core::mem::size_of::<GlobalState>(), 0);

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
