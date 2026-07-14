use core::ops::RangeInclusive;

use crate::{Error, ErrorKind, Tag};

/// Trait on automatically derived by BitString macro.
/// Used for checking if binary data fits into defined struct.
///
/// ```
/// /// Bit length of 2
/// struct MyBitString {
///     flag1: bool,
///     flag2: bool,
/// }
/// ```
///
/// ```rust,ignore
/// use der::BitString;
///
/// /// Bit length of 3..=4
/// #[derive(BitString)]
/// struct MyBitString {
///     flag1: bool,
///     flag2: bool,
///     flag3: bool,
///
///     #[asn1(optional = "true")]
///     flag4: bool,
/// }
/// ```
pub trait AllowedLenBitString {
    /// Implementer must specify how many bits are allowed
    const ALLOWED_LEN_RANGE: RangeInclusive<u16>;

    /// Returns an error if the bitstring is not in expected length range
    fn check_bit_len(bit_len: u16) -> Result<(), Error> {
        let allowed_len_range = Self::ALLOWED_LEN_RANGE;

        // forces allowed range to e.g. 3..=4
        if !allowed_len_range.contains(&bit_len) {
            Err(ErrorKind::Length {
                tag: Tag::BitString,
            }
            .into())
        } else {
            Ok(())
        }
    }
}
