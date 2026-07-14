use core::fmt;

/// Errors emitted from the wrap and unwrap operations.
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// Input data length invalid.
    InvalidDataSize,

    /// Output buffer size invalid.
    InvalidOutputSize {
        /// Expected size in bytes.
        expected_len: usize,
    },

    /// Integrity check did not pass.
    IntegrityCheckFailed,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidDataSize => f.write_str("data must be a multiple of 64 bits for AES-KW and less than 2^32 bytes for AES-KWP"),
            Error::InvalidOutputSize { expected_len: expected } => {
                write!(f, "invalid output buffer size: expected {}", expected)
            }
            Error::IntegrityCheckFailed => f.write_str("integrity check failed"),
        }
    }
}

impl core::error::Error for Error {}

/// Error that indicates integrity check failure.
#[derive(Clone, Copy, Debug)]
pub struct IntegrityCheckFailed;

impl fmt::Display for IntegrityCheckFailed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("integrity check failed")
    }
}

impl core::error::Error for IntegrityCheckFailed {}
