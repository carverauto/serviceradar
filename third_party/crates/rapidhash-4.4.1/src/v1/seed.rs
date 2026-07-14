//! Reliable seeding and secrets generation for the hash functions.

use crate::util::mix::rapid_mix;

/// The default seed used in the C++ implementation.
pub(crate) const DEFAULT_SEED: u64 = 0xbdd89aa982704029;

/// Used only for generating random secrets.
const DEFAULT_SECRETS: [u64; 3] = [
    0x2d358dccaa6c78a5,
    0x8bb84b93962eacc9,
    0x4b33a62ed433d4a3,
];

/// The default rapidhash secrets used in the C++ implementation.
///
/// We recommend generating your own secrets using the [`crate::v3::RapidSecrets::seed`] method to avoid
/// trivial collision attacks if you need minimal HashDoS protection.
pub const DEFAULT_RAPID_SECRETS: RapidSecrets = RapidSecrets::seed_cpp(DEFAULT_SEED);

/// Hold the seed and secrets to be used by rapidhash.
///
/// RapidSecrets premix the seed and generate a set of other secrets based on the seed that are all
/// used in the hashing process. There are some quality checks on the random values to ensure a
/// reasonable distribution of entropy in the generated secrets.
///
/// Constructing this struct is fairly cheap, but unnecessary in the critical path. We therefore
/// recommend instantiating it once and re-using the same instance for any persistent hashing. The
/// `seed` method is marked `const` to also do so at compile time.
///
/// # Minimal HashDoS Protection
/// We recommend changing the default seed and secrets must be changed to avoid trivial collision
/// attacks. For persistent hashing, you can hard code your own randomized seed at compile time.
///
/// ```rust
/// use rapidhash::v1::RapidSecrets;
/// const DEFAULT_SECRETS: RapidSecrets = RapidSecrets::seed(0x123456);  // <-- change this value!
///
/// /// Export your chosen rapidhash version and secrets for use throughout your project.
/// pub fn rapidhash(data: &[u8]) -> u64 {
///     rapidhash::v1::rapidhash_v1_seeded(data, &DEFAULT_SECRETS)
/// }
/// ```
///
/// TODO: serde or serialization support.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct RapidSecrets {
    /// The core rapidhash seed.
    pub seed: u64,

    /// The secrets, effectively other seeds used in the hashing process.
    pub secrets: [u64; 3],
}

impl RapidSecrets {
    /// Generate secrets from a given randomized seed.
    ///
    /// Note the chosen seed will be pre-mixed to further randomized it, and the secrets will be
    /// computed based on the seed.
    ///
    /// If compatibility with the C++ implementation is required, use the `seed_cpp` method instead.
    #[inline]
    pub const fn seed(seed: u64) -> Self {
        let seed = premix_seed(seed, 0);
        let mut secrets = [0; 3];
        secrets[0] = premix_seed(seed, 0);
        secrets[1] = premix_seed(secrets[0], 1);
        secrets[2] = premix_seed(secrets[1], 2);
        Self { seed, secrets }
    }

    /// Creates a new `RapidSecrets` instance with a different seed and the same secrets.
    ///
    /// This is useful for in-memory hashing, so we can quickly use a different seed for other
    /// HashMaps.
    #[inline(always)]
    pub const fn reseed(&self) -> Self {
        Self {
            seed: premix_seed(self.seed, 6),
            secrets: self.secrets,
        }
    }

    /// Creates a new `RapidSecrets` instance using a seed and secrets that are compatible with the
    /// C++ implementation.
    ///
    /// Note that these **use the default secrets** and therefore are liable to some trivial
    /// collision attacks, as randomising both the seed and secrets is necessary to provide minimal
    /// HashDoS resistance.
    #[inline(always)]
    pub const fn seed_cpp(seed: u64) -> Self {
        Self {
            seed: rapidhash_seed(seed),
            secrets: DEFAULT_SECRETS,
        }
    }
}

#[inline(always)]
const fn rapidhash_seed(seed: u64) -> u64 {
    seed ^ rapid_mix::<false>(seed ^ DEFAULT_SECRETS[0], DEFAULT_SECRETS[1])
}

#[inline]
const fn premix_seed(mut seed: u64, i: usize) -> u64 {
    seed ^= rapid_mix::<false>(seed ^ DEFAULT_SECRETS[2], DEFAULT_SECRETS[i]);

    // ensure the seeds are of reasonable non-zero quality
    const HI: u64 = 0xFFFF << 48;
    const MI: u64 = 0xFFFF << 24;
    const LO: u64 = 0xFFFF;

    if (seed & HI) == 0 {
        seed |= 1u64 << 63;
    }

    if (seed & MI) == 0 {
        seed |= 1u64 << 31;
    }

    if (seed & LO) == 0 {
        seed |= 1u64;
    }

    seed
}
