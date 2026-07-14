use std::{
	error,
	fmt,
	io,
};

use crate::ffi;

/// API Error
pub enum Error {
	/// If error code used some recognized name
	KnownError(ffi::DNSServiceError),
	/// Unrecognized error codes
	UnknownError(i32),
	/// IO error
	IoError(io::Error),
}

impl Error {
	/// Check if a raw error code represents an error, and convert it
	/// accordingly.  (Not all codes are treated as an error, including
	/// `0`).
	pub fn from(value: ffi::DNSServiceErrorType) -> Result<(), Self> {
		if ffi::DNSServiceNoError::try_from(value).is_some() {
			Ok(())
		} else {
			match ffi::DNSServiceError::try_from(value) {
				Some(e) => Err(Self::KnownError(e)),
				None => Err(Self::UnknownError(value)),
			}
		}
	}
}

impl From<io::Error> for Error {
	fn from(e: io::Error) -> Self {
		Self::IoError(e)
	}
}

impl From<Error> for io::Error {
	fn from(e: Error) -> Self {
		match e {
			Error::IoError(e) => e,
			e => Self::new(io::ErrorKind::Other, e),
		}
	}
}

impl fmt::Debug for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::KnownError(ffi_err) => write!(f, "known error {:?}: {}", ffi_err, ffi_err),
			Self::UnknownError(e) => write!(f, "unknown error code: {:?}", e),
			Self::IoError(e) => write!(f, "io error: {:?}", e),
		}
	}
}
impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::KnownError(ffi_err) => write!(f, "{}", ffi_err),
			Self::UnknownError(e) => write!(f, "unknown error code: {:?}", e),
			Self::IoError(e) => write!(f, "io error: {}", e),
		}
	}
}
impl error::Error for Error {
	fn source(&self) -> Option<&(dyn error::Error + 'static)> {
		match self {
			Self::KnownError(ffi_err) => Some(ffi_err),
			Self::UnknownError(_) => None,
			Self::IoError(e) => Some(e),
		}
	}
}

impl ffi::DNSServiceError {
	pub fn description(&self) -> &str {
		use ffi::DNSServiceError::*;
		match *self {
			Unknown => "unknown error",
			NoSuchName => "no such name",
			NoMemory => "out of memory",
			BadParam => "bad parameter",
			BadReference => "bad reference",
			BadState => "bad state",
			BadFlags => "bad flags",
			Unsupported => "not supported",
			NotInitialized => "not initialized",
			NoCache => "no cache",
			AlreadyRegistered => "already registered",
			NameConflict => "name conflict",
			Invalid => "invalid",
			Incompatible => "client library incompatible with daemon",
			BadInterfaceIndex => "bad interface index",
			Refused => "refused",
			NoSuchRecord => "no such record",
			NoAuth => "no auth",
			NoSuchKey => "no such key",
			NoValue => "no value",
			BufferTooSmall => "buffer too small",
		}
	}
}

impl fmt::Display for ffi::DNSServiceError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		write!(f, "{}", self.description())
	}
}
impl error::Error for ffi::DNSServiceError {
	fn description(&self) -> &str {
		self.description()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	#[allow(deprecated)]
	fn test_ffi_err_description() {
		// make sure Error::description still works, although we now provide a
		// (non-trait) description method
		assert_eq!(
			error::Error::description(&ffi::DNSServiceError::NoAuth),
			"no auth"
		);
	}
}
