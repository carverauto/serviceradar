//! Portable hashing: rapidhash V1 algorithm.
//!
//! For new code, please use [`crate::v3`] instead, as it is a superior hashing algorithm.

mod rapid_const;
#[cfg(any(feature = "std", docsrs))]
mod rapid_file;
mod seed;

#[doc(inline)]
pub use rapid_const::*;
#[doc(inline)]
#[cfg(any(feature = "std", docsrs))]
pub use rapid_file::*;
#[doc(inline)]
pub use seed::*;

#[cfg(test)]
mod tests {
    #![allow(deprecated)]

    extern crate std;

    use crate::util::macros::{compare_to_c, flip_bit_trial};
    use super::*;

    flip_bit_trial!(flip_bit_trial_v1, rapidhash_v1_inline::<true, false, false, false>);
    flip_bit_trial!(flip_bit_trial_v1_bug, rapidhash_v1_inline::<true, false, false, true>);
    compare_to_c!(compare_to_c_v1, rapidhash_v1_inline::<true, false, false, false>, rapidhash_v1_inline::<true, true, false, false>, rapidhashcc_v1);

    #[test]
    fn test_v1_bug() {
        fn rapidhash_bug(data: &str) -> u64 {
            rapidhash_v1_inline::<true, false, false, true>(data.as_bytes(), &DEFAULT_RAPID_SECRETS)
        }

        // The v1.x.x bug was for the 48-byte case
        // The v2.x.x attempted fix ended up not hashing a bunch of data beyond 48 bytes... :facepalm:
        assert_eq!(5006746792674864303, rapidhash_bug("\n"));
        assert_eq!(4933522537766704430, rapidhash_bug("abcdef\n"));
        assert_eq!(3345456103814863532, rapidhash_bug("abcdefghijklmnopqrstuvwxyz12345678901234567890\n"));
        assert_eq!(8825074939507110130, rapidhash_bug("abcdefghijklmnopqrstuvwxyz123456789012345678901\n"));
        assert_eq!(2762901732509801681, rapidhash_bug("abcdefghijklmnopqrstuvwxyz1234567890123456789012\n"));
        assert_eq!( 934306286158757431, rapidhash_bug("abcdefghijklmnopqrstuvwxyz12345678901234567890123\n"));
    }

    #[test]
    fn test_hardcoded_v1() {
        assert_eq!(6516417773221693515, rapidhash_v1(&[]));
        assert_eq!(5006746792674864303, rapidhash_v1("\n".as_bytes()));
        assert_eq!(15965596575264898037, rapidhash_v1("something\n".as_bytes()));
        // below is 47 bytes, an extra character would hit the V1 bug
        assert_eq!(10644405912457645442, rapidhash_v1("abcdefghijklmnopqrstuvwxyz01234567890123456789\n".as_bytes()));
        assert_eq!(7545813847373533788, rapidhash_v1("abcdefghijklmnopqrstuvwxyz012345678901234567890abcdefghijklmnopqrstuvwxyz012345678901234567890abcdefghijklmnopqrstuvwxyz012345678901234567890\n".as_bytes()));
    }
}
