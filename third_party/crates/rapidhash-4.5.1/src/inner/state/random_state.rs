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
/// # Performance
///
/// Enabling the `std` feature will make `RandomState` slightly faster to initialize by avoiding
/// a global atomic load/store and using thread-locals instead.
///
/// Note that `GlobalState` will be even faster to initialize than `RandomState`, as it does not
/// generate a new seed for every instantiation. `GlobalState` also randomizes the seed and secrets
/// on the first instantiation, so it can still provide minimal DoS resistance, but then re-uses
/// that same randomized seed and secrets for subsequent instantiations. If you are creating many
/// instances of `RandomState` in a tight loop, you may want to consider using `GlobalState`
/// instead.
///
/// # Portability
///
/// On most target platforms, the secrets are randomly initialized once and cached globally for the
/// lifetime of the program. With the `getrandom_04` feature this uses OS/platform entropy directly;
/// with `std` it uses the standard library's secure RNG; with neither it falls back to ASLR-based
/// entropy alone. A fresh seed is generated for each new instance of `RandomState` from a
/// thread-local or global counter mixed with ASLR entropy.
///
/// Some targets have no ambient entropy or ASLR at all, and seeding on them is otherwise fully
/// deterministic between boots. Enable the `getrandom_04` feature to get true randomisation for
/// HashDoS resistance on these targets:
///
/// - **wasm32 with WASI** (`wasm32-wasip1`/`wasm32-wasip2`): enabling rapidhash's `getrandom_04`
///   feature is sufficient; entropy comes from the WASI host.
/// - **wasm32 in the browser or node** (`wasm32-unknown-unknown`): enable rapidhash's `getrandom_04`
///   feature, add `getrandom = { version = "0.4", features = ["wasm_js"] }` to the top-level
///   binary's dependencies, and build with `RUSTFLAGS='--cfg getrandom_backend="wasm_js"'`.
///   Without the backend flag the build fails with instructions, rather than silently
///   falling back to deterministic seeding.
/// - **Embedded and other `no_std` targets with a hardware RNG**: enable rapidhash's `getrandom_04`
///   feature and register a [custom backend](https://docs.rs/getrandom/0.4/getrandom/#custom-backend)
///   that reads from the platform's RNG.
///
/// Older or exotic platforms that getrandom does not support can also use the custom backend
/// mechanism to supply their own entropy source.
///
/// On targets without atomic pointer support (e.g. `thumbv6m-none-eabi`), the global secrets
/// cannot be randomized and fall back to the default secrets. With the `getrandom_04` feature each
/// `RandomState` still draws a fresh random per-map seed directly from the entropy source,
/// retaining minimal HashDoS resistance; without it these platforms have none. If stronger
/// support for these platforms is important to your application, please raise a GitHub issue.
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
    /// Create a new random state with a fresh per-instance seed and the global secrets.
    ///
    /// A new seed is generated for every `RandomState` instance. With the `std` feature this uses a
    /// fast thread-local counter mixed with stack-pointer (ASLR) entropy, where each thread's
    /// counter is initialized from the process-wide random seed and a global thread counter;
    /// without `std` it uses a global atomic counter initialized from the process-wide random
    /// seed. On targets with neither, each instance draws its seed from getrandom when the
    /// `getrandom_04` feature is enabled, or falls back to ASLR alone.
    ///
    /// The secrets are randomized once and then cached globally for the lifetime of the program.
    /// The one-time randomization is derived from OS/platform entropy with the `getrandom_04`
    /// feature, or the standard library's secure RNG with the `std` feature (the same source
    /// `std` uses to seed its own hashers); with neither it falls back to mixing ASLR and other
    /// weaker sources of entropy.
    ///
    /// On platforms that do not support atomic pointers, the secrets will be the default rapidhash
    /// secrets, which are not randomized. Therefore, **targets without atomic pointer support only
    /// have minimal HashDoS resistance when the `getrandom_04` feature provides random seeds**.
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
