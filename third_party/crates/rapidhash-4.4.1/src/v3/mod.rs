//! Portable hashing: rapidhash V3 algorithm.

mod rapid_const;
#[cfg(any(feature = "std", docsrs))]
mod rapid_file;
mod seed;
mod rapid_stream_hasher;

#[doc(inline)]
pub use rapid_const::*;

#[doc(inline)]
#[cfg(any(feature = "std", docsrs))]
pub use rapid_file::*;

#[doc(inline)]
pub use rapid_stream_hasher::*;

#[doc(inline)]
pub use seed::*;

#[cfg(test)]
mod tests {
    extern crate std;

    use rand::Rng;
    use crate::util::macros::{compare_to_c, flip_bit_trial};
    use super::*;

    flip_bit_trial!(flip_bit_trial_v3, rapidhash_v3_inline::<true, false, false>);
    flip_bit_trial!(flip_bit_trial_v3_micro, rapidhash_v3_micro_inline::<true, false>);
    flip_bit_trial!(flip_bit_trial_v3_nano, rapidhash_v3_nano_inline::<true, false>);
    compare_to_c!(compare_to_c_v3, rapidhash_v3_inline::<true, false, false>, rapidhash_v3_inline::<true, true, false>, rapidhashcc_v3);
    compare_to_c!(compare_to_c_v3_micro, rapidhash_v3_micro_inline::<true, false>, rapidhash_v3_micro_inline::<true, false>, rapidhashcc_v3_micro);
    compare_to_c!(compare_to_c_v3_nano, rapidhash_v3_nano_inline::<true, false>, rapidhash_v3_nano_inline::<true, false>, rapidhashcc_v3_nano);

    /// Compare the main rapidhash version matches micro (80 btyes) and nano (48 bytes) up to
    /// the expected length.
    #[test]
    fn compare_micro_nano_v3() {
        // test zero-length input
        let hash_v3 = rapidhash_v3_inline::<true, false, false>(&[], &DEFAULT_RAPID_SECRETS);
        let hash_micro = rapidhash_v3_micro_inline::<true, false>(&[], &DEFAULT_RAPID_SECRETS);
        let hash_nano = rapidhash_v3_nano_inline::<true, false>(&[], &DEFAULT_RAPID_SECRETS);
        assert_eq!(hash_v3, hash_micro, "Mismatch with micro on zero length input");
        assert_eq!(hash_v3, hash_nano, "Mismatch with nano on zero length input");

        for len in 0..=82 {
            let mut data = std::vec![0; len];
            rand::rng().fill(&mut data[..]);

            for byte in 0..len {
                for bit in 0..8 {
                    let mut data = data.clone();
                    data[byte] ^= 1 << bit;

                    let hash_v3 = rapidhash_v3_inline::<true, false, false>(&data, &DEFAULT_RAPID_SECRETS);
                    let hash_micro = rapidhash_v3_micro_inline::<true, false>(&data, &DEFAULT_RAPID_SECRETS);
                    let hash_nano = rapidhash_v3_nano_inline::<true, false>(&data, &DEFAULT_RAPID_SECRETS);

                    if len <= 80 {
                        assert_eq!(hash_v3, hash_micro, "Mismatch with mico on input {} byte {} bit {}", len, byte, bit);
                    } else {
                        assert_ne!(hash_v3, hash_micro, "Micro should mismatch on input {} byte {} bit {}", len, byte, bit);
                    }

                    if len <= 48 {
                        assert_eq!(hash_v3, hash_nano, "Mismatch with nano on input {} byte {} bit {}", len, byte, bit);
                    } else {
                        assert_ne!(hash_v3, hash_nano, "Nano should mismatch on input {} byte {} bit {}", len, byte, bit);
                    }
                }
            }
        }
    }
}
