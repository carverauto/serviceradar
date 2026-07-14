//! In-memory hashing: RapidHasher with full configurability via compile-time arguments.
//!
//! This module contains the Hasher, BuildHasher, HashMap, HashSet, and RandomState
//! implementations. It is recommended to use [crate::fast] or [crate::quality], but for the
//! advanced user, [crate::inner] can be used directly to customise the compile time options to
//! modify the hash function.
//!
//! Each structure may have the compile time const generics:
//! - `AVALANCHE`: Whether to use a final avalanche mix step, required to pass SMHasher3. This
//!   option changes the hash output. Enabled on [crate::quality], disabled on [crate::fast].
//! - `SPONGE`: Allow RapidHasher to cache integers into a 128-bit buffer to perform a single
//!   folded multiply step on the entire buffer. If disabled, a mix step is performed on each
//!   individual integer. This changes the hash output when hashing integers. Enabled on both
//!   [crate::quality] and [crate::fast].
//! - `COMPACT`: Reduce the code size of the hasher by preventing manually unrolled loops. This does
//!   _not_ affect the hash output. Disabled on both [crate::quality] and [crate::fast].
//! - `PROTECTED`: When performing the folded multiply mix step, XOR the a and b back into their
//!   original values to make it harder for an attacker to generate collisions. This changes the
//!   hash ouput. Disabled on both [crate::quality] and [crate::fast].
//!
//! The `RapidHasher` struct is _inspired by_ rapidhash, but is not a direct port and will output
//! different hash values. It keeps the same hasher quality but uses various optimisations to
//! improve performance when used in the Rust Hasher trait.
//!
//! The output values of functions in the `inner` module are not guaranteed to be stable between
//! versions. Please use the `v1`, `v2`, or `v3` modules for stable output values between rapidhash
//! crate versions.


mod rapid_const;
mod rapid_hasher;
mod state;
pub(crate) mod seeding;
mod mix_np;
mod seed;
mod read_np;

#[doc(inline)]
pub use rapid_hasher::*;
#[doc(inline)]
pub use state::*;
#[doc(inline)]
use seed::*;

#[cfg(test)]
mod tests {
    extern crate std;

    use std::hash::{BuildHasher, Hash, Hasher};
    use std::collections::BTreeSet;
    use rand::Rng;
    use crate::inner::mix_np::rapid_mix_np;
    use super::seed::{DEFAULT_RAPID_SECRETS, DEFAULT_SEED};
    use super::rapid_const::{rapidhash_rs, rapidhash_rs_seeded};

    type RapidHasher = super::RapidHasher<'static, true, true, true, false>;
    type SeedableState = super::SeedableState<'static, true, true, true, false>;

    #[derive(Hash)]
    struct Object {
        string: &'static str,
    }

    /// `#[derive(Hash)]` writes a length prefix first, check understanding.
    #[cfg(target_endian = "little")]
    #[test]
    fn derive_hash_works() {
        #[cfg(not(feature = "nightly"))]
        const EXPECTED: u64 = 7608958509739739138;

        #[cfg(feature = "nightly")]
        const EXPECTED: u64 = 8977256838778740407;

        let object = Object { string: "hello world" };
        let mut hasher = RapidHasher::default();
        object.hash(&mut hasher);
        assert_eq!(hasher.finish(), EXPECTED);

        let mut hasher = RapidHasher::default();
        hasher.write(object.string.as_bytes());
        #[cfg(not(feature = "nightly"))] {
            hasher.write_u8(0xFF);
        }
        assert_eq!(hasher.finish(), EXPECTED);
    }

    /// Check RapidHasher is equivalent to the raw rapidhash for a single byte stream.
    ///
    /// Also check that the hash is unique for different byte streams.
    #[test]
    fn all_sizes() {
        let mut hashes = BTreeSet::new();

        for size in 0..=1024 {
            let mut data = std::vec![0; size];
            rand::rng().fill(data.as_mut_slice());

            let hash1 = rapidhash_rs(&data);
            let mut hasher = RapidHasher::default();
            hasher.write(&data);
            let hash2 = hasher.finish();

            assert_eq!(hash1, hash2, "Failed on size {}", size);
            assert!(!hashes.contains(&hash1), "Duplicate for size {}", size);

            hashes.insert(hash1);
        }
    }

    /// Ensure that changing a single bit flips at least 10 bits in the resulting hash, and on
    /// average flips half of the bits.
    ///
    /// These tests are not deterministic, but should fail with a very low probability.
    #[test]
    fn flip_bit_trial() {
        use rand::Rng;

        let mut flips = std::vec![];

        for len in 1..=512 {
            let mut data = std::vec![0; len];
            rand::rng().fill(&mut data[..]);

            let hash = rapidhash_rs(&data);
            for byte in 0..len {
                for bit in 0..8 {
                    let mut data = data.clone();
                    data[byte] ^= 1 << bit;
                    let new_hash = rapidhash_rs(&data);
                    assert_ne!(hash, new_hash, "Flipping byte {} bit {} did not change hash for input len {}", byte, bit, len);
                    let xor = hash ^ new_hash;
                    let flipped = xor.count_ones() as u64;
                    assert!(xor.count_ones() >= 8, "Flipping bit {byte}:{bit} changed only {flipped} bits");

                    flips.push(flipped);
                }
            }
        }

        let average = flips.iter().sum::<u64>() as f64 / flips.len() as f64;
        assert!(average > 31.95 && average < 32.05, "Did not flip an average of half the bits. average: {average}, expected: 32.0");
    }

    /// Helper method for [flip_bit_trial_streaming]. Hashes a byte stream in u8 chunks.
    fn streaming_hash(data: &[u8]) -> u64 {
        let mut hasher = RapidHasher::default();
        for byte in data {
            hasher.write_u8(*byte);
        }
        hasher.finish()
    }

    /// Ensure various subsequent `write_u8` calls produce a stable result.
    ///
    /// Used to help diagnose an issue using rapidhash for PHF.
    #[test]
    fn sponge_buffer_stability() {
        use std::collections::HashSet;

        /// Simulate the UniCase Ascii/Unicode string hashing
        fn manual_string_hash(data: &[u8]) -> u64 {
            // ensure avalanche is disabled, sponge enabled to match PHF
            let mut hasher = crate::inner::SeedableState::<'static, false, true, false, false>::fixed().build_hasher();
            for byte in data {
                hasher.write_u8(*byte);
            }
            hasher.write_u8(0xFF); // prefix freedom
            hasher.finish()
        }

        let mut hashes = HashSet::new();

        for len in 1..=64 {
            for byte in 0u8..=255 {
                // don't randomized the data, simply extend an extra byte each time
                let data = std::vec![byte; len];

                let hash1 = manual_string_hash(&data);
                let hash2 = manual_string_hash(&data);
                assert_eq!(hash1, hash2, "Mismatch for length {}", len);

                assert!(!hashes.contains(&hash1), "Duplicate hash at length {}", len);
                hashes.insert(hash1);
            }
        }
    }

    /// The same as [flip_bit_trial], but against our streaming implementation, to ensure that
    /// reusing the `a`, `b`, and `seed` state is not causing glaringly obvious issues.
    ///
    /// This test is not a substitute for SMHasher or similar.
    ///
    /// These tests are not deterministic, but should fail with a very low probability.
    #[test]
    fn flip_bit_trial_streaming() {
        use rand::Rng;

        let mut flips = std::vec![];

        for len in 1..=300 {
            let mut data = std::vec![0; len];
            rand::rng().fill(&mut data[..]);

            let hash = streaming_hash(&data);
            for byte in 0..len {
                for bit in 0..8 {
                    let mut data = data.clone();
                    data[byte] ^= 1 << bit;

                    // check that the hash changed
                    let new_hash = streaming_hash(&data);
                    assert_ne!(hash, new_hash, "Flipping bit {byte}:{bit} for input len {len} did not change hash");

                    // track how many bits were flipped
                    let xor = hash ^ new_hash;
                    let flipped = xor.count_ones() as u64;
                    assert!(xor.count_ones() >= 8, "Flipping bit {byte}:{bit} for input len {len} changed only {flipped} bits");
                    flips.push(flipped);
                }
            }
        }

        // check that on average half of the bits were flipped
        let average = flips.iter().sum::<u64>() as f64 / flips.len() as f64;
        assert!(average > 31.95 && average < 32.05, "Did not flip an average of half the bits. average: {average}, expected: 32.0");
    }

    /// Compare to the C rapidhash implementation to ensure we match perfectly.
    #[cfg(target_endian = "little")]
    #[test]
    fn compare_to_c() {
        use rand::Rng;
        use rapidhash_c::rapidhashcc_rs;

        for len in 0..=512 {
            let mut data = std::vec![0; len];
            rand::rng().fill(&mut data[..]);

            for byte in 0..len {
                for bit in 0..8 {
                    let mut data = data.clone();
                    data[byte] ^= 1 << bit;

                    let rust_hash = rapidhash_rs_seeded(&data, &DEFAULT_RAPID_SECRETS);
                    let mut c_hash = rapidhashcc_rs(&data, DEFAULT_SEED);
                    // TODO: remove this hack; it's to make it work with how the Hasher avalanches
                    c_hash = rapid_mix_np::<false>(c_hash, DEFAULT_RAPID_SECRETS.secrets[1]);
                    assert_eq!(rust_hash, c_hash, "Mismatch with input {} byte {} bit {}", len, byte, bit);

                    let mut rust_hasher = SeedableState::fixed().build_hasher();
                    rust_hasher.write(&data);
                    let rust_hasher_hash = rust_hasher.finish();
                    assert_eq!(rust_hash, rust_hasher_hash, "Hasher mismatch with input {} byte {} bit {}", len, byte, bit);
                }
            }
        }
    }

    #[test]
    fn disambiguation_check() {
        use std::vec::Vec;

        let hasher = SeedableState::default();

        let a = [std::vec![1], std::vec![2, 3]];
        let b = [std::vec![1, 2], std::vec![3]];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = [std::vec![], std::vec![1]];
        let b = [std::vec![1],  std::vec![]];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a: [Vec<Vec<u64>>; 2] = [std::vec![], std::vec![std::vec![]]];
        let b: [Vec<Vec<u64>>; 2] = [std::vec![std::vec![]], std::vec![]];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = ["abc", "def"];
        let b = ["fed", "abc"];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = ["abc", "def"];
        let b = ["abcd", "ef"];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = [1u8, 2];
        let b = [2u8, 1];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = [1u16, 2];
        let b = [2u16, 1];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = [1u32, 2];
        let b = [2u32, 1];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = [1u64, 2];
        let b = [2u64, 1];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));

        let a = [1u128, 2];
        let b = [2u128, 1];
        assert_ne!(hasher.hash_one(a), hasher.hash_one(b));
    }
}
