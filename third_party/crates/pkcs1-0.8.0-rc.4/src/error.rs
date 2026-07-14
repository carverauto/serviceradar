//! Error types

use core::fmt;

#[cfg(feature = "pem")]
use der::pem;

/// Result type
pub type Result<T> = core::result::Result<T, Error>;

/// Error type
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Error {
    /// ASN.1 DER-related errors.
    Asn1(der::Error),

    /// Cryptographic errors.
    ///
    /// These can be used by RSA implementations to signal that a key is
    /// invalid for cryptographic reasons. This means the document parsed
    /// correctly, but one of the values contained within was invalid, e.g.
    /// a number expected to be a prime was not a prime.
    Crypto,

    /// Malformed cryptographic key contained in a PKCS#1 document.
    ///
    /// This is intended for relaying errors when decoding fields of a PKCS#1 document.
    KeyMalformed,

    /// Version errors
    Version,
}

impl core::error::Error for Error {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        match self {
            Error::Asn1(err) => Some(err),
            _ => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Asn1(err) => write!(f, "PKCS#1 ASN.1 error: {err}"),
            Error::KeyMalformed => f.write_str("PKCS#1 cryptographic key data malformed"),
            Error::Crypto => f.write_str("PKCS#1 cryptographic error"),
            Error::Version => f.write_str("PKCS#1 version error"),
        }
    }
}

impl From<der::Error> for Error {
    fn from(err: der::Error) -> Error {
        Error::Asn1(err)
    }
}

#[cfg(feature = "pem")]
impl From<pem::Error> for Error {
    fn from(err: pem::Error) -> Error {
        der::Error::from(err).into()
    }
}
