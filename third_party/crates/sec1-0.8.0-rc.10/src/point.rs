//! Support for the SEC1 `Elliptic-Curve-Point-to-Octet-String` and
//! `Octet-String-to-Elliptic-Curve-Point` encoding algorithms.
//!
//! Described in [SEC1: Elliptic Curve Cryptography] (Version 2.0) section 2.3.3 (p.10).
//!
//! [SEC1: Elliptic Curve Cryptography]: https://www.secg.org/sec1-v2.pdf

use crate::{Error, Result};
use base16ct::HexDisplay;
use core::{
    cmp::Ordering,
    fmt::{self, Debug},
    hash::{Hash, Hasher},
    ops::{Add, Sub},
    str,
};
use hybrid_array::{Array, ArraySize, typenum::U1};

#[cfg(feature = "alloc")]
use alloc::boxed::Box;

#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Serialize, de, ser};

#[cfg(feature = "subtle")]
use subtle::{Choice, ConditionallySelectable};

#[cfg(feature = "zeroize")]
use zeroize::Zeroize;

/// Trait for supported modulus sizes which precomputes the typenums for various point encodings so
/// they don't need to be included as bounds.
// TODO(tarcieri): replace this all with const generic expressions.
pub trait ModulusSize:
    'static + ArraySize + Copy + Debug + Add<U1, Output = Self::CompressedPointSize>
{
    /// Size of a compressed point for the given elliptic curve when encoded using the SEC1
    /// `Elliptic-Curve-Point-to-Octet-String` algorithm (including leading `0x02` or `0x03`
    /// tag byte).
    type CompressedPointSize: 'static
        + ArraySize
        + Copy
        + Debug
        + Add<Self, Output = Self::UncompressedPointSize>;

    /// Size of an uncompressed point for the given elliptic curve when encoded using the SEC1
    /// `Elliptic-Curve-Point-to-Octet-String` algorithm (including leading `0x04` tag byte).
    type UncompressedPointSize: 'static + ArraySize + Copy + Debug;

    /// Size of an untagged point for given elliptic curve, i.e. size of two serialized base field
    /// elements when concatenated.
    type UntaggedPointSize: 'static + ArraySize + Copy + Debug + Sub<Self, Output = Self>;
}

impl<T> ModulusSize for T
where
    T: 'static + ArraySize + Copy + Debug,
    T: Add<U1, Output: 'static + ArraySize + Copy + Debug>,
    T: Add<T, Output: 'static + ArraySize + Copy + Debug + Sub<T, Output = T>>,
    <T as Add<U1>>::Output: Add<T, Output: 'static + ArraySize + Copy + Debug>,
{
    type CompressedPointSize = <T as Add<U1>>::Output;
    type UncompressedPointSize = <Self::CompressedPointSize as Add<T>>::Output;
    type UntaggedPointSize = <T as Add<T>>::Output;
}

/// SEC1 encoded curve point.
///
/// This type is an enum over the compressed and uncompressed encodings,
/// useful for cases where either encoding can be supported, or conversions
/// between the two forms.
#[derive(Clone, Default)]
pub struct EncodedPoint<Size>
where
    Size: ModulusSize,
{
    bytes: Array<u8, Size::UncompressedPointSize>,
}

#[allow(clippy::len_without_is_empty)]
impl<Size> EncodedPoint<Size>
where
    Size: ModulusSize,
{
    /// Decode elliptic curve point (compressed or uncompressed) from the
    /// `Elliptic-Curve-Point-to-Octet-String` encoding described in
    /// SEC 1: Elliptic Curve Cryptography (Version 2.0) section
    /// 2.3.3 (page 10).
    ///
    /// <http://www.secg.org/sec1-v2.pdf>
    pub fn from_bytes(input: impl AsRef<[u8]>) -> Result<Self> {
        let input = input.as_ref();

        // Validate tag
        let tag = input
            .first()
            .cloned()
            .ok_or(Error::PointEncoding)
            .and_then(Tag::from_u8)?;

        // Validate length
        let expected_len = tag.message_len(Size::to_usize());

        if input.len() != expected_len {
            return Err(Error::PointEncoding);
        }

        let mut bytes = Array::default();
        bytes[..expected_len].copy_from_slice(input);
        Ok(Self { bytes })
    }

    /// Decode elliptic curve point from raw uncompressed coordinates, i.e.
    /// encoded as the concatenated `x || y` coordinates with no leading SEC1
    /// tag byte (which would otherwise be `0x04` for an uncompressed point).
    pub fn from_untagged_bytes(bytes: &Array<u8, Size::UntaggedPointSize>) -> Self {
        let (x, y) = bytes.split_ref();
        Self::from_affine_coordinates(x, y, false)
    }

    /// Encode an elliptic curve point from big endian serialized coordinates
    /// (with optional point compression)
    pub fn from_affine_coordinates(
        x: &Array<u8, Size>,
        y: &Array<u8, Size>,
        compress: bool,
    ) -> Self {
        let tag = if compress {
            Tag::compress_y(y.as_slice())
        } else {
            Tag::Uncompressed
        };

        let mut bytes = Array::default();
        bytes[0] = tag.into();
        bytes[1..(Size::to_usize() + 1)].copy_from_slice(x);

        if !compress {
            bytes[(Size::to_usize() + 1)..].copy_from_slice(y);
        }

        Self { bytes }
    }

    /// Return [`EncodedPoint`] representing the additive identity
    /// (a.k.a. point at infinity)
    pub fn identity() -> Self {
        Self::default()
    }

    /// Get the length of the encoded point in bytes
    pub fn len(&self) -> usize {
        self.tag().message_len(Size::to_usize())
    }

    /// Get byte slice containing the serialized [`EncodedPoint`].
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.len()]
    }

    /// Get boxed byte slice containing the serialized [`EncodedPoint`]
    #[cfg(feature = "alloc")]
    pub fn to_bytes(&self) -> Box<[u8]> {
        self.as_bytes().to_vec().into_boxed_slice()
    }

    /// Is this [`EncodedPoint`] compact?
    pub fn is_compact(&self) -> bool {
        self.tag().is_compact()
    }

    /// Is this [`EncodedPoint`] compressed?
    pub fn is_compressed(&self) -> bool {
        self.tag().is_compressed()
    }

    /// Is this [`EncodedPoint`] the additive identity? (a.k.a. point at infinity)
    pub fn is_identity(&self) -> bool {
        self.tag().is_identity()
    }

    /// Compress this [`EncodedPoint`], returning a new [`EncodedPoint`].
    pub fn compress(&self) -> Self {
        match self.coordinates() {
            Coordinates::Compressed { .. }
            | Coordinates::Compact { .. }
            | Coordinates::Identity => self.clone(),
            Coordinates::Uncompressed { x, y } => Self::from_affine_coordinates(x, y, true),
        }
    }

    /// Get the SEC1 tag for this [`EncodedPoint`]
    pub fn tag(&self) -> Tag {
        // Tag is ensured valid by the constructor
        Tag::from_u8(self.bytes[0]).expect("invalid tag")
    }

    /// Get the [`Coordinates`] for this [`EncodedPoint`].
    #[inline]
    pub fn coordinates(&self) -> Coordinates<'_, Size> {
        if self.is_identity() {
            return Coordinates::Identity;
        }

        let (x_bytes, y_bytes) = self.bytes[1..].split_at(Size::to_usize());
        let x = x_bytes.try_into().expect("size invariants were violated");

        if self.is_compressed() {
            Coordinates::Compressed {
                x,
                y_is_odd: self.tag() as u8 & 1 == 1,
            }
        } else if self.is_compact() {
            Coordinates::Compact { x }
        } else {
            Coordinates::Uncompressed {
                x,
                y: y_bytes.try_into().expect("size invariants were violated"),
            }
        }
    }

    /// Get the x-coordinate for this [`EncodedPoint`].
    ///
    /// Returns `None` if this point is the identity point.
    pub fn x(&self) -> Option<&Array<u8, Size>> {
        match self.coordinates() {
            Coordinates::Identity => None,
            Coordinates::Compressed { x, .. } => Some(x),
            Coordinates::Uncompressed { x, .. } => Some(x),
            Coordinates::Compact { x } => Some(x),
        }
    }

    /// Get the y-coordinate for this [`EncodedPoint`].
    ///
    /// Returns `None` if this point is compressed or the identity point.
    pub fn y(&self) -> Option<&Array<u8, Size>> {
        match self.coordinates() {
            Coordinates::Compressed { .. } | Coordinates::Identity => None,
            Coordinates::Uncompressed { y, .. } => Some(y),
            Coordinates::Compact { .. } => None,
        }
    }
}

impl<Size> AsRef<[u8]> for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    #[inline]
    fn as_ref(&self) -> &[u8] {
        self.as_bytes()
    }
}

#[cfg(feature = "subtle")]
impl<Size> ConditionallySelectable for EncodedPoint<Size>
where
    Size: ModulusSize,
    <Size::UncompressedPointSize as ArraySize>::ArrayType<u8>: Copy,
{
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        let mut bytes = Array::default();

        for (i, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::conditional_select(&a.bytes[i], &b.bytes[i], choice);
        }

        Self { bytes }
    }
}

impl<Size> Copy for EncodedPoint<Size>
where
    Size: ModulusSize,
    <Size::UncompressedPointSize as ArraySize>::ArrayType<u8>: Copy,
{
}

impl<Size> Debug for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "EncodedPoint({:?})", self.coordinates())
    }
}

impl<Size: ModulusSize> Eq for EncodedPoint<Size> {}

impl<Size> PartialEq for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn eq(&self, other: &Self) -> bool {
        self.as_bytes() == other.as_bytes()
    }
}

impl<Size> Hash for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.as_bytes().hash(state)
    }
}

impl<Size: ModulusSize> PartialOrd for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<Size: ModulusSize> Ord for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn cmp(&self, other: &Self) -> Ordering {
        self.as_bytes().cmp(other.as_bytes())
    }
}

impl<Size: ModulusSize> TryFrom<&[u8]> for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    type Error = Error;

    fn try_from(bytes: &[u8]) -> Result<Self> {
        Self::from_bytes(bytes)
    }
}

#[cfg(feature = "zeroize")]
impl<Size> Zeroize for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn zeroize(&mut self) {
        self.bytes.zeroize();
        *self = Self::identity();
    }
}

impl<Size> fmt::Display for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:X}")
    }
}

impl<Size> fmt::LowerHex for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:x}", HexDisplay(self.as_bytes()))
    }
}

impl<Size> fmt::UpperHex for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:X}", HexDisplay(self.as_bytes()))
    }
}

/// Decode a SEC1-encoded point from hexadecimal.
///
/// Upper and lower case hexadecimal are both accepted, however mixed case is
/// rejected.
impl<Size> str::FromStr for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    type Err = Error;

    fn from_str(hex: &str) -> Result<Self> {
        let mut buf = Array::<u8, Size::UncompressedPointSize>::default();
        base16ct::mixed::decode(hex, &mut buf)
            .map_err(|_| Error::PointEncoding)
            .and_then(Self::from_bytes)
    }
}

#[cfg(feature = "serde")]
impl<Size> Serialize for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn serialize<S>(&self, serializer: S) -> core::result::Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        serdect::slice::serialize_hex_upper_or_bin(&self.as_bytes(), serializer)
    }
}

#[cfg(feature = "serde")]
impl<'de, Size> Deserialize<'de> for EncodedPoint<Size>
where
    Size: ModulusSize,
{
    fn deserialize<D>(deserializer: D) -> core::result::Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        let bytes = serdect::slice::deserialize_hex_or_bin_vec(deserializer)?;
        Self::from_bytes(bytes).map_err(de::Error::custom)
    }
}

/// Enum representing the coordinates of either compressed or uncompressed
/// SEC1-encoded elliptic curve points.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum Coordinates<'a, Size: ModulusSize> {
    /// Identity point (a.k.a. point at infinity)
    Identity,

    /// Compact curve point
    Compact {
        /// x-coordinate
        x: &'a Array<u8, Size>,
    },

    /// Compressed curve point
    Compressed {
        /// x-coordinate
        x: &'a Array<u8, Size>,

        /// Is the y-coordinate odd?
        y_is_odd: bool,
    },

    /// Uncompressed curve point
    Uncompressed {
        /// x-coordinate
        x: &'a Array<u8, Size>,

        /// y-coordinate
        y: &'a Array<u8, Size>,
    },
}

impl<Size: ModulusSize> Coordinates<'_, Size> {
    /// Get the tag octet needed to encode this set of [`Coordinates`]
    pub fn tag(&self) -> Tag {
        match self {
            Coordinates::Compact { .. } => Tag::Compact,
            Coordinates::Compressed { y_is_odd, .. } => {
                if *y_is_odd {
                    Tag::CompressedOddY
                } else {
                    Tag::CompressedEvenY
                }
            }
            Coordinates::Identity => Tag::Identity,
            Coordinates::Uncompressed { .. } => Tag::Uncompressed,
        }
    }
}

/// Tag byte used by the `Elliptic-Curve-Point-to-Octet-String` encoding.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Tag {
    /// Identity point (`0x00`)
    Identity = 0,

    /// Compressed point with even y-coordinate (`0x02`)
    CompressedEvenY = 2,

    /// Compressed point with odd y-coordinate (`0x03`)
    CompressedOddY = 3,

    /// Uncompressed point (`0x04`)
    Uncompressed = 4,

    /// Compact point (`0x05`)
    Compact = 5,
}

impl Tag {
    /// Parse a tag value from a byte
    pub fn from_u8(byte: u8) -> Result<Self> {
        match byte {
            0 => Ok(Tag::Identity),
            2 => Ok(Tag::CompressedEvenY),
            3 => Ok(Tag::CompressedOddY),
            4 => Ok(Tag::Uncompressed),
            5 => Ok(Tag::Compact),
            _ => Err(Error::PointEncoding),
        }
    }

    /// Is this point compact?
    pub fn is_compact(self) -> bool {
        matches!(self, Tag::Compact)
    }

    /// Is this point compressed?
    pub fn is_compressed(self) -> bool {
        matches!(self, Tag::CompressedEvenY | Tag::CompressedOddY)
    }

    /// Is this point the identity point?
    pub fn is_identity(self) -> bool {
        self == Tag::Identity
    }

    /// Compute the expected total message length for a message prefixed
    /// with this tag (including the tag byte), given the field element size
    /// (in bytes) for a particular elliptic curve.
    pub fn message_len(self, field_element_size: usize) -> usize {
        1 + match self {
            Tag::Identity => 0,
            Tag::CompressedEvenY | Tag::CompressedOddY => field_element_size,
            Tag::Uncompressed => field_element_size * 2,
            Tag::Compact => field_element_size,
        }
    }

    /// Compress the given y-coordinate, returning a `Tag::Compressed*` value
    fn compress_y(y: &[u8]) -> Self {
        // Is the y-coordinate odd in the SEC1 sense: `self mod 2 == 1`?
        if y.as_ref().last().expect("empty y-coordinate") & 1 == 1 {
            Tag::CompressedOddY
        } else {
            Tag::CompressedEvenY
        }
    }
}

impl TryFrom<u8> for Tag {
    type Error = Error;

    fn try_from(byte: u8) -> Result<Self> {
        Self::from_u8(byte)
    }
}

impl From<Tag> for u8 {
    fn from(tag: Tag) -> u8 {
        tag as u8
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::{Coordinates, Tag};
    use core::str::FromStr;
    use hex_literal::hex;
    use hybrid_array::typenum::U32;

    #[cfg(feature = "alloc")]
    use alloc::string::ToString;

    #[cfg(feature = "subtle")]
    use subtle::ConditionallySelectable;

    type EncodedPoint = super::EncodedPoint<U32>;

    /// Identity point
    const IDENTITY_BYTES: [u8; 1] = [0];

    /// Example uncompressed point
    const UNCOMPRESSED_BYTES: [u8; 65] = hex!(
        "0411111111111111111111111111111111111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222"
    );

    /// Example compressed point: `UNCOMPRESSED_BYTES` after point compression
    const COMPRESSED_BYTES: [u8; 33] =
        hex!("021111111111111111111111111111111111111111111111111111111111111111");

    #[test]
    fn decode_compressed_point() {
        // Even y-coordinate
        let compressed_even_y_bytes =
            hex!("020100000000000000000000000000000000000000000000000000000000000000");

        let compressed_even_y = EncodedPoint::from_bytes(&compressed_even_y_bytes[..]).unwrap();

        assert!(compressed_even_y.is_compressed());
        assert_eq!(compressed_even_y.tag(), Tag::CompressedEvenY);
        assert_eq!(compressed_even_y.len(), 33);
        assert_eq!(compressed_even_y.as_bytes(), &compressed_even_y_bytes[..]);

        assert_eq!(
            compressed_even_y.coordinates(),
            Coordinates::Compressed {
                x: &hex!("0100000000000000000000000000000000000000000000000000000000000000").into(),
                y_is_odd: false
            }
        );

        assert_eq!(
            compressed_even_y.x().unwrap(),
            &hex!("0100000000000000000000000000000000000000000000000000000000000000")
        );
        assert_eq!(compressed_even_y.y(), None);

        // Odd y-coordinate
        let compressed_odd_y_bytes =
            hex!("030200000000000000000000000000000000000000000000000000000000000000");

        let compressed_odd_y = EncodedPoint::from_bytes(&compressed_odd_y_bytes[..]).unwrap();

        assert!(compressed_odd_y.is_compressed());
        assert_eq!(compressed_odd_y.tag(), Tag::CompressedOddY);
        assert_eq!(compressed_odd_y.len(), 33);
        assert_eq!(compressed_odd_y.as_bytes(), &compressed_odd_y_bytes[..]);

        assert_eq!(
            compressed_odd_y.coordinates(),
            Coordinates::Compressed {
                x: &hex!("0200000000000000000000000000000000000000000000000000000000000000").into(),
                y_is_odd: true
            }
        );

        assert_eq!(
            compressed_odd_y.x().unwrap(),
            &hex!("0200000000000000000000000000000000000000000000000000000000000000")
        );
        assert_eq!(compressed_odd_y.y(), None);
    }

    #[test]
    fn decode_uncompressed_point() {
        let uncompressed_point = EncodedPoint::from_bytes(&UNCOMPRESSED_BYTES[..]).unwrap();

        assert!(!uncompressed_point.is_compressed());
        assert_eq!(uncompressed_point.tag(), Tag::Uncompressed);
        assert_eq!(uncompressed_point.len(), 65);
        assert_eq!(uncompressed_point.as_bytes(), &UNCOMPRESSED_BYTES[..]);

        assert_eq!(
            uncompressed_point.coordinates(),
            Coordinates::Uncompressed {
                x: &hex!("1111111111111111111111111111111111111111111111111111111111111111").into(),
                y: &hex!("2222222222222222222222222222222222222222222222222222222222222222").into()
            }
        );

        assert_eq!(
            uncompressed_point.x().unwrap(),
            &hex!("1111111111111111111111111111111111111111111111111111111111111111")
        );
        assert_eq!(
            uncompressed_point.y().unwrap(),
            &hex!("2222222222222222222222222222222222222222222222222222222222222222")
        );
    }

    #[test]
    fn decode_identity() {
        let identity_point = EncodedPoint::from_bytes(&IDENTITY_BYTES[..]).unwrap();
        assert!(identity_point.is_identity());
        assert_eq!(identity_point.tag(), Tag::Identity);
        assert_eq!(identity_point.len(), 1);
        assert_eq!(identity_point.as_bytes(), &IDENTITY_BYTES[..]);
        assert_eq!(identity_point.coordinates(), Coordinates::Identity);
        assert_eq!(identity_point.x(), None);
        assert_eq!(identity_point.y(), None);
    }

    #[test]
    fn decode_invalid_tag() {
        let mut compressed_bytes = COMPRESSED_BYTES;
        let mut uncompressed_bytes = UNCOMPRESSED_BYTES;

        for bytes in &mut [&mut compressed_bytes[..], &mut uncompressed_bytes[..]] {
            for tag in 0..=0xFF {
                // valid tags
                if tag == 2 || tag == 3 || tag == 4 || tag == 5 {
                    continue;
                }

                (*bytes)[0] = tag;
                let decode_result = EncodedPoint::from_bytes(&*bytes);
                assert!(decode_result.is_err());
            }
        }
    }

    #[test]
    fn decode_truncated_point() {
        for bytes in &[&COMPRESSED_BYTES[..], &UNCOMPRESSED_BYTES[..]] {
            for len in 0..bytes.len() {
                let decode_result = EncodedPoint::from_bytes(&bytes[..len]);
                assert!(decode_result.is_err());
            }
        }
    }

    #[test]
    fn from_untagged_point() {
        let untagged_bytes = hex!(
            "11111111111111111111111111111111111111111111111111111111111111112222222222222222222222222222222222222222222222222222222222222222"
        );
        let uncompressed_point = EncodedPoint::from_untagged_bytes(&untagged_bytes.into());
        assert_eq!(uncompressed_point.as_bytes(), &UNCOMPRESSED_BYTES[..]);
    }

    #[test]
    fn from_affine_coordinates() {
        let x = hex!("1111111111111111111111111111111111111111111111111111111111111111");
        let y = hex!("2222222222222222222222222222222222222222222222222222222222222222");

        let uncompressed_point = EncodedPoint::from_affine_coordinates(&x.into(), &y.into(), false);
        assert_eq!(uncompressed_point.as_bytes(), &UNCOMPRESSED_BYTES[..]);

        let compressed_point = EncodedPoint::from_affine_coordinates(&x.into(), &y.into(), true);
        assert_eq!(compressed_point.as_bytes(), &COMPRESSED_BYTES[..]);
    }

    #[test]
    fn compress() {
        let uncompressed_point = EncodedPoint::from_bytes(&UNCOMPRESSED_BYTES[..]).unwrap();
        let compressed_point = uncompressed_point.compress();
        assert_eq!(compressed_point.as_bytes(), &COMPRESSED_BYTES[..]);
    }

    #[cfg(feature = "subtle")]
    #[test]
    fn conditional_select() {
        let a = EncodedPoint::from_bytes(&COMPRESSED_BYTES[..]).unwrap();
        let b = EncodedPoint::from_bytes(&UNCOMPRESSED_BYTES[..]).unwrap();

        let a_selected = EncodedPoint::conditional_select(&a, &b, 0.into());
        assert_eq!(a, a_selected);

        let b_selected = EncodedPoint::conditional_select(&a, &b, 1.into());
        assert_eq!(b, b_selected);
    }

    #[test]
    fn identity() {
        let identity_point = EncodedPoint::identity();
        assert_eq!(identity_point.tag(), Tag::Identity);
        assert_eq!(identity_point.len(), 1);
        assert_eq!(identity_point.as_bytes(), &IDENTITY_BYTES[..]);

        // identity is default
        assert_eq!(identity_point, EncodedPoint::default());
    }

    #[test]
    fn decode_hex() {
        let point = EncodedPoint::from_str(
            "021111111111111111111111111111111111111111111111111111111111111111",
        )
        .unwrap();
        assert_eq!(point.as_bytes(), COMPRESSED_BYTES);
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn to_bytes() {
        let uncompressed_point = EncodedPoint::from_bytes(&UNCOMPRESSED_BYTES[..]).unwrap();
        assert_eq!(&*uncompressed_point.to_bytes(), &UNCOMPRESSED_BYTES[..]);
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn to_string() {
        let point = EncodedPoint::from_bytes(&COMPRESSED_BYTES[..]).unwrap();
        assert_eq!(
            point.to_string(),
            "021111111111111111111111111111111111111111111111111111111111111111"
        );
    }
}
