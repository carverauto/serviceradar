use core::fmt;

use crate::Flavor;

/// Errors returned by the crate's API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// The requested bit length of the candidate is larger than the maximum size of the target integer type.
    BitLengthTooLarge {
        /// The requested bit length.
        bit_length: u32,
        /// The maximum size of the integer type.
        bits_precision: u32,
    },
    /// The requested bit length is too small to fit a prime of the chosen [`Flavor`](`crate::Flavor`).
    BitLengthTooSmall {
        /// The requested bit length.
        bit_length: u32,
        /// The requested flavor.
        flavor: Flavor,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        match self {
            Error::BitLengthTooLarge {
                bit_length,
                bits_precision,
            } => write!(
                f,
                concat![
                    "The requested bit length of the candidate ({}) ",
                    "is larger than the maximum size of the target integer type ({})."
                ],
                bit_length, bits_precision
            ),
            Error::BitLengthTooSmall { bit_length, flavor } => write!(
                f,
                concat![
                    "The requested bit length of the candidate ({}) ",
                    "is too small to fit a prime of the flavor {:?}",
                ],
                bit_length, flavor
            ),
        }
    }
}
