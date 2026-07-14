// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Pkcs11 return codes and crate Result/Error types

mod rv;
mod rv_error;

pub use rv::*;
pub use rv_error::*;

use std::fmt;

use crate::context::Function;

#[derive(Debug)]
/// Main error type
pub enum Error {
    /// Any error that happens during library loading of the PKCS#11 module is encompassed under
    /// this error. It is a direct forward of the underlying error from libloading.
    LibraryLoading(libloading::Error),

    /// All PKCS#11 functions that return non-zero translate to this error.
    Pkcs11(RvError, Function),

    /// This error marks a feature that is not yet supported by the PKCS11 Rust abstraction layer.
    NotSupported,

    /// Error happening while converting types
    TryFromInt(std::num::TryFromIntError),

    /// Error when converting a slice to an array
    TryFromSlice(std::array::TryFromSliceError),

    /// Error when converting a numerical str to an integral value
    ParseInt(core::num::ParseIntError),

    /// Error converting into a type assuming valid UTF-8
    Utf8(std::str::Utf8Error),

    /// Error with nul characters in Strings
    NulError(std::ffi::NulError),

    /// Calling a PKCS11 function that is a NULL function pointer.
    NullFunctionPointer,

    /// The value is not one of those expected.
    InvalidValue,

    /// The PIN was not set before logging in.
    PinNotSet,

    /// The PKCS11 library has already been initialized
    AlreadyInitialized,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::LibraryLoading(e) => write!(f, "libloading error ({e})"),
            Error::Pkcs11(e, funct) => write!(f, "{funct}: PKCS11 error: {e}"),
            Error::NotSupported => write!(f, "Feature not supported"),
            Error::TryFromInt(e) => write!(f, "Conversion between integers failed ({e})"),
            Error::TryFromSlice(e) => write!(f, "Error converting slice to array ({e})"),
            Error::ParseInt(e) => write!(f, "Error parsing string as integer ({e})"),
            Error::Utf8(e) => write!(f, "Invalid UTF-8 ({e})"),
            Error::NulError(e) => write!(f, "An interior nul byte was found ({e})"),
            Error::NullFunctionPointer => write!(f, "Calling a NULL function pointer"),
            Error::InvalidValue => write!(f, "The value is not one of the expected options"),
            Error::PinNotSet => write!(f, "Pin has not been set before trying to log in"),
            Error::AlreadyInitialized => write!(f, "PKCS11 library has already been initialized"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::LibraryLoading(e) => Some(e),
            Error::TryFromInt(e) => Some(e),
            Error::TryFromSlice(e) => Some(e),
            Error::ParseInt(e) => Some(e),
            Error::Utf8(e) => Some(e),
            Error::NulError(e) => Some(e),
            Error::Pkcs11(_, _)
            | Error::NotSupported
            | Error::NullFunctionPointer
            | Error::PinNotSet
            | Error::InvalidValue
            | Error::AlreadyInitialized => None,
        }
    }
}

impl From<libloading::Error> for Error {
    fn from(err: libloading::Error) -> Error {
        Error::LibraryLoading(err)
    }
}

impl From<std::num::TryFromIntError> for Error {
    fn from(err: std::num::TryFromIntError) -> Error {
        Error::TryFromInt(err)
    }
}

impl From<std::array::TryFromSliceError> for Error {
    fn from(err: std::array::TryFromSliceError) -> Error {
        Error::TryFromSlice(err)
    }
}

impl From<core::num::ParseIntError> for Error {
    fn from(err: core::num::ParseIntError) -> Error {
        Error::ParseInt(err)
    }
}

impl From<std::str::Utf8Error> for Error {
    fn from(err: std::str::Utf8Error) -> Error {
        Error::Utf8(err)
    }
}

impl From<std::ffi::NulError> for Error {
    fn from(err: std::ffi::NulError) -> Error {
        Error::NulError(err)
    }
}

impl From<std::convert::Infallible> for Error {
    fn from(_err: std::convert::Infallible) -> Error {
        unreachable!()
    }
}

/// Main Result type
pub type Result<T> = core::result::Result<T, Error>;
