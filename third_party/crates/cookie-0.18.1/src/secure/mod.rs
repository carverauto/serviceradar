extern crate rand;

mod base64 {
    use base64::{DecodeError, Engine, prelude::BASE64_STANDARD};

    /// Encode `input` as the standard base64 with padding.
    pub(crate) fn encode<T: AsRef<[u8]>>(input: T) -> String {
        BASE64_STANDARD.encode(input)
    }

    /// Decode `input` as the standard base64 with padding.
    pub(crate) fn decode<T: AsRef<[u8]>>(input: T) -> Result<Vec<u8>, DecodeError> {
        BASE64_STANDARD.decode(input)
    }
}

#[macro_use]
mod macros;
mod key;

pub use self::key::*;

#[cfg(feature = "private")] mod private;
#[cfg(feature = "private")] pub use self::private::*;

#[cfg(feature = "signed")] mod signed;
#[cfg(feature = "signed")] pub use self::signed::*;
