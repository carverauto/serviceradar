//! Fast random number generation using rapidhash mixing.

#[cfg(feature = "rng")]
use rand_core::{RngCore, SeedableRng, impls};
use crate::util::mix::rapid_mix;

/// Uses the V1 rapid seed.
const RAPID_SEED: u64 = 0xbdd89aa982704029;

/// Uses the V1 rapid secrets.
const RAPID_SECRET: [u64; 3] = [0x2d358dccaa6c78a5, 0x8bb84b93962eacc9, 0x4b33a62ed433d4a3];

/// Generate a random number using rapidhash mixing.
///
/// This RNG is deterministic and optimized for throughput. It is not a cryptographic random number
/// generator.
///
/// This implementation is equivalent in logic and performance to
/// [wyhash::wyrng](https://docs.rs/wyhash/latest/wyhash/fn.wyrng.html) and
/// [fasthash::u64](https://docs.rs/fastrand/latest/fastrand/), but uses rapidhash
/// constants/secrets.
///
/// The weakness with this RNG is that at best it's a single cycle over the u64 space, as the seed
/// is simple a position in a constant sequence. Future work could involve using a wider state to
/// ensure we can generate many different sequences.
#[inline]
pub fn rapidrng_fast(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_add(RAPID_SECRET[0]);
    rapid_mix::<false>(*seed, *seed ^ RAPID_SECRET[1])
}

/// A lower quality version of [`rapidrng_fast`] with that's slightly faster, with optimisations for
/// u32 platforms and those without wide-arithmetic support.
///
/// This is not a portable RNG, as it will produce different results on different platforms. Use
/// [`rapidrng_fast`] if stable outputs are required.
///
/// Used in the rapidhash WASM benchmarks.
#[inline]
pub fn rapidrng_fast_not_portable(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_add(RAPID_SECRET[0]);
    rapid_mix_np_low_quality(*seed, RAPID_SECRET[1])
}

/// A very fast low-quality mixing function used only for the ultra-fast PRNG.
///
/// Uses the standard `rapid_mix` for 64-bit architectures, and otherwise uses a very cheap
/// u32-mix for platforms without wide-arithmetic support. This is even cheaper/lower quality than
/// `rapid_mix_np`.
#[inline(always)]
fn rapid_mix_np_low_quality(x: u64, y: u64) -> u64 {
    #[cfg(any(
        all(
            target_pointer_width = "64",
            not(any(target_arch = "sparc64", target_arch = "wasm64")),
        ),
        target_arch = "aarch64",
        target_arch = "x86_64",
        all(target_family = "wasm", target_feature = "wide-arithmetic"),
    ))]
    {
        rapid_mix::<false>(x, y)
    }

    #[cfg(not(any(
        all(
            target_pointer_width = "64",
            not(any(target_arch = "sparc64", target_arch = "wasm64")),
        ),
        target_arch = "aarch64",
        target_arch = "x86_64",
        all(target_family = "wasm", target_feature = "wide-arithmetic"),
    )))]
    {
        // u64 x u64 -> u128 product is prohibitively expensive on 32-bit.
        // Decompose into 32-bit parts.
        let lx = x as u32;
        let ly = y as u32;
        let hx = (x >> 32) as u32;
        let hy = (y >> 32) as u32;

        // u32 x u32 -> u64 the low bits of one with the high bits of the other.
        let afull = (lx as u64) * (hy as u64);
        let bfull = (hx as u64) * (ly as u64);

        // Combine, swapping low/high of one of them so the upper bits of the
        // product of one combine with the lower bits of the other.
        afull ^ bfull.rotate_right(32)
    }
}

/// Generate a random number non-deterministically by re-seeding with the current time.
///
/// This is not a cryptographic random number generator.
///
/// Note fetching system time requires a syscall and is therefore much slower than [rapidrng_fast].
/// It can also be used to seed [rapidrng_fast].
///
/// Requires the `std` feature and a platform that supports [std::time::SystemTime].
///
/// # Example
/// ```rust
/// use rapidhash::rng::{rapidrng_fast, rapidrng_time};
///
/// // choose a non-deterministic random seed (50-100ns)
/// let mut seed = rapidrng_time(&mut 0);
///
/// // rapid fast deterministic random numbers (~1ns/iter)
/// for _ in 0..10 {
///     println!("{}", rapidrng_fast(&mut seed));
/// }
/// ```
#[cfg(any(
    all(
        feature = "std",
        not(any(
            miri,
            all(target_family = "wasm", target_os = "unknown"),
            target_os = "zkvm"
        ))
    ),
    docsrs
))]
#[inline]
pub fn rapidrng_time(seed: &mut u64) -> u64 {
    let time = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
    // NOTE limited entropy: only a few of the time.as_secs bits will change between calls, and the
    // time.subsec_nanos may only have milli- or micro-second precision on some platforms.
    // This is why we further stretch the teed with multiple rounds of rapid_mix.
    let mut  teed = (time.as_secs() << 32) | time.subsec_nanos() as u64;
    teed = rapid_mix::<false>(teed ^ RAPID_SECRET[0], *seed ^ RAPID_SECRET[1]);
    *seed = rapid_mix::<false>(teed ^ RAPID_SECRET[0], RAPID_SECRET[2]);
    rapid_mix::<false>(*seed, *seed ^ RAPID_SECRET[1])
}

/// A random number generator that uses the rapidhash mixing algorithm.
///
/// This deterministic RNG is optimized for speed and throughput. This is not a cryptographic random
/// number generator.
///
/// This RNG is compatible with [`rand_core::RngCore`] and [`rand_core::SeedableRng`].
///
/// # Example
/// ```rust
/// use rapidhash::rng::RapidRng;
///
/// let mut rng = RapidRng::default();
/// println!("{}", rng.next());
/// ```
#[derive(Clone, Copy, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub struct RapidRng {
    seed: u64,
}

#[cfg(any(
    all(
        feature = "std",
        not(any(
            miri,
            all(target_family = "wasm", target_os = "unknown"),
            target_os = "zkvm"
        ))
    ),
    docsrs
))]
impl Default for RapidRng {
    /// Create a new random number generator.
    ///
    /// With `std` enabled, the seed is generated using the current system time via [rapidrng_time].
    ///
    /// Without `std`, the seed is set to the default seed.
    #[inline]
    fn default() -> Self {
        let mut seed = RAPID_SEED;
        Self {
            seed: rapidrng_time(&mut seed),
        }
    }
}

#[cfg(not(any(
    all(
        feature = "std",
        not(any(
            miri,
            all(target_family = "wasm", target_os = "unknown"),
            target_os = "zkvm"
        ))
    ),
    docsrs
)))]
impl Default for RapidRng {
    /// Create a new random number generator.
    ///
    /// With `std` enabled, the seed is generated using the current system time via [rapidrng_time].
    ///
    /// Without `std`, the seed is set to [RAPID_SEED].
    #[inline]
    fn default() -> Self {
        Self {
            seed: RAPID_SEED,
        }
    }
}

impl RapidRng {
    /// Create a new random number generator from a specified seed.
    ///
    /// Also see [RapidRng::default()] with the `std` feature enabled for seed randomisation based
    /// on the current time.
    #[inline]
    pub fn new(seed: u64) -> Self {
        Self {
            seed,
        }
    }

    /// Export the current state of the random number generator.
    #[inline]
    pub fn state(&self) -> [u8; 8] {
        self.seed.to_le_bytes()
    }

    /// Get the next random number from this PRNG and iterate the state.
    #[inline]
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> u64 {
        rapidrng_fast(&mut self.seed)
    }
}

#[cfg(feature = "rng")]
impl RngCore for RapidRng {
    #[inline]
    fn next_u32(&mut self) -> u32 {
        self.next_u64() as u32
    }

    #[inline]
    fn next_u64(&mut self) -> u64 {
        self.next()
    }

    #[inline]
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        impls::fill_bytes_via_next(self, dest)
    }
}

#[cfg(feature = "rng")]
impl SeedableRng for RapidRng {
    type Seed = [u8; 8];

    #[inline]
    fn from_seed(seed: Self::Seed) -> Self {
        Self {
            seed: u64::from_le_bytes(seed),
        }
    }

    #[inline]
    fn seed_from_u64(state: u64) -> Self {
        Self::new(state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "rng")]
    #[test]
    fn test_rapidrng() {
        let mut rng = RapidRng::new(0);
        let x = rng.next();
        let y = rng.next();
        assert_ne!(x, 0);
        assert_ne!(x, y);
    }

    #[cfg(all(feature = "rng", feature = "std"))]
    #[test]
    fn bit_flip_trial() {
        let cycles = 100_000;
        let mut seen = std::collections::HashSet::with_capacity(cycles);
        let mut flips = std::vec::Vec::with_capacity(cycles);
        let mut rng = RapidRng::new(0);

        let mut prev = 0;
        for _ in 0..cycles {
            let next = rng.next_u64();

            let xor = prev ^ next;
            let flipped = xor.count_ones() as u64;
            assert!(xor.count_ones() >= 10, "Flipping bit changed only {} bits", flipped);
            flips.push(flipped);

            assert!(!seen.contains(&next), "RapidRngFast produced a duplicate value");
            seen.insert(next);

            prev = next;
        }

        let average = flips.iter().sum::<u64>() as f64 / flips.len() as f64;
        assert!(average > 31.95 && average < 32.05, "Did not flip an average of half the bits. average: {}, expected: 32.0", average);
    }

    #[cfg(feature = "std")]
    #[test]
    fn bit_flip_trial_fast() {
        let cycles = 100_000;
        let mut seen = std::collections::HashSet::with_capacity(cycles);
        let mut flips = std::vec::Vec::with_capacity(cycles);

        let mut prev = 0;
        for _ in 0..cycles {
            let next = rapidrng_fast(&mut prev);

            let xor = prev ^ next;
            let flipped = xor.count_ones() as u64;
            assert!(xor.count_ones() >= 10, "Flipping bit changed only {} bits", flipped);
            flips.push(flipped);

            assert!(!seen.contains(&next), "rapidrng_fast produced a duplicate value");
            seen.insert(next);

            prev = next;
        }

        let average = flips.iter().sum::<u64>() as f64 / flips.len() as f64;
        assert!(average > 31.95 && average < 32.05, "Did not flip an average of half the bits. average: {}, expected: 32.0", average);
    }

    #[cfg(feature = "std")]
    #[test]
    fn bit_flip_trial_time() {
        let cycles = 100_000;
        let mut seen = std::collections::HashSet::with_capacity(cycles);
        let mut flips = std::vec::Vec::with_capacity(cycles);

        let mut prev = 0;
        for _ in 0..cycles {
            let next = rapidrng_time(&mut prev);

            let xor = prev ^ next;
            let flipped = xor.count_ones() as u64;
            assert!(xor.count_ones() >= 10, "Flipping bit changed only {} bits", flipped);
            flips.push(flipped);

            assert!(!seen.contains(&next), "rapidrng_time produced a duplicate value");
            seen.insert(next);

            prev = next;
        }

        let average = flips.iter().sum::<u64>() as f64 / flips.len() as f64;
        assert!(average > 31.95 && average < 32.05, "Did not flip an average of half the bits. average: {}, expected: 32.0", average);
    }

    /// detects a cycle at: 4294967296:1751221902
    /// note that we're detecting _seed_ cycles, not output values.
    #[test]
    #[ignore]
    fn find_cycle() {
        let mut fast = 0;
        let mut slow = 0;

        let mut power: u64 = 1;
        let mut lam: u64 = 1;
        rapidrng_fast(&mut fast);
        while fast != slow {
            if power == lam {
                slow = fast;
                power *= 2;
                lam = 0;
            }
            rapidrng_fast(&mut fast);
            lam += 1;
        }

        panic!("Cycle found after {power}:{lam} iterations.");
    }

    #[cfg(feature = "rng")]
    #[test]
    #[ignore]
    fn find_cycle_slow() {
        let mut rng = RapidRng::new(0);

        let mut power: u64 = 1;
        let mut lam: u64 = 1;
        let mut fast = rng.next_u64();
        let mut slow = 0;
        while fast != slow {
            if power == lam {
                slow = fast;
                power *= 2;
                lam = 0;
            }
            fast = rng.next_u64();
            lam += 1;
        }

        assert!(false, "Cycle found after {power}:{lam} iterations.");
    }

    #[cfg(feature = "rng")]
    #[test]
    fn test_construction() {
        let mut rng = RapidRng::default();
        assert_ne!(rng.next(), 0);
    }
}
