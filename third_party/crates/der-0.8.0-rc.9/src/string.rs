//! Common handling for types backed by `str` slices with enforcement of a
//! library-level length limitation i.e. `Length::max()`.

use crate::{BytesRef, DecodeValue, EncodeValue, Error, Header, Length, Reader, Result, Writer};
use core::str;

/// String slice newtype which respects the [`Length::max`] limit.
#[derive(Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
#[repr(transparent)]
pub struct StringRef(str);

impl StringRef {
    /// Create a new [`StringRef`], ensuring that the byte representation of
    /// the provided `str` value is shorter than `Length::max()`.
    pub const fn new(s: &str) -> Result<&Self> {
        match Length::new_usize(s.len()) {
            Ok(_) => Ok(Self::new_unchecked(s)),
            Err(err) => Err(err),
        }
    }

    /// Perform a raw conversion of a `str` to `Self` without first performing a length check.
    pub(crate) const fn new_unchecked(s: &str) -> &Self {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `str`
        #[allow(unsafe_code)]
        unsafe {
            &*(s as *const str as *const Self)
        }
    }

    /// Parse a [`StringRef`] from UTF-8 encoded bytes.
    pub fn from_bytes(bytes: &[u8]) -> Result<&Self> {
        Self::new(str::from_utf8(bytes)?)
    }

    /// Borrow the inner `str`.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Borrow the inner byte slice.
    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }

    /// Get the [`Length`] of this [`StringRef`].
    pub fn len(&self) -> Length {
        debug_assert!(u32::try_from(self.0.len()).is_ok());

        #[allow(clippy::cast_possible_truncation)] // checked by constructors
        Length::new(self.0.len() as u32)
    }

    /// Is this [`StringRef`] empty?
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl AsRef<str> for StringRef {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

impl AsRef<[u8]> for StringRef {
    fn as_ref(&self) -> &[u8] {
        self.as_bytes()
    }
}

impl AsRef<BytesRef> for StringRef {
    fn as_ref(&self) -> &BytesRef {
        BytesRef::new_unchecked(self.as_bytes())
    }
}

impl<'a> DecodeValue<'a> for &'a StringRef {
    type Error = Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
        StringRef::from_bytes(<&'a BytesRef>::decode_value(reader, header)?.as_slice())
    }
}

impl EncodeValue for StringRef {
    fn value_len(&self) -> Result<Length> {
        Ok(self.len())
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
        writer.write(self.as_ref())
    }
}

#[cfg(feature = "alloc")]
pub(crate) mod allocating {
    use super::StringRef;
    use crate::{
        BytesRef, DecodeValue, EncodeValue, Error, Header, Length, Reader, Result, Writer,
    };
    use alloc::{borrow::ToOwned, string::String};
    use core::{borrow::Borrow, ops::Deref, str};

    /// String newtype which respects the [`Length::max`] limit.
    #[derive(Clone, Debug, Eq, PartialEq, PartialOrd, Ord, Hash)]
    pub struct StringOwned {
        /// Inner value
        pub(crate) inner: String,

        /// Precomputed `Length` (avoids possible panicking conversions)
        pub(crate) length: Length,
    }

    impl StringOwned {
        /// Create a new [`StringOwned`], ensuring that the byte representation of
        /// the provided `str` value is shorter than `Length::max()`.
        pub fn new(s: String) -> Result<Self> {
            let length = Length::try_from(s.len())?;

            Ok(Self { inner: s, length })
        }

        /// Parse a [`String`] from UTF-8 encoded bytes.
        pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
            Ok(Self {
                inner: String::from_utf8(bytes.to_vec())?,
                length: Length::try_from(bytes.len())?,
            })
        }

        /// Borrow the inner `str`
        pub fn as_str(&self) -> &str {
            &self.inner
        }

        /// Borrow the inner byte slice
        pub fn as_bytes(&self) -> &[u8] {
            self.inner.as_bytes()
        }

        /// Get the [`Length`] of this [`StringOwned`]
        pub fn len(&self) -> Length {
            self.length
        }

        /// Is this [`StringOwned`] empty?
        pub fn is_empty(&self) -> bool {
            self.len() == Length::ZERO
        }
    }

    impl AsRef<str> for StringOwned {
        fn as_ref(&self) -> &str {
            self.as_str()
        }
    }

    impl AsRef<[u8]> for StringOwned {
        fn as_ref(&self) -> &[u8] {
            self.as_bytes()
        }
    }

    impl AsRef<BytesRef> for StringOwned {
        fn as_ref(&self) -> &BytesRef {
            BytesRef::new_unchecked(self.as_bytes())
        }
    }

    impl AsRef<StringRef> for StringOwned {
        fn as_ref(&self) -> &StringRef {
            StringRef::new_unchecked(&self.inner)
        }
    }

    impl Borrow<StringRef> for StringOwned {
        fn borrow(&self) -> &StringRef {
            StringRef::new_unchecked(&self.inner)
        }
    }

    impl Deref for StringOwned {
        type Target = StringRef;

        fn deref(&self) -> &StringRef {
            self.borrow()
        }
    }

    impl<'a> DecodeValue<'a> for StringOwned {
        type Error = Error;

        fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
            Self::from_bytes(<&'a BytesRef>::decode_value(reader, header)?.as_slice())
        }
    }

    impl EncodeValue for StringOwned {
        fn value_len(&self) -> Result<Length> {
            Ok(self.length)
        }

        fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
            writer.write(self.as_ref())
        }
    }

    impl ToOwned for StringRef {
        type Owned = StringOwned;

        fn to_owned(&self) -> StringOwned {
            StringOwned {
                inner: self.as_str().into(),
                length: self.len(),
            }
        }
    }
}
