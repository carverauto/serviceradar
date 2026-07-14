use alloc::borrow::Cow;
use core::fmt;
#[cfg(feature = "std")]
use std::io::Error as IoError;

#[cfg(not(feature = "std"))]
#[derive(Clone, PartialEq, Eq, Debug)]
pub(crate) struct IoError(Cow<'static, str>);

#[cfg(not(feature = "std"))]
impl fmt::Display for IoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

/// An I/O error; can be converted to [`std::io::Error`].
#[derive(Debug)]
pub struct Error(IoError);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

#[cfg(feature = "std")]
impl std::error::Error for Error {}
#[cfg(not(feature = "std"))]
impl core::error::Error for Error {}

#[allow(dead_code)]
impl Error {
    pub(crate) fn new(message: &'static str) -> Self {
        #[cfg(not(feature = "std"))]
        {
            Self::from_io(IoError(message.into()))
        }

        #[cfg(feature = "std")]
        {
            Self::from_io(IoError::new(std::io::ErrorKind::NotFound, message))
        }
    }

    pub(crate) fn with_invalid_data(
        message: impl Into<Cow<'static, str>>,
    ) -> Self {
        let message = message.into();

        #[cfg(not(feature = "std"))]
        {
            Self::from_io(IoError(message))
        }

        #[cfg(feature = "std")]
        {
            Self::from_io(IoError::new(
                std::io::ErrorKind::InvalidData,
                message,
            ))
        }
    }

    pub(crate) fn from_io(err: IoError) -> Self {
        Self(err)
    }

    pub(crate) fn missing_record() -> Self {
        Self::new("Missing record")
    }

    pub(crate) fn null_record() -> Self {
        Self::new("Null record")
    }

    pub(crate) fn empty_record() -> Self {
        Self::new("Empty record")
    }

    pub(crate) fn permission_denied() -> Self {
        #[cfg(not(feature = "std"))]
        {
            Self::from_io(IoError("Permission denied".into()))
        }

        #[cfg(feature = "std")]
        {
            Self::from_io(IoError::new(
                std::io::ErrorKind::PermissionDenied,
                "Permission denied",
            ))
        }
    }
}

impl From<Error> for IoError {
    fn from(err: Error) -> Self {
        err.0
    }
}
