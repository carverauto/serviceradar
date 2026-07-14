use core::fmt;

/// Error that is returned when supplied pseudorandom key (PRK) is not long enough.
#[derive(Copy, Clone, Debug)]
pub struct InvalidPrkLength;

impl fmt::Display for InvalidPrkLength {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        f.write_str("invalid pseudorandom key length, too short")
    }
}

impl core::error::Error for InvalidPrkLength {}

/// Structure for InvalidLength, used for output error handling.
#[derive(Copy, Clone, Debug)]
pub struct InvalidLength;

impl fmt::Display for InvalidLength {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
        f.write_str("invalid number of blocks, too large output")
    }
}

impl core::error::Error for InvalidLength {}
