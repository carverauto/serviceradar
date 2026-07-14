//! # Error wrappers and boilerplate
//!
//! This module provides some basic boilerplate for errors. As a consumer of this
//! library, you should expect that all public functions return a `Result` type
//! using this local `Error`, which implements the standard Error trait.
//! As a general rule, errors that come from dependent crates are wrapped by
//! this crate's error type.
#![allow(unused_macros)]

use core::fmt;
use signatory::signature;

use std::{
    error::Error as StdError,
    string::{String, ToString},
};

/// Provides an error type specific to the nkeys library
#[derive(Debug)]
pub struct Error {
    kind: ErrorKind,

    description: Option<String>,
}

/// Provides context as to how a particular nkeys error might have occurred
#[derive(Debug, Copy, Clone, PartialEq)]
pub enum ErrorKind {
    /// Indicates an inappropriate byte prefix was used for an encoded key string
    InvalidPrefix,
    /// Indicates a key string was used with the wrong length
    InvalidKeyLength,
    /// Indicates a signature verification mismatch. Use this to check for invalid signatures or messages
    VerifyError,
    /// Indicates an unexpected underlying error occurred while trying to perform routine signature tasks.
    SignatureError,
    /// Indicates a checksum mismatch occurred while validating a crc-encoded string
    ChecksumFailure,
    /// Indicates a miscellaneous error occurred during encoding or decoding the nkey-specific formats
    CodecFailure,
    /// Indicates a key type mismatch, e.g. attempting to sign with only a public key
    IncorrectKeyType,
    /// Payload not valid (or failed to be decrypted)
    InvalidPayload,
    /// Signature did not match the expected length (64 bytes)
    InvalidSignatureLength,
}

/// A handy macro borrowed from the `signatory` crate that lets library-internal code generate
/// more readable exception handling flows
#[macro_export]
macro_rules! err {
    ($variant:ident, $msg:expr) => {
        $crate::error::Error::new(
            $crate::error::ErrorKind::$variant,
            Some($msg)
        )
    };
    ($variant:ident, $fmt:expr, $($arg:tt)+) => {
        err!($variant, &format!($fmt, $($arg)+))
    };
}

impl ErrorKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorKind::InvalidPrefix => "Invalid byte prefix",
            ErrorKind::InvalidKeyLength => "Invalid key length",
            ErrorKind::InvalidSignatureLength => "Invalid signature length",
            ErrorKind::VerifyError => "Signature verification failure",
            ErrorKind::ChecksumFailure => "Checksum match failure",
            ErrorKind::CodecFailure => "Codec failure",
            ErrorKind::SignatureError => "Signature failure",
            ErrorKind::IncorrectKeyType => "Incorrect key type",
            ErrorKind::InvalidPayload => "Invalid payload",
        }
    }
}

impl fmt::Display for ErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl Error {
    /// Creates a new nkeys error wrapper
    pub fn new(kind: ErrorKind, description: Option<&str>) -> Self {
        Error {
            kind,
            description: description.map(|desc| desc.to_string()),
        }
    }

    /// An accessor exposing the error kind enum. Crate consumers should have little to no
    /// need to access this directly and it's mostly used to assert that internal functions
    /// are creating appropriate error wrappers.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }
}

/// Creates an nkeys error derived from an error that came from the `signatory` crate
impl From<signature::Error> for Error {
    fn from(source: signature::Error) -> Error {
        err!(SignatureError, &format!("Signature error: {}", source))
    }
}

/// Creates an nkeys error derived from a decoding failure in the `data_encoding` crate
impl From<data_encoding::DecodeError> for Error {
    fn from(source: data_encoding::DecodeError) -> Error {
        err!(CodecFailure, "Data encoding failure: {}", source)
    }
}

impl StdError for Error {
    fn description(&self) -> &str {
        if let Some(ref desc) = self.description {
            desc
        } else {
            self.kind.as_str()
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.description {
            Some(ref desc) => write!(f, "{}: {}", self.kind.as_str(), desc),
            None => write!(f, "{}", self.kind.as_str()),
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_error_to_string() {
        assert_eq!(
            err!(InvalidKeyLength, "Testing").to_string(),
            "Invalid key length: Testing"
        );
        assert_eq!(
            err!(InvalidKeyLength, "Testing {}", 1).to_string(),
            "Invalid key length: Testing 1"
        );
    }
}
