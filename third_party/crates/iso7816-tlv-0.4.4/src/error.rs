use core::fmt;

/// Error definition for TLV data as defined in [ISO7816-4].
#[allow(clippy::module_name_repetitions)]
#[derive(PartialEq, Clone, Debug)]
pub enum TlvError {
  /// Invalid input encountered
  InvalidInput,
  /// Read tag is reserved for future usage
  TagIsRFU,
  /// conversion error
  ParseIntError,
  /// parsing error
  TruncatedInput,
  /// Inconsistant (tag, value) pair
  Inconsistant,
  /// Read invalid length value
  InvalidLength,
}

#[cfg(feature = "std")]
impl std::error::Error for TlvError {
  fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
    match self {
      _ => None,
    }
  }
}

impl fmt::Display for TlvError {
  fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
    let s = match self {
      Self::InvalidInput => "Invalid tag encountered",
      Self::TagIsRFU => "Tag is reserved for future usage",
      Self::ParseIntError => "Error parsing input as int",
      Self::TruncatedInput => "Error input too short",
      Self::Inconsistant => "Inconsistant (tag, value) pair",
      Self::InvalidLength => "Read invalid length value",
    };
    write!(f, "{s}")
  }
}

impl From<core::num::ParseIntError> for TlvError {
  fn from(_: core::num::ParseIntError) -> Self {
    Self::ParseIntError
  }
}

impl From<untrusted::EndOfInput> for TlvError {
  fn from(_: untrusted::EndOfInput) -> Self {
    Self::TruncatedInput
  }
}
