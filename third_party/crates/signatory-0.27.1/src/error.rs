//! Error type

use core::fmt::{self, Display};

/// Result type
pub type Result<T> = core::result::Result<T, Error>;

/// Error type
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// Algorithm is invalid.
    AlgorithmInvalid,

    /// Duplicate key in keyring.
    DuplicateKey,

    /// ECDSA errors.
    #[cfg(feature = "ecdsa")]
    Ecdsa,

    /// Key name is invalid.
    KeyNameInvalid,

    /// I/O errors
    #[cfg(feature = "std")]
    Io(std::io::Error),

    /// Expected a directory, found something else
    #[cfg(feature = "std")]
    NotADirectory,

    /// Parse errors for raw/non-PKCS#8 keys.
    Parse,

    /// Permissions error, not required mode
    #[cfg(feature = "std")]
    Permissions,

    /// PKCS#8 errors
    Pkcs8(pkcs8::Error),
}

impl Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlgorithmInvalid => f.write_str("invalid algorithm"),
            Self::DuplicateKey => f.write_str("duplicate key"),
            #[cfg(feature = "ecdsa")]
            Self::Ecdsa => f.write_str("ECDSA error"),
            Self::KeyNameInvalid => f.write_str("invalid key name"),
            #[cfg(feature = "std")]
            Self::Io(err) => write!(f, "{}", err),
            #[cfg(feature = "std")]
            Self::NotADirectory => f.write_str("not a directory"),
            Self::Parse => f.write_str("parse error"),
            #[cfg(feature = "std")]
            Self::Permissions => f.write_str("invalid file permissions"),
            Self::Pkcs8(err) => write!(f, "{}", err),
        }
    }
}

#[cfg(feature = "std")]
impl std::error::Error for Error {}

#[cfg(feature = "ecdsa")]
impl From<ecdsa::Error> for Error {
    fn from(_: ecdsa::Error) -> Error {
        Error::Ecdsa
    }
}

impl From<pkcs8::Error> for Error {
    fn from(err: pkcs8::Error) -> Error {
        Error::Pkcs8(err)
    }
}

impl From<pkcs8::der::Error> for Error {
    fn from(err: pkcs8::der::Error) -> Error {
        Error::Pkcs8(err.into())
    }
}

impl From<pkcs8::der::pem::Error> for Error {
    fn from(err: pkcs8::der::pem::Error) -> Error {
        pkcs8::der::Error::from(err).into()
    }
}

#[cfg(feature = "std")]
impl From<std::io::Error> for Error {
    fn from(err: std::io::Error) -> Error {
        Error::Io(err)
    }
}
