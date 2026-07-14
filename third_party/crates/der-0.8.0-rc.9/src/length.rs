//! Length calculations for encoded ASN.1 DER values

#[cfg(feature = "ber")]
pub(crate) mod indefinite;

/// Octet identifying an indefinite length as described in X.690 Section
/// 8.1.3.6.1:
///
/// > The single octet shall have bit 8 set to one, and bits 7 to
/// > 1 set to zero.
pub(super) const INDEFINITE_LENGTH_OCTET: u8 = 0b10000000; // 0x80

use crate::{Decode, DerOrd, Encode, EncodingRules, Error, ErrorKind, Reader, Result, Tag, Writer};
use core::{
    cmp::Ordering,
    fmt,
    ops::{Add, Sub},
};

/// ASN.1-encoded length.
#[derive(Copy, Clone, Default, Eq, Hash, PartialEq, PartialOrd, Ord)]
pub struct Length {
    /// Inner length as a `u32`. Note that the decoder and encoder also support a maximum length
    /// of 32-bits.
    inner: u32,

    /// Flag bit which specifies whether the length was indeterminate when decoding ASN.1 BER.
    ///
    /// This should always be false when working with DER.
    #[cfg(feature = "ber")]
    indefinite: bool,
}

impl Length {
    /// Length of `0`
    pub const ZERO: Self = Self::new(0);

    /// Length of `1`
    pub const ONE: Self = Self::new(1);

    /// Maximum length (`u32::MAX`).
    pub const MAX: Self = Self::new(u32::MAX);

    /// Length of end-of-content octets (i.e. `00 00`).
    #[cfg(feature = "ber")]
    pub(crate) const EOC_LEN: Self = Self::new(2);

    /// Create a new [`Length`] for any value which fits inside of a [`u16`].
    ///
    /// This function is const-safe and therefore useful for [`Length`] constants.
    pub const fn new(value: u32) -> Self {
        Self {
            inner: value,

            #[cfg(feature = "ber")]
            indefinite: false,
        }
    }

    /// Create a new [`Length`] for any value which fits inside the length type.
    ///
    /// This function is const-safe and therefore useful for [`Length`] constants.
    #[allow(clippy::cast_possible_truncation)]
    pub(crate) const fn new_usize(len: usize) -> Result<Self> {
        if len > (u32::MAX as usize) {
            Err(Error::from_kind(ErrorKind::Overflow))
        } else {
            Ok(Self::new(len as u32))
        }
    }

    /// Is this length equal to zero?
    pub const fn is_zero(self) -> bool {
        self.inner == 0
    }

    /// Was this length decoded from an indefinite length when decoding BER?
    #[cfg(feature = "ber")]
    pub(crate) const fn is_indefinite(self) -> bool {
        self.indefinite
    }

    /// Get the length of DER Tag-Length-Value (TLV) encoded data if `self`
    /// is the length of the inner "value" portion of the message.
    pub fn for_tlv(self, tag: Tag) -> Result<Self> {
        tag.encoded_len()? + self.encoded_len()? + self
    }

    /// Perform saturating addition of two lengths.
    pub fn saturating_add(self, rhs: Self) -> Self {
        Self::new(self.inner.saturating_add(rhs.inner))
    }

    /// Perform saturating subtraction of two lengths.
    pub fn saturating_sub(self, rhs: Self) -> Self {
        Self::new(self.inner.saturating_sub(rhs.inner))
    }

    /// If the length is indefinite, compute a length with the EOC marker removed
    /// (i.e. the final two bytes `00 00`).
    ///
    /// Otherwise (as should always be the case with DER), the length is unchanged.
    ///
    /// This method notably preserves the `indefinite` flag when performing arithmetic.
    #[cfg(feature = "ber")]
    pub(crate) fn sans_eoc(self) -> Self {
        if self.indefinite {
            // We expect EOC to be present when this is called.
            debug_assert!(self >= Self::EOC_LEN);

            Self {
                inner: self.saturating_sub(Self::EOC_LEN).inner,
                indefinite: true,
            }
        } else {
            // Return DER length
            self
        }
    }

    /// Get initial octet of the encoded length (if one is required).
    ///
    /// From X.690 Section 8.1.3.5:
    /// > In the long form, the length octets shall consist of an initial octet
    /// > and one or more subsequent octets. The initial octet shall be encoded
    /// > as follows:
    /// >
    /// > a) bit 8 shall be one;
    /// > b) bits 7 to 1 shall encode the number of subsequent octets in the
    /// >    length octets, as an unsigned binary integer with bit 7 as the
    /// >    most significant bit;
    /// > c) the value 11111111₂ shall not be used.
    fn initial_octet(self) -> Option<u8> {
        match self.inner {
            0x80..=0xFF => Some(0x81),
            0x100..=0xFFFF => Some(0x82),
            0x10000..=0xFFFFFF => Some(0x83),
            0x1000000..=0xFFFFFFFF => Some(0x84),
            _ => None,
        }
    }
}

impl Add for Length {
    type Output = Result<Self>;

    fn add(self, other: Self) -> Result<Self> {
        self.inner
            .checked_add(other.inner)
            .ok_or_else(|| ErrorKind::Overflow.into())
            .map(Self::new)
    }
}

impl Add<u8> for Length {
    type Output = Result<Self>;

    fn add(self, other: u8) -> Result<Self> {
        self + Length::from(other)
    }
}

impl Add<u16> for Length {
    type Output = Result<Self>;

    fn add(self, other: u16) -> Result<Self> {
        self + Length::from(other)
    }
}

impl Add<u32> for Length {
    type Output = Result<Self>;

    fn add(self, other: u32) -> Result<Self> {
        self + Length::from(other)
    }
}

impl Add<usize> for Length {
    type Output = Result<Self>;

    fn add(self, other: usize) -> Result<Self> {
        self + Length::try_from(other)?
    }
}

impl Add<Length> for Result<Length> {
    type Output = Self;

    fn add(self, other: Length) -> Self {
        self? + other
    }
}

impl Sub for Length {
    type Output = Result<Self>;

    fn sub(self, other: Length) -> Result<Self> {
        self.inner
            .checked_sub(other.inner)
            .ok_or_else(|| ErrorKind::Overflow.into())
            .map(Self::new)
    }
}

impl Sub<Length> for Result<Length> {
    type Output = Self;

    fn sub(self, other: Length) -> Self {
        self? - other
    }
}

impl From<u8> for Length {
    fn from(len: u8) -> Length {
        Length::new(len.into())
    }
}

impl From<u16> for Length {
    fn from(len: u16) -> Length {
        Length::new(len.into())
    }
}

impl From<u32> for Length {
    fn from(len: u32) -> Length {
        Length::new(len)
    }
}

impl From<Length> for u32 {
    fn from(length: Length) -> u32 {
        length.inner
    }
}

impl TryFrom<usize> for Length {
    type Error = Error;

    fn try_from(len: usize) -> Result<Length> {
        Length::new_usize(len)
    }
}

impl TryFrom<Length> for usize {
    type Error = Error;

    fn try_from(len: Length) -> Result<usize> {
        len.inner.try_into().map_err(|_| ErrorKind::Overflow.into())
    }
}

impl<'a> Decode<'a> for Length {
    type Error = Error;

    fn decode<R: Reader<'a>>(reader: &mut R) -> Result<Length> {
        match reader.read_byte()? {
            len if len < INDEFINITE_LENGTH_OCTET => Ok(len.into()),
            // Note: per X.690 Section 8.1.3.6.1 the byte 0x80 encodes indefinite lengths
            INDEFINITE_LENGTH_OCTET => match reader.encoding_rules() {
                // Indefinite lengths are allowed when decoding BER
                #[cfg(feature = "ber")]
                EncodingRules::Ber => indefinite::decode_indefinite_length(&mut reader.clone()),
                // Indefinite lengths are disallowed when decoding DER
                EncodingRules::Der => Err(reader.error(ErrorKind::IndefiniteLength)),
            },
            // 1-4 byte variable-sized length prefix
            tag @ 0x81..=0x84 => {
                let nbytes = tag
                    .checked_sub(0x80)
                    .ok_or_else(|| reader.error(ErrorKind::Overlength))?
                    as usize;

                debug_assert!(nbytes <= 4);

                let mut decoded_len = 0u32;
                for _ in 0..nbytes {
                    decoded_len = decoded_len
                        .checked_shl(8)
                        .ok_or_else(|| reader.error(ErrorKind::Overflow))?
                        | u32::from(reader.read_byte()?);
                }

                let length = Length::from(decoded_len);

                // X.690 Section 10.1: DER lengths must be encoded with a minimum
                // number of octets
                if length.initial_octet() == Some(tag) {
                    Ok(length)
                } else {
                    Err(reader.error(ErrorKind::Overlength))
                }
            }
            _ => {
                // We specialize to a maximum 4-byte length (including initial octet)
                Err(reader.error(ErrorKind::Overlength))
            }
        }
    }
}

impl Encode for Length {
    fn encoded_len(&self) -> Result<Length> {
        match self.inner {
            0..=0x7F => Ok(Length::new(1)),
            0x80..=0xFF => Ok(Length::new(2)),
            0x100..=0xFFFF => Ok(Length::new(3)),
            0x10000..=0xFFFFFF => Ok(Length::new(4)),
            0x1000000..=0xFFFFFFFF => Ok(Length::new(5)),
        }
    }

    fn encode(&self, writer: &mut impl Writer) -> Result<()> {
        match self.initial_octet() {
            Some(tag_byte) => {
                writer.write_byte(tag_byte)?;

                // Strip leading zeroes
                match self.inner.to_be_bytes() {
                    [0, 0, 0, byte] => writer.write_byte(byte),
                    [0, 0, bytes @ ..] => writer.write(&bytes),
                    [0, bytes @ ..] => writer.write(&bytes),
                    bytes => writer.write(&bytes),
                }
            }
            #[allow(clippy::cast_possible_truncation)]
            None => writer.write_byte(self.inner as u8),
        }
    }
}

impl DerOrd for Length {
    fn der_cmp(&self, other: &Self) -> Result<Ordering> {
        // The DER encoding has the same ordering as the integer value
        Ok(self.inner.cmp(&other.inner))
    }
}

impl fmt::Debug for Length {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        #[cfg(feature = "ber")]
        if self.indefinite {
            return write!(f, "Length([indefinite])");
        }

        f.debug_tuple("Length").field(&self.inner).finish()
    }
}

impl fmt::Display for Length {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.inner.fmt(f)
    }
}

// Implement by hand because the derive would create invalid values.
// Generate a u32 with a valid range.
#[cfg(feature = "arbitrary")]
impl<'a> arbitrary::Arbitrary<'a> for Length {
    fn arbitrary(u: &mut arbitrary::Unstructured<'a>) -> arbitrary::Result<Self> {
        Ok(Self::new(u.arbitrary()?))
    }

    fn size_hint(depth: usize) -> (usize, Option<usize>) {
        u32::size_hint(depth)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::Length;
    use crate::{Decode, DerOrd, Encode, ErrorKind};
    use core::cmp::Ordering;

    #[test]
    fn decode() {
        assert_eq!(Length::ZERO, Length::from_der(&[0x00]).unwrap());

        assert_eq!(Length::from(0x7Fu8), Length::from_der(&[0x7F]).unwrap());

        assert_eq!(
            Length::from(0x80u8),
            Length::from_der(&[0x81, 0x80]).unwrap()
        );

        assert_eq!(
            Length::from(0xFFu8),
            Length::from_der(&[0x81, 0xFF]).unwrap()
        );

        assert_eq!(
            Length::from(0x100u16),
            Length::from_der(&[0x82, 0x01, 0x00]).unwrap()
        );

        assert_eq!(
            Length::from(0x10000u32),
            Length::from_der(&[0x83, 0x01, 0x00, 0x00]).unwrap()
        );
        assert_eq!(
            Length::from(0xFFFFFFFFu32),
            Length::from_der(&[0x84, 0xFF, 0xFF, 0xFF, 0xFF]).unwrap()
        );
    }

    #[test]
    fn encode() {
        let mut buffer = [0u8; 5];

        assert_eq!(&[0x00], Length::ZERO.encode_to_slice(&mut buffer).unwrap());

        assert_eq!(
            &[0x7F],
            Length::from(0x7Fu8).encode_to_slice(&mut buffer).unwrap()
        );

        assert_eq!(
            &[0x81, 0x80],
            Length::from(0x80u8).encode_to_slice(&mut buffer).unwrap()
        );

        assert_eq!(
            &[0x81, 0xFF],
            Length::from(0xFFu8).encode_to_slice(&mut buffer).unwrap()
        );

        assert_eq!(
            &[0x82, 0x01, 0x00],
            Length::from(0x100u16).encode_to_slice(&mut buffer).unwrap()
        );

        assert_eq!(
            &[0x83, 0x01, 0x00, 0x00],
            Length::from(0x10000u32)
                .encode_to_slice(&mut buffer)
                .unwrap()
        );
        assert_eq!(
            &[0x84, 0xFF, 0xFF, 0xFF, 0xFF],
            Length::from(0xFFFFFFFFu32)
                .encode_to_slice(&mut buffer)
                .unwrap()
        );
    }

    #[test]
    fn add_overflows_when_max_length_exceeded() {
        let result = Length::MAX + Length::ONE;
        assert_eq!(
            result.err().map(|err| err.kind()),
            Some(ErrorKind::Overflow)
        );
    }

    #[test]
    fn der_ord() {
        assert_eq!(Length::ONE.der_cmp(&Length::MAX).unwrap(), Ordering::Less);
        assert_eq!(Length::ONE.der_cmp(&Length::ONE).unwrap(), Ordering::Equal);
        assert_eq!(
            Length::ONE.der_cmp(&Length::ZERO).unwrap(),
            Ordering::Greater
        );
    }
}
