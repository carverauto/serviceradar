use core::hash::Hasher;
use super::DEFAULT_RAPID_SECRETS;
use super::mix_np::rapid_mix_np;
use super::rapid_const::rapidhash_core;
use super::seed::rapidhash_seed;
use crate::util::hints::likely;

/// This function needs to be as small as possible to have as high a chance of being inlined as
/// possible.
///
/// We try to generate the least amount of LLVM-IR code to reduce the inlining cost. Rust should
/// remove the const statements before generating the LLVM-IR.
macro_rules! write_num {
    ($write_num:ident, $int:ident, $unsigned:ident) => {

        /// Write an integer to the hasher, marked as `#[inline(always)]`.
        #[inline(always)]
        fn $write_num(&mut self, i: $int) {
            const N: u8 = core::mem::size_of::<$int>() as u8 * 8;
            if SPONGE {
                // This early u128 conversion seems to be important on x86, as if it impacts the
                // LLVM inlining cost too much to have it inside the if statement...
                // The compiler also converts an i32 -> i128 -> u128 unless we coerce it into its
                // unsigned type first.
                let bytes = (i as $unsigned) as u128;
                if likely(self.sponge_len + N <= 128) {
                    // HOT: add the bytes into the sponge
                    self.sponge |= bytes << self.sponge_len;
                    self.sponge_len += N;
                } else {
                    // COLD: sponge is full, so we need to flush it
                    let a = self.sponge as u64;
                    let b = (self.sponge >> 64) as u64;
                    self.seed = rapid_mix_np::<PROTECTED>(a ^ self.seed, b ^ self.secrets[0]);
                    self.sponge = bytes;
                    self.sponge_len = N;
                }
            } else {
                // slower but high-quality rapidhash
                let bytes = (i as $unsigned) as u64;
                self.seed = rapid_mix_np::<PROTECTED>(bytes ^ self.secrets[0], bytes ^ self.seed);
            }
        }
    };
}

/// A [Hasher] trait compatible hasher that uses the [rapidhash](https://github.com/Nicoshev/rapidhash)
/// algorithm, and uses `#[inline(always)]` for all methods.
///
/// Using `#[inline(always)]` can deliver a large performance improvement when hashing complex
/// objects, but should be benchmarked for your specific use case. If you have HashMaps for many
/// different types this may come at the cost of some binary size increase.
///
/// See [crate::fast::RandomState] for usage with [std::collections::HashMap].
///
/// # Example
/// ```
/// use std::hash::Hasher;
///
/// use rapidhash::quality::RapidHasher;
///
/// let mut hasher = RapidHasher::default();
/// hasher.write(b"hello world");
/// let hash = hasher.finish();
/// ```
#[derive(Copy, Clone)]
pub struct RapidHasher<'s, const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool = false, const PROTECTED: bool = false> {
    seed: u64,
    secrets: &'s [u64; 7],
    sponge: u128,
    sponge_len: u8,
}

impl<'s, const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> RapidHasher<'s, AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Default `RapidHasher` seed.
    pub const DEFAULT_SEED: u64 = super::seed::DEFAULT_SEED;

    /// Create a new [RapidHasher] with a custom seed.
    ///
    /// See instead [crate::quality::RandomState::new] or [crate::fast::RandomState::new] for a random
    /// seed and random secret initialization, for minimal DoS resistance.
    #[inline(always)]
    #[must_use]
    pub const fn new(mut seed: u64) -> Self {
        // do most of the rapidhash_seed initialization here to avoid doing it on each int
        seed = rapidhash_seed(seed);
        Self::new_precomputed_seed(seed, &DEFAULT_RAPID_SECRETS.secrets)
    }

    #[inline(always)]
    #[must_use]
    pub(super) const fn new_precomputed_seed(seed: u64, secrets: &'s [u64; 7]) -> Self {
        Self {
            seed,
            secrets,
            sponge: 0,
            sponge_len: 0,
        }
    }

    /// Create a new [RapidHasher] using the default seed and secrets.
    #[inline(always)]
    #[must_use]
    pub const fn default_const() -> Self {
        Self::new(Self::DEFAULT_SEED)
    }
}

impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> Default for RapidHasher<'_, AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Create a new [RapidHasher] with the default seed.
    ///
    /// See [crate::inner::RandomState] for a [std::hash::BuildHasher] that initializes with a random
    /// seed.
    #[inline(always)]
    fn default() -> Self {
        Self::new(super::seed::DEFAULT_SEED)
    }
}

/// This implementation implements methods for all integer types as the compiler will (hopefully...)
/// inline and heavily optimize the rapidhash_core for each. Where the bytes length is known the
/// compiler can make significant optimisations and saves us writing them out by hand.
impl<const AVALANCHE: bool, const SPONGE: bool, const COMPACT: bool, const PROTECTED: bool> Hasher for RapidHasher<'_, AVALANCHE, SPONGE, COMPACT, PROTECTED> {
    /// Produce the final hash value, marked as `#[inline(always)]`.
    #[inline(always)]
    fn finish(&self) -> u64 {
        // written to minimise the LLVM-IR lines, as rust should remove the const if statements
        #[allow(clippy::collapsible_else_if)]
        if SPONGE {
            if !AVALANCHE {
                if self.sponge_len > 0 {
                    let a = self.sponge as u64;
                    let b = (self.sponge >> 64) as u64;
                    rapid_mix_np::<PROTECTED>(a ^ self.seed, b ^ self.secrets[0])
                } else {
                    self.seed
                }
            } else {
                let mut seed = self.seed;
                if self.sponge_len > 0 {
                    let a = self.sponge as u64;
                    let b = (self.sponge >> 64) as u64;
                    seed = rapid_mix_np::<PROTECTED>(a ^ self.seed, b ^ self.secrets[0]);
                }
                // FUTURE: revisit when write_str is stable, as we'd want to move this into the
                // above if statement
                rapid_mix_np::<PROTECTED>(seed, DEFAULT_RAPID_SECRETS.secrets[1])
            }
        } else {
            if !AVALANCHE {
                self.seed
            } else {
                rapid_mix_np::<PROTECTED>(self.seed, DEFAULT_RAPID_SECRETS.secrets[1])
            }
        }
    }

    /// Write a byte slice to the hasher, marked as `#[inline(always)]`.
    #[inline(always)]
    fn write(&mut self, bytes: &[u8]) {
        self.seed = rapidhash_core::<AVALANCHE, COMPACT, PROTECTED>(self.seed, self.secrets, bytes);
    }

    write_num!(write_u8, u8, u8);
    write_num!(write_u16, u16, u16);
    write_num!(write_u32, u32, u32);
    write_num!(write_u64, u64, u64);
    write_num!(write_usize, usize, usize);
    write_num!(write_i8, i8, u8);
    write_num!(write_i16, i16, u16);
    write_num!(write_i32, i32, u32);
    write_num!(write_i64, i64, u64);
    write_num!(write_isize, isize, usize);

    /// Write an int to the hasher, marked as `#[inline(always)]`.
    #[inline(always)]
    fn write_u128(&mut self, i: u128) {
        let a = i as u64;
        let b = (i >> 64) as u64;
        self.seed = rapid_mix_np::<PROTECTED>(a ^ self.seed, b ^ self.secrets[0]);
    }

    /// Write an int to the hasher, marked as `#[inline(always)]`.
    #[inline(always)]
    fn write_i128(&mut self, i: i128) {
        let a = (i as u128) as u64;
        let b = (i as u128 >> 64) as u64;
        self.seed = rapid_mix_np::<PROTECTED>(a ^ self.seed, b ^ self.secrets[0]);
    }

    /// Write a length prefix to the hasher, marked as `#[inline(always)]`.
    #[cfg(feature = "nightly")]
    #[inline(always)]
    fn write_length_prefix(&mut self, len: usize) {
        self.write_usize(len);
    }

    /// Write a string to the hasher, without adding a length prefix as rapidhash already mixes in
    /// the byte length to prevent length extension attacks, marked as `#[inline(always)]`.
    #[cfg(feature = "nightly")]
    #[inline(always)]
    fn write_str(&mut self, s: &str) {
        self.write(s.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    extern crate std;

    use std::hash::BuildHasher;
    use crate::fast::SeedableState;
    use super::*;

    #[test]
    fn test_hasher_size() {
        assert_eq!(core::mem::size_of::<RapidHasher::<true, true, false, false>>(), 48);
    }

    /// Test that writing a single u64 outputs the same as writing the equivalent bytes.
    ///
    /// Does not apply if the algorithm is using a sponge.
    #[ignore]
    #[test]
    fn test_hasher_write_u64() {
        assert_eq!((8 & 24) >> (8 >> 3), 4);

        let ints = [1234u64, 0, 1, u64::MAX, u64::MAX - 2385962040453523];

        for int in ints {
            let mut hasher = RapidHasher::<true, false>::default();
            hasher.write(int.to_le_bytes().as_slice());
            let a = hasher.finish();

            assert_eq!(int.to_le_bytes().as_slice().len(), 8);

            let mut hasher = RapidHasher::<true, false>::default();
            hasher.write_u64(int);
            let b = hasher.finish();

            assert_eq!(a, b, "Mismatching hash for u64 with input {int}");
        }
    }

    /// Check the number of collisions when writing numbers.
    #[test]
    #[ignore]
    #[cfg(feature = "std")]
    fn test_num_collisions() {
        let builder = SeedableState::default();
        let mut collisions = 0;
        let mut set = std::collections::HashSet::new();
        for i in 0..=u16::MAX {
            let hash_u16 = builder.hash_one(i) & 0xFFFFFF;
            if set.contains(&hash_u16) {
                collisions += 1;
            } else {
                set.insert(hash_u16);
            }

            // if i < 256 {
            //     let hash_u8 = builder.hash_one(i as u8) & 0xFFFF;
            //     if set.contains(&hash_u8) {
            //         collisions += 1;
            //     } else {
            //         set.insert(hash_u8);
            //     }
            // }
        }
        assert_eq!(collisions, 0, "Collisions found when hashing numbers with seed {builder:?}");
    }
}
