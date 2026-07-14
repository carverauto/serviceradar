//! Common handling for types backed by byte slices with enforcement of a
//! library-level length limitation i.e. `Length::max()`.

use crate::{DecodeValue, DerOrd, EncodeValue, Error, Header, Length, Reader, Result, Writer};
use core::cmp::Ordering;

/// Byte slice newtype which respects the `Length::MAX` limit.
#[derive(Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
#[repr(transparent)]
pub(crate) struct BytesRef([u8]);

impl BytesRef {
    /// Constant value representing an empty byte slice.
    pub const EMPTY: &'static Self = Self::new_unchecked(&[]);

    /// Create a new [`BytesRef`], ensuring that the provided `slice` value
    /// is shorter than `Length::MAX`.
    pub const fn new(slice: &[u8]) -> Result<&Self> {
        match Length::new_usize(slice.len()) {
            Ok(_) => Ok(Self::new_unchecked(slice)),
            Err(err) => Err(err),
        }
    }

    /// Perform a raw conversion of a byte slice to `Self` without first performing a length check.
    pub(crate) const fn new_unchecked(slice: &[u8]) -> &Self {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `[u8]`
        #[allow(unsafe_code)]
        unsafe {
            &*(slice as *const [u8] as *const Self)
        }
    }

    /// Get a pointer to this [`BytesRef`].
    pub(crate) const fn as_ptr(&self) -> *const BytesRef {
        self as *const BytesRef
    }

    /// Borrow the inner byte slice
    pub const fn as_slice(&self) -> &[u8] {
        &self.0
    }

    /// Get the [`Length`] of this [`BytesRef`].
    pub fn len(&self) -> Length {
        debug_assert!(u32::try_from(self.0.len()).is_ok());

        #[allow(clippy::cast_possible_truncation)] // checked by constructors
        Length::new(self.0.len() as u32)
    }

    /// Is this [`BytesRef`] empty?
    pub const fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Get a prefix of a [`crate::bytes_ref::BytesRef`] of the given length.
    pub fn prefix(&self, length: Length) -> Result<&Self> {
        let inner = self
            .as_slice()
            .get(..usize::try_from(length)?)
            .ok_or_else(|| Error::incomplete(self.len()))?;

        Ok(Self::new_unchecked(inner))
    }
}

impl AsRef<[u8]> for BytesRef {
    fn as_ref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl<'a> DecodeValue<'a> for &'a BytesRef {
    type Error = Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
        BytesRef::new(reader.read_slice(header.length())?)
    }
}

impl EncodeValue for BytesRef {
    fn value_len(&self) -> Result<Length> {
        Ok(self.len())
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
        writer.write(self.as_ref())
    }
}

impl DerOrd for BytesRef {
    fn der_cmp(&self, other: &Self) -> Result<Ordering> {
        Ok(self.as_slice().cmp(other.as_slice()))
    }
}

impl<'a> TryFrom<&'a [u8]> for &'a BytesRef {
    type Error = Error;

    fn try_from(slice: &'a [u8]) -> Result<Self> {
        BytesRef::new(slice)
    }
}

/// Implemented by hand because the derive would create invalid values.
/// Makes sure the length and the inner.len matches.
#[cfg(feature = "arbitrary")]
impl<'a> arbitrary::Arbitrary<'a> for &'a BytesRef {
    fn arbitrary(u: &mut arbitrary::Unstructured<'a>) -> arbitrary::Result<Self> {
        let length: Length = u.arbitrary()?;
        Ok(BytesRef::new_unchecked(
            u.bytes(u32::from(length) as usize)?,
        ))
    }

    fn size_hint(depth: usize) -> (usize, Option<usize>) {
        arbitrary::size_hint::and(Length::size_hint(depth), (0, None))
    }
}

#[cfg(feature = "alloc")]
pub(crate) mod allocating {
    use super::BytesRef;
    #[cfg(feature = "ber")]
    use crate::{ErrorKind, length::indefinite::read_constructed_vec};

    use crate::{
        DecodeValue, DerOrd, EncodeValue, Error, Header, Length, Reader, Result, Tag, Writer,
    };

    use alloc::{borrow::ToOwned, boxed::Box, vec::Vec};
    use core::{borrow::Borrow, cmp::Ordering, ops::Deref};

    /// Byte slice newtype which respects the `Length::max()` limit.
    #[derive(Clone, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
    pub(crate) struct BytesOwned {
        /// Precomputed `Length` (avoids possible panicking conversions)
        length: Length,

        /// Inner value
        inner: Box<[u8]>,
    }

    impl BytesOwned {
        /// Create a new [`BytesOwned`], ensuring that the provided `slice` value
        /// is shorter than `Length::max()`.
        pub fn new(data: impl Into<Box<[u8]>>) -> Result<Self> {
            let inner: Box<[u8]> = data.into();

            Ok(Self {
                length: Length::try_from(inner.len())?,
                inner,
            })
        }
        /// Decodes [`BytesOwned`] as DER, or from parts, when using a BER reader.
        pub fn decode_value_parts<'a, R: Reader<'a>>(
            reader: &mut R,
            header: Header,
            inner_tag: Tag,
        ) -> Result<Self> {
            #[cfg(feature = "ber")]
            if header.is_constructed() {
                if header.length().is_indefinite() && reader.encoding_rules().is_ber() {
                    // Reassemble indefinite length string types
                    return Self::new(read_constructed_vec(reader, header.length(), inner_tag)?);
                } else {
                    // NOTE:
                    // constructed strings with definite length unsupported
                    // See discussion
                    //   - https://github.com/RustCrypto/formats/issues/779#issuecomment-3049869721
                    //
                    // NOTE: this repositions the error to be at the end of the header
                    // rather than at the beginning of the value
                    return Err(Error::new(
                        ErrorKind::Noncanonical { tag: header.tag() },
                        reader.position().saturating_sub(Length::ONE),
                    ));
                }
            }

            #[cfg(not(feature = "ber"))]
            let _ = inner_tag;

            Self::decode_value(reader, header)
        }
    }

    impl AsRef<[u8]> for BytesOwned {
        fn as_ref(&self) -> &[u8] {
            &self.inner
        }
    }

    impl AsRef<BytesRef> for BytesOwned {
        fn as_ref(&self) -> &BytesRef {
            BytesRef::new_unchecked(&self.inner)
        }
    }

    impl Borrow<[u8]> for BytesOwned {
        fn borrow(&self) -> &[u8] {
            &self.inner
        }
    }

    impl Borrow<BytesRef> for BytesOwned {
        fn borrow(&self) -> &BytesRef {
            BytesRef::new_unchecked(&self.inner)
        }
    }

    impl Deref for BytesOwned {
        type Target = BytesRef;

        fn deref(&self) -> &BytesRef {
            self.borrow()
        }
    }

    impl<'a> DecodeValue<'a> for BytesOwned {
        type Error = Error;

        fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
            reader.read_vec(header.length()).and_then(Self::new)
        }
    }

    impl EncodeValue for BytesOwned {
        fn value_len(&self) -> Result<Length> {
            Ok(self.length)
        }

        fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
            writer.write(self.as_ref())
        }
    }

    impl Default for BytesOwned {
        fn default() -> Self {
            Self {
                length: Length::ZERO,
                inner: Box::new([]),
            }
        }
    }

    impl DerOrd for BytesOwned {
        fn der_cmp(&self, other: &Self) -> Result<Ordering> {
            Ok(self.as_slice().cmp(other.as_slice()))
        }
    }

    impl From<BytesOwned> for Box<[u8]> {
        fn from(bytes: BytesOwned) -> Box<[u8]> {
            bytes.inner
        }
    }

    impl From<&BytesRef> for BytesOwned {
        fn from(bytes: &BytesRef) -> BytesOwned {
            BytesOwned {
                length: bytes.len(),
                inner: bytes.as_slice().into(),
            }
        }
    }

    impl TryFrom<&[u8]> for BytesOwned {
        type Error = Error;

        fn try_from(bytes: &[u8]) -> Result<Self> {
            Self::new(bytes)
        }
    }

    impl TryFrom<Box<[u8]>> for BytesOwned {
        type Error = Error;

        fn try_from(bytes: Box<[u8]>) -> Result<Self> {
            Self::new(bytes)
        }
    }

    impl TryFrom<Vec<u8>> for BytesOwned {
        type Error = Error;

        fn try_from(bytes: Vec<u8>) -> Result<Self> {
            Self::new(bytes)
        }
    }

    impl ToOwned for BytesRef {
        type Owned = BytesOwned;

        fn to_owned(&self) -> BytesOwned {
            BytesOwned {
                inner: self.as_slice().into(),
                length: self.len(),
            }
        }
    }

    // Implement by hand because the derive would create invalid values.
    // Make sure the length and the inner.len matches.
    #[cfg(feature = "arbitrary")]
    impl<'a> arbitrary::Arbitrary<'a> for BytesOwned {
        fn arbitrary(u: &mut arbitrary::Unstructured<'a>) -> arbitrary::Result<Self> {
            let length = u.arbitrary()?;
            Ok(Self {
                length,
                inner: Box::from(u.bytes(u32::from(length) as usize)?),
            })
        }

        fn size_hint(depth: usize) -> (usize, Option<usize>) {
            arbitrary::size_hint::and(Length::size_hint(depth), (0, None))
        }
    }
}
