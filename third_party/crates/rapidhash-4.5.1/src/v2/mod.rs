//! Portable hashing: rapidhash V2.2 algorithm.
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
    extern crate std;

    use crate::util::macros::{compare_to_c, flip_bit_trial};
    use super::*;

    flip_bit_trial!(flip_bit_trial_v2_0, rapidhash_v2_inline::<0, true, false, false>);
    flip_bit_trial!(flip_bit_trial_v2_1, rapidhash_v2_inline::<1, true, false, false>);
    flip_bit_trial!(flip_bit_trial_v2_2, rapidhash_v2_inline::<2, true, false, false>);
    compare_to_c!(compare_to_c_v2_0, rapidhash_v2_inline::<0, true, false, false>, rapidhash_v2_inline::<0, true, true, false>, rapidhashcc_v2);
    compare_to_c!(compare_to_c_v2_1, rapidhash_v2_inline::<1, true, false, false>, rapidhash_v2_inline::<1, true, true, false>, rapidhashcc_v2_1);
    compare_to_c!(compare_to_c_v2_2, rapidhash_v2_inline::<2, true, false, false>, rapidhash_v2_inline::<2, true, true, false>, rapidhashcc_v2_2);
}
