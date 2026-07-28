use super::fast_parse::{
    parse_6_bytes, parse_i8, parse_i16_be, parse_i24_be, parse_i32_be, parse_i64_be,
    parse_i128_be, parse_u8, parse_u16_be, parse_u24_be, parse_u32_be, parse_u64_be,
    parse_u128_be,
};
use super::field_types::{
    FirewallEvent, FlowEndReason, ForwardingStatus, FragmentFlags, Ipv4Options,
    Ipv6ExtensionHeaders, IsMulticast, MplsLabelExp, MplsTopLabelType, NatEvent,
    NatOriginatingAddressRealm, TcpControlBits, TcpOptions,
};
use crate::protocol::ProtocolTypes;
use nom::{
    Err as NomErr, IResult,
    bytes::complete::take,
    error::{Error as NomError, ErrorKind},
};
use nom_derive::Parse;
use serde::Serialize;
use serde::ser::Serializer;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

macro_rules! impl_try_from {
    ($($t:ty => $v:ident),*) => {
        $(
            impl TryFrom<&DataNumber> for $t {
                type Error = DataNumberError;

                fn try_from(val: &DataNumber) -> Result<Self, Self::Error> {
                    match val {
                        DataNumber::$v(i) => Ok(*i),
                        _ => Err(DataNumberError::InvalidDataType),
                    }
                }
            }

            impl TryFrom<&FieldValue> for $t {
                type Error = FieldValueError;

                fn try_from(value: &FieldValue) -> Result<Self, Self::Error> {
                    match value {
                        FieldValue::DataNumber(d) => {
                            let d: $t = d.try_into().map_err(|_| FieldValueError::InvalidDataType)?;
                            Ok(d)
                        }
                        _ => Err(FieldValueError::InvalidDataType),
                    }
                }
            }
        )*


    };
}

/// Holds our datatypes and values post parsing
///
/// `PartialEq`/`Eq` use semantic numeric comparison (matching `Ord`),
/// so `U8(255) == U16(255)` is true.
#[derive(Debug, Clone, Serialize)]
pub enum DataNumber {
    U8(u8),
    I8(i8),
    U16(u16),
    I16(i16),
    U24(u32),
    I24(i32),
    U32(u32),
    U64(u64),
    I64(i64),
    U128(u128),
    I128(i128),
    I32(i32),
    Vec(Vec<u8>),
}

impl DataNumber {
    /// Try to extract a `u8` from any numeric variant, narrowing if the value fits.
    pub fn as_u8(&self) -> Option<u8> {
        match self {
            DataNumber::U8(n) => Some(*n),
            DataNumber::I8(n) => u8::try_from(*n).ok(),
            DataNumber::U16(n) => u8::try_from(*n).ok(),
            DataNumber::I16(n) => u8::try_from(*n).ok(),
            DataNumber::U24(n) => u8::try_from(*n).ok(),
            DataNumber::I24(n) => u8::try_from(*n).ok(),
            DataNumber::U32(n) => u8::try_from(*n).ok(),
            DataNumber::I32(n) => u8::try_from(*n).ok(),
            DataNumber::U64(n) => u8::try_from(*n).ok(),
            DataNumber::I64(n) => u8::try_from(*n).ok(),
            DataNumber::U128(n) => u8::try_from(*n).ok(),
            DataNumber::I128(n) => u8::try_from(*n).ok(),
            DataNumber::Vec(_) => None,
        }
    }

    /// Try to extract a `u16` from any numeric variant, narrowing if the value fits.
    pub fn as_u16(&self) -> Option<u16> {
        match self {
            DataNumber::U8(n) => Some(u16::from(*n)),
            DataNumber::I8(n) => u16::try_from(*n).ok(),
            DataNumber::U16(n) => Some(*n),
            DataNumber::I16(n) => u16::try_from(*n).ok(),
            DataNumber::U24(n) => u16::try_from(*n).ok(),
            DataNumber::I24(n) => u16::try_from(*n).ok(),
            DataNumber::U32(n) => u16::try_from(*n).ok(),
            DataNumber::I32(n) => u16::try_from(*n).ok(),
            DataNumber::U64(n) => u16::try_from(*n).ok(),
            DataNumber::I64(n) => u16::try_from(*n).ok(),
            DataNumber::U128(n) => u16::try_from(*n).ok(),
            DataNumber::I128(n) => u16::try_from(*n).ok(),
            DataNumber::Vec(_) => None,
        }
    }

    /// Try to extract a `u64` from any numeric variant, widening or narrowing as needed.
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            DataNumber::U8(n) => Some(u64::from(*n)),
            DataNumber::I8(n) => u64::try_from(*n).ok(),
            DataNumber::U16(n) => Some(u64::from(*n)),
            DataNumber::I16(n) => u64::try_from(*n).ok(),
            DataNumber::U24(n) => Some(u64::from(*n)),
            DataNumber::I24(n) => u64::try_from(*n).ok(),
            DataNumber::U32(n) => Some(u64::from(*n)),
            DataNumber::I32(n) => u64::try_from(*n).ok(),
            DataNumber::U64(n) => Some(*n),
            DataNumber::I64(n) => u64::try_from(*n).ok(),
            DataNumber::U128(n) => u64::try_from(*n).ok(),
            DataNumber::I128(n) => u64::try_from(*n).ok(),
            DataNumber::Vec(_) => None,
        }
    }

    /// Convert to i128 for numeric comparison across all variants.
    fn to_i128(&self) -> i128 {
        match self {
            DataNumber::U8(n) => i128::from(*n),
            DataNumber::I8(n) => i128::from(*n),
            DataNumber::U16(n) => i128::from(*n),
            DataNumber::I16(n) => i128::from(*n),
            DataNumber::U24(n) => i128::from(*n),
            DataNumber::I24(n) => i128::from(*n),
            DataNumber::U32(n) => i128::from(*n),
            DataNumber::I32(n) => i128::from(*n),
            DataNumber::U64(n) => i128::from(*n),
            DataNumber::I64(n) => i128::from(*n),
            DataNumber::U128(n) => {
                if *n > i128::MAX as u128 {
                    i128::MAX
                } else {
                    *n as i128
                }
            }
            DataNumber::I128(n) => *n,
            DataNumber::Vec(v) => {
                // Only interpret up to 16 bytes (128 bits) to avoid silent overflow
                v.iter()
                    .take(16)
                    .fold(0i128, |acc, &b| (acc << 8) | i128::from(b))
            }
        }
    }
}

impl PartialEq for DataNumber {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == std::cmp::Ordering::Equal
    }
}

impl Eq for DataNumber {}

impl PartialOrd for DataNumber {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for DataNumber {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match (self, other) {
            // Vec variants sort after all numeric variants (lexicographic among themselves)
            (DataNumber::Vec(a), DataNumber::Vec(b)) => a.cmp(b),
            (DataNumber::Vec(_), _) => std::cmp::Ordering::Greater,
            (_, DataNumber::Vec(_)) => std::cmp::Ordering::Less,
            (DataNumber::U128(a), DataNumber::U128(b)) => a.cmp(b),
            // U128 values beyond i128::MAX are greater than any other variant
            (DataNumber::U128(n), _) if *n > i128::MAX as u128 => std::cmp::Ordering::Greater,
            (_, DataNumber::U128(n)) if *n > i128::MAX as u128 => std::cmp::Ordering::Less,
            _ => self.to_i128().cmp(&other.to_i128()),
        }
    }
}

/// Error returned when converting a [`DataNumber`] to a concrete numeric type fails
/// because the variant does not match the requested type.
#[derive(Debug)]
pub enum DataNumberError {
    /// The [`DataNumber`] variant does not match the requested numeric type.
    InvalidDataType,
}

impl std::fmt::Display for DataNumberError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataNumberError::InvalidDataType => {
                write!(f, "DataNumber variant does not match the requested type")
            }
        }
    }
}

impl std::error::Error for DataNumberError {}

impl_try_from!(
    u8 => U8,
    i8 => I8,
    u16 => U16,
    i16 => I16,
    u64 => U64,
    i64 => I64,
    u128 => U128,
    i128 => I128
);

// Manual TryFrom for u32/i32 to also handle U24/I24 variants
impl TryFrom<&DataNumber> for u32 {
    type Error = DataNumberError;

    fn try_from(val: &DataNumber) -> Result<Self, Self::Error> {
        match val {
            DataNumber::U32(i) | DataNumber::U24(i) => Ok(*i),
            _ => Err(DataNumberError::InvalidDataType),
        }
    }
}

impl TryFrom<&FieldValue> for u32 {
    type Error = FieldValueError;

    fn try_from(value: &FieldValue) -> Result<Self, Self::Error> {
        match value {
            FieldValue::DataNumber(d) => {
                let d: u32 = d.try_into().map_err(|_| FieldValueError::InvalidDataType)?;
                Ok(d)
            }
            _ => Err(FieldValueError::InvalidDataType),
        }
    }
}

impl TryFrom<&DataNumber> for i32 {
    type Error = DataNumberError;

    fn try_from(val: &DataNumber) -> Result<Self, Self::Error> {
        match val {
            DataNumber::I32(i) | DataNumber::I24(i) => Ok(*i),
            _ => Err(DataNumberError::InvalidDataType),
        }
    }
}

impl TryFrom<&FieldValue> for i32 {
    type Error = FieldValueError;

    fn try_from(value: &FieldValue) -> Result<Self, Self::Error> {
        match value {
            FieldValue::DataNumber(d) => {
                let d: i32 = d.try_into().map_err(|_| FieldValueError::InvalidDataType)?;
                Ok(d)
            }
            _ => Err(FieldValueError::InvalidDataType),
        }
    }
}

/// Error returned when converting a [`FieldValue`] to a concrete Rust type fails
/// because the variant does not match the requested type.
#[derive(Debug)]
pub enum FieldValueError {
    /// The [`FieldValue`] variant does not match the requested type.
    InvalidDataType,
}

impl std::fmt::Display for FieldValueError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FieldValueError::InvalidDataType => {
                write!(f, "FieldValue variant does not match the requested type")
            }
        }
    }
}

impl std::error::Error for FieldValueError {}

impl TryFrom<&FieldValue> for String {
    type Error = FieldValueError;

    fn try_from(value: &FieldValue) -> Result<Self, Self::Error> {
        match value {
            FieldValue::String(s) => Ok(s.value.clone()),
            FieldValue::MacAddr(bytes) => Ok(format_mac_addr(bytes)),
            _ => Err(FieldValueError::InvalidDataType),
        }
    }
}

/// Format a 6-byte MAC address as "aa:bb:cc:dd:ee:ff" (lowercase hex, colon-separated)
fn format_mac_addr(bytes: &[u8; 6]) -> String {
    format!(
        "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]
    )
}

impl TryFrom<&FieldValue> for IpAddr {
    type Error = FieldValueError;

    fn try_from(value: &FieldValue) -> Result<Self, Self::Error> {
        match value {
            FieldValue::Ip4Addr(ip) => Ok(IpAddr::V4(*ip)),
            FieldValue::Ip6Addr(ip) => Ok(IpAddr::V6(*ip)),
            _ => Err(FieldValueError::InvalidDataType),
        }
    }
}

#[cfg(feature = "parse_unknown_fields")]
fn parse_unknown_fields(remaining: &[u8], field_length: u16) -> IResult<&[u8], FieldValue> {
    let (i, taken) = take(field_length)(remaining)?;
    Ok((i, FieldValue::Vec(taken.to_vec())))
}

#[cfg(not(feature = "parse_unknown_fields"))]
fn parse_unknown_fields(remaining: &[u8], _field_length: u16) -> IResult<&[u8], FieldValue> {
    Err(NomErr::Error(NomError::new(remaining, ErrorKind::Fail)))
}

/// Helper function to parse duration fields that can be either 4 or 8 bytes.
/// Builds a `DurationValue::Seconds` or `DurationValue::Millis` depending on the
/// variant constructor passed via `make_variant`.
fn parse_duration<F>(
    remaining: &[u8],
    field_length: u16,
    make_variant: F,
) -> IResult<&[u8], FieldValue>
where
    F: Fn(u64, u8) -> DurationValue,
{
    match field_length {
        2 => {
            let (i, value) = u16::parse_be(remaining)?;
            Ok((i, FieldValue::Duration(make_variant(value.into(), 2))))
        }
        4 => {
            let (i, value) = u32::parse_be(remaining)?;
            Ok((i, FieldValue::Duration(make_variant(value.into(), 4))))
        }
        8 => {
            let (i, value) = u64::parse_be(remaining)?;
            Ok((i, FieldValue::Duration(make_variant(value, 8))))
        }
        _ => Err(NomErr::Error(NomError::new(remaining, ErrorKind::Fail))),
    }
}

/// Convert into usize, mainly for serialization purposes
impl DataNumber {
    /// Parse bytes into DataNumber Type
    #[inline]
    pub fn parse(i: &[u8], field_length: u16, signed: bool) -> IResult<&[u8], DataNumber> {
        match (field_length, signed) {
            (1, false) => parse_u8(i).map(|(i, j)| (i, Self::U8(j))),
            (1, true) => parse_i8(i).map(|(i, j)| (i, Self::I8(j))),
            (2, false) => parse_u16_be(i).map(|(i, j)| (i, Self::U16(j))),
            (2, true) => parse_i16_be(i).map(|(i, j)| (i, Self::I16(j))),
            (3, false) => parse_u24_be(i).map(|(i, j)| (i, Self::U24(j))),
            (3, true) => parse_i24_be(i).map(|(i, j)| (i, Self::I24(j))),
            (4, true) => parse_i32_be(i).map(|(i, j)| (i, Self::I32(j))),
            (4, false) => parse_u32_be(i).map(|(i, j)| (i, Self::U32(j))),
            (8, false) => parse_u64_be(i).map(|(i, j)| (i, Self::U64(j))),
            (8, true) => parse_i64_be(i).map(|(i, j)| (i, Self::I64(j))),
            (16, false) => parse_u128_be(i).map(|(i, j)| (i, Self::U128(j))),
            (16, true) => parse_i128_be(i).map(|(i, j)| (i, Self::I128(j))),
            _ => {
                let (i, bytes) = take(field_length)(i)?;
                Ok((i, Self::Vec(bytes.to_vec())))
            }
        }
    }

    /// Returns the number of bytes this value occupies when serialized.
    pub fn byte_len(&self) -> usize {
        match self {
            DataNumber::U8(_) | DataNumber::I8(_) => 1,
            DataNumber::U16(_) | DataNumber::I16(_) => 2,
            DataNumber::U24(_) | DataNumber::I24(_) => 3,
            DataNumber::U32(_) | DataNumber::I32(_) => 4,
            DataNumber::U64(_) | DataNumber::I64(_) => 8,
            DataNumber::U128(_) | DataNumber::I128(_) => 16,
            DataNumber::Vec(v) => v.len(),
        }
    }

    /// Write big-endian bytes into a caller-provided buffer.
    pub fn write_be_bytes(&self, buf: &mut Vec<u8>) -> Result<(), std::io::Error> {
        match self {
            DataNumber::U8(n) => buf.push(*n),
            DataNumber::I8(n) => buf.push(*n as u8),
            DataNumber::U16(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::I16(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::U24(n) => {
                debug_assert!(
                    *n <= 0x00FF_FFFF,
                    "U24 value {n} out of range (max 16777215)"
                );
                let masked = *n & 0x00FF_FFFF;
                buf.push((masked >> 16) as u8);
                buf.push((masked >> 8) as u8);
                buf.push(masked as u8);
            }
            DataNumber::I24(n) => {
                debug_assert!(
                    (-8_388_608..=8_388_607).contains(n),
                    "I24 value {n} out of range (-8388608..=8388607)"
                );
                let masked = *n & 0x00FF_FFFF;
                buf.push((masked >> 16) as u8);
                buf.push((masked >> 8) as u8);
                buf.push(masked as u8);
            }
            DataNumber::U32(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::U64(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::I64(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::U128(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::I32(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::I128(n) => buf.extend_from_slice(&n.to_be_bytes()),
            DataNumber::Vec(v) => buf.extend_from_slice(v),
        }
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Clone, Serialize)]
pub struct ApplicationId {
    pub classification_engine_id: u8,
    pub selector_id: Option<DataNumber>,
}

/// Preserves the original time unit, field width, and sub-second precision
/// so that round-trip serialization is lossless.
///
/// `PartialEq` and `PartialOrd` compare semantically via `as_duration()`,
/// so `Seconds { value: 1, .. }` == `Millis { value: 1000, .. }`.
#[derive(Debug, Clone)]
pub enum DurationValue {
    /// Duration in seconds, stored as 4 or 8 bytes
    Seconds { value: u64, width: u8 },
    /// Duration in milliseconds, stored as 4 or 8 bytes
    Millis { value: u64, width: u8 },
    /// Duration in NTP microsecond format (seconds + fractional), always 8 bytes
    MicrosNtp { seconds: u32, fraction: u32 },
    /// Duration in NTP nanosecond format (seconds + fractional), always 8 bytes
    NanosNtp { seconds: u32, fraction: u32 },
}

impl PartialEq for DurationValue {
    fn eq(&self, other: &Self) -> bool {
        self.as_duration() == other.as_duration()
    }
}

impl Eq for DurationValue {}

impl Ord for DurationValue {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.as_duration().cmp(&other.as_duration())
    }
}

impl PartialOrd for DurationValue {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl DurationValue {
    /// Convert to a `std::time::Duration` for ergonomic access.
    pub fn as_duration(&self) -> std::time::Duration {
        match self {
            DurationValue::Seconds { value, .. } => std::time::Duration::from_secs(*value),
            DurationValue::Millis { value, .. } => std::time::Duration::from_millis(*value),
            DurationValue::MicrosNtp { seconds, fraction } => {
                // NTP fractional part: fraction / 2^32 of a second.
                // Multiply then right-shift to convert to microseconds.
                // Precision loss is < 1 microsecond, inherent to this conversion.
                let micros = ((u64::from(*fraction)).saturating_mul(1_000_000)) >> 32;
                std::time::Duration::from_secs(u64::from(*seconds))
                    .saturating_add(std::time::Duration::from_micros(micros))
            }
            DurationValue::NanosNtp { seconds, fraction } => {
                // NTP fractional part: fraction / 2^32 of a second.
                // Multiply then right-shift to convert to nanoseconds.
                // Precision loss is < 1 nanosecond, inherent to this conversion.
                let nanos = ((u64::from(*fraction)).saturating_mul(1_000_000_000)) >> 32;
                std::time::Duration::from_secs(u64::from(*seconds))
                    .saturating_add(std::time::Duration::from_nanos(nanos))
            }
        }
    }
}

impl Serialize for DurationValue {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        // Serialize as the computed Duration for JSON compatibility
        let dur = self.as_duration();
        dur.serialize(serializer)
    }
}

/// Preserves the original wire bytes alongside the cleaned display string
/// so that round-trip serialization is lossless.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Clone)]
pub struct StringValue {
    /// Cleaned display string (lossy UTF-8, control chars filtered, P4 stripped)
    pub value: String,
    /// Original wire bytes for faithful serialization
    pub raw: Vec<u8>,
}

impl Serialize for StringValue {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        // Serialize only the cleaned value to preserve current JSON output
        self.value.serialize(serializer)
    }
}

/// Holds the post parsed field with its relevant datatype
#[non_exhaustive]
#[derive(Debug, PartialEq, PartialOrd, Clone)]
pub enum FieldValue {
    ApplicationId(ApplicationId),
    String(StringValue),
    DataNumber(DataNumber),
    Float64(f64),
    Duration(DurationValue),
    Ip4Addr(Ipv4Addr),
    Ip6Addr(Ipv6Addr),
    MacAddr([u8; 6]),
    Vec(Vec<u8>),
    ProtocolType(ProtocolTypes),
    ForwardingStatus(ForwardingStatus),
    FragmentFlags(FragmentFlags),
    /// TCP control bits with wire width (1 or 2 bytes).
    TcpControlBits(TcpControlBits, u8),
    Ipv6ExtensionHeaders(Ipv6ExtensionHeaders),
    Ipv4Options(Ipv4Options),
    TcpOptions(TcpOptions),
    IsMulticast(IsMulticast),
    MplsLabelExp(MplsLabelExp),
    FlowEndReason(FlowEndReason),
    NatEvent(NatEvent),
    FirewallEvent(FirewallEvent),
    MplsTopLabelType(MplsTopLabelType),
    NatOriginatingAddressRealm(NatOriginatingAddressRealm),
}

impl Serialize for FieldValue {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            FieldValue::ApplicationId(v) => {
                serializer.serialize_newtype_variant("FieldValue", 0, "ApplicationId", v)
            }
            FieldValue::String(v) => {
                serializer.serialize_newtype_variant("FieldValue", 1, "String", &v.value)
            }
            FieldValue::DataNumber(v) => {
                serializer.serialize_newtype_variant("FieldValue", 2, "DataNumber", v)
            }
            FieldValue::Float64(v) => {
                if v.is_finite() {
                    serializer.serialize_newtype_variant("FieldValue", 3, "Float64", v)
                } else {
                    // NaN and Infinity cannot be represented in JSON;
                    // serialize as null to avoid failing the entire packet.
                    serializer.serialize_newtype_variant("FieldValue", 3, "Float64", &())
                }
            }
            FieldValue::Duration(v) => {
                serializer.serialize_newtype_variant("FieldValue", 4, "Duration", v)
            }
            FieldValue::Ip4Addr(v) => {
                serializer.serialize_newtype_variant("FieldValue", 5, "Ip4Addr", v)
            }
            FieldValue::Ip6Addr(v) => {
                serializer.serialize_newtype_variant("FieldValue", 6, "Ip6Addr", v)
            }
            FieldValue::MacAddr(bytes) => {
                let formatted = format_mac_addr(bytes);
                serializer.serialize_newtype_variant("FieldValue", 7, "MacAddr", &formatted)
            }
            FieldValue::Vec(v) => {
                serializer.serialize_newtype_variant("FieldValue", 8, "Vec", v)
            }
            FieldValue::ProtocolType(v) => {
                serializer.serialize_newtype_variant("FieldValue", 9, "ProtocolType", v)
            }
            FieldValue::ForwardingStatus(v) => {
                serializer.serialize_newtype_variant("FieldValue", 10, "ForwardingStatus", v)
            }
            FieldValue::FragmentFlags(v) => {
                serializer.serialize_newtype_variant("FieldValue", 11, "FragmentFlags", v)
            }
            FieldValue::TcpControlBits(v, _) => {
                serializer.serialize_newtype_variant("FieldValue", 12, "TcpControlBits", v)
            }
            FieldValue::Ipv6ExtensionHeaders(v) => serializer.serialize_newtype_variant(
                "FieldValue",
                13,
                "Ipv6ExtensionHeaders",
                v,
            ),
            FieldValue::Ipv4Options(v) => {
                serializer.serialize_newtype_variant("FieldValue", 14, "Ipv4Options", v)
            }
            FieldValue::TcpOptions(v) => {
                serializer.serialize_newtype_variant("FieldValue", 15, "TcpOptions", v)
            }
            FieldValue::IsMulticast(v) => {
                serializer.serialize_newtype_variant("FieldValue", 16, "IsMulticast", v)
            }
            FieldValue::MplsLabelExp(v) => {
                serializer.serialize_newtype_variant("FieldValue", 17, "MplsLabelExp", v)
            }
            FieldValue::FlowEndReason(v) => {
                serializer.serialize_newtype_variant("FieldValue", 18, "FlowEndReason", v)
            }
            FieldValue::NatEvent(v) => {
                serializer.serialize_newtype_variant("FieldValue", 19, "NatEvent", v)
            }
            FieldValue::FirewallEvent(v) => {
                serializer.serialize_newtype_variant("FieldValue", 20, "FirewallEvent", v)
            }
            FieldValue::MplsTopLabelType(v) => {
                serializer.serialize_newtype_variant("FieldValue", 21, "MplsTopLabelType", v)
            }
            FieldValue::NatOriginatingAddressRealm(v) => serializer.serialize_newtype_variant(
                "FieldValue",
                22,
                "NatOriginatingAddressRealm",
                v,
            ),
        }
    }
}

impl FieldValue {
    /// Try to extract a `u8`, narrowing across `DataNumber` variants and
    /// converting `ProtocolType` to its numeric value.
    pub fn as_u8(&self) -> Option<u8> {
        match self {
            FieldValue::DataNumber(d) => d.as_u8(),
            FieldValue::ProtocolType(p) => Some(u8::from(*p)),
            _ => None,
        }
    }

    /// Try to extract a `u16`, narrowing across `DataNumber` variants.
    pub fn as_u16(&self) -> Option<u16> {
        match self {
            FieldValue::DataNumber(d) => d.as_u16(),
            _ => None,
        }
    }

    /// Try to extract a `u64`, widening or narrowing across `DataNumber` variants
    /// and converting `Duration` to milliseconds.
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            FieldValue::DataNumber(d) => d.as_u64(),
            FieldValue::Duration(d) => match d {
                DurationValue::Millis { value, .. } => Some(*value),
                DurationValue::Seconds { value, .. } => value.checked_mul(1000),
                DurationValue::MicrosNtp { seconds, fraction } => {
                    let millis = ((u64::from(*fraction)).saturating_mul(1_000)) >> 32;
                    u64::from(*seconds)
                        .checked_mul(1000)
                        .and_then(|s| s.checked_add(millis))
                }
                DurationValue::NanosNtp { seconds, fraction } => {
                    let millis = ((u64::from(*fraction)).saturating_mul(1_000)) >> 32;
                    u64::from(*seconds)
                        .checked_mul(1000)
                        .and_then(|s| s.checked_add(millis))
                }
            },
            _ => None,
        }
    }

    /// Returns the number of bytes this value occupies when serialized.
    pub fn byte_len(&self) -> usize {
        match self {
            FieldValue::ApplicationId(app_id) => {
                1 + app_id.selector_id.as_ref().map_or(0, |s| s.byte_len())
            }
            FieldValue::String(s) => s.raw.len(),
            FieldValue::DataNumber(d) => d.byte_len(),
            FieldValue::Float64(_) => 8,
            FieldValue::Duration(d) => match d {
                DurationValue::Seconds { width, .. } | DurationValue::Millis { width, .. } => {
                    *width as usize
                }
                DurationValue::MicrosNtp { .. } | DurationValue::NanosNtp { .. } => 8,
            },
            FieldValue::Ip4Addr(_) => 4,
            FieldValue::Ip6Addr(_) => 16,
            FieldValue::MacAddr(_) => 6,
            FieldValue::ProtocolType(_) => 1,
            FieldValue::ForwardingStatus(_) => 1,
            FieldValue::FragmentFlags(_) => 1,
            FieldValue::TcpControlBits(_, w) => *w as usize,
            FieldValue::Ipv6ExtensionHeaders(_) => 4,
            FieldValue::Ipv4Options(_) => 4,
            FieldValue::TcpOptions(_) => 8,
            FieldValue::IsMulticast(_) => 1,
            FieldValue::MplsLabelExp(_) => 1,
            FieldValue::FlowEndReason(_) => 1,
            FieldValue::NatEvent(_) => 1,
            FieldValue::FirewallEvent(_) => 1,
            FieldValue::MplsTopLabelType(_) => 1,
            FieldValue::NatOriginatingAddressRealm(_) => 1,
            FieldValue::Vec(v) => v.len(),
        }
    }

    /// Write big-endian bytes into a caller-provided buffer.
    pub fn write_be_bytes(&self, buf: &mut Vec<u8>) -> Result<(), std::io::Error> {
        match self {
            FieldValue::ApplicationId(app_id) => {
                buf.push(app_id.classification_engine_id);
                if let Some(ref sid) = app_id.selector_id {
                    sid.write_be_bytes(buf)?;
                }
            }
            FieldValue::String(s) => buf.extend_from_slice(&s.raw),
            FieldValue::DataNumber(d) => d.write_be_bytes(buf)?,
            FieldValue::Float64(f) => buf.extend_from_slice(&f.to_be_bytes()),
            FieldValue::Duration(d) => match d {
                DurationValue::Seconds { value, width }
                | DurationValue::Millis { value, width } => match *width {
                    2 => {
                        let v = u16::try_from(*value).map_err(std::io::Error::other)?;
                        buf.extend_from_slice(&v.to_be_bytes());
                    }
                    4 => {
                        let v = u32::try_from(*value).map_err(std::io::Error::other)?;
                        buf.extend_from_slice(&v.to_be_bytes());
                    }
                    8 => {
                        buf.extend_from_slice(&value.to_be_bytes());
                    }
                    w => {
                        return Err(std::io::Error::other(format!(
                            "invalid duration width: {w}"
                        )));
                    }
                },
                DurationValue::MicrosNtp { seconds, fraction }
                | DurationValue::NanosNtp { seconds, fraction } => {
                    buf.extend_from_slice(&seconds.to_be_bytes());
                    buf.extend_from_slice(&fraction.to_be_bytes());
                }
            },
            FieldValue::Ip4Addr(ip) => buf.extend_from_slice(&ip.octets()),
            FieldValue::Ip6Addr(ip) => buf.extend_from_slice(&ip.octets()),
            FieldValue::MacAddr(mac) => buf.extend_from_slice(mac),
            FieldValue::ProtocolType(p) => buf.push(u8::from(*p)),
            FieldValue::ForwardingStatus(f) => buf.push(u8::from(*f)),
            FieldValue::FragmentFlags(f) => buf.push(u8::from(*f)),
            FieldValue::TcpControlBits(t, w) => {
                let val = u16::from(*t);
                if *w == 1 {
                    buf.push((val & 0xFF) as u8);
                } else {
                    buf.extend_from_slice(&val.to_be_bytes());
                }
            }
            FieldValue::Ipv6ExtensionHeaders(h) => {
                buf.extend_from_slice(&u32::from(*h).to_be_bytes())
            }
            FieldValue::Ipv4Options(o) => buf.extend_from_slice(&u32::from(*o).to_be_bytes()),
            FieldValue::TcpOptions(o) => buf.extend_from_slice(&u64::from(*o).to_be_bytes()),
            FieldValue::IsMulticast(m) => buf.push(u8::from(*m)),
            FieldValue::MplsLabelExp(e) => buf.push(u8::from(*e)),
            FieldValue::FlowEndReason(r) => buf.push(u8::from(*r)),
            FieldValue::NatEvent(e) => buf.push(u8::from(*e)),
            FieldValue::FirewallEvent(e) => buf.push(u8::from(*e)),
            FieldValue::MplsTopLabelType(t) => buf.push(u8::from(*t)),
            FieldValue::NatOriginatingAddressRealm(r) => buf.push(u8::from(*r)),
            FieldValue::Vec(v) => buf.extend_from_slice(v),
        }
        Ok(())
    }

    #[inline]
    pub fn from_field_type(
        remaining: &[u8],
        field_type: FieldDataType,
        field_length: u16,
    ) -> IResult<&[u8], FieldValue> {
        let (remaining, field_value) = match field_type {
            FieldDataType::ApplicationId => {
                let selector_length = field_length.checked_sub(1).ok_or_else(|| {
                    nom::Err::Error(nom::error::Error::new(
                        remaining,
                        nom::error::ErrorKind::Verify,
                    ))
                })?;
                let (i, id) = u8::parse(remaining)?;
                let (i, selector_id) = if selector_length == 0 {
                    (i, None)
                } else {
                    let (i, sid) = DataNumber::parse(i, selector_length, false)?;
                    (i, Some(sid))
                };
                (
                    i,
                    FieldValue::ApplicationId(ApplicationId {
                        classification_engine_id: id,
                        selector_id,
                    }),
                )
            }
            FieldDataType::UnsignedDataNumber => {
                let (i, data_number) = DataNumber::parse(remaining, field_length, false)?;
                (i, FieldValue::DataNumber(data_number))
            }
            FieldDataType::SignedDataNumber => {
                let (i, data_number) = DataNumber::parse(remaining, field_length, true)?;
                (i, FieldValue::DataNumber(data_number))
            }
            FieldDataType::String => {
                let (i, taken) = take(field_length)(remaining)?;
                let raw = taken.to_vec();
                let lossy = String::from_utf8_lossy(taken);
                let s: String = lossy.chars().filter(|&c| !c.is_control()).collect();
                (i, FieldValue::String(StringValue { value: s, raw }))
            }
            FieldDataType::Ip4Addr if field_length == 4 => {
                let (i, taken) = parse_u32_be(remaining)?;
                let ip_addr = Ipv4Addr::from(taken);
                (i, FieldValue::Ip4Addr(ip_addr))
            }
            FieldDataType::Ip6Addr if field_length == 16 => {
                let (i, taken) = parse_u128_be(remaining)?;
                let ip_addr = Ipv6Addr::from(taken);
                (i, FieldValue::Ip6Addr(ip_addr))
            }
            FieldDataType::MacAddr if field_length == 6 => {
                let (i, taken) = parse_6_bytes(remaining)?;
                (i, FieldValue::MacAddr(taken))
            }
            // Fall back to raw bytes when field_length doesn't match expected size
            FieldDataType::Ip4Addr | FieldDataType::Ip6Addr | FieldDataType::MacAddr => {
                let (i, taken) = take(field_length)(remaining)?;
                (i, FieldValue::Vec(taken.to_vec()))
            }
            FieldDataType::DurationSeconds if matches!(field_length, 2 | 4 | 8) => {
                parse_duration(remaining, field_length, |value, width| {
                    DurationValue::Seconds { value, width }
                })?
            }
            FieldDataType::DurationMillis if matches!(field_length, 2 | 4 | 8) => {
                parse_duration(remaining, field_length, |value, width| {
                    DurationValue::Millis { value, width }
                })?
            }
            FieldDataType::DurationMicrosNTP if field_length == 8 => {
                let (i, seconds) = u32::parse_be(remaining)?;
                let (i, fraction) = u32::parse_be(i)?;
                (
                    i,
                    FieldValue::Duration(DurationValue::MicrosNtp { seconds, fraction }),
                )
            }
            FieldDataType::DurationNanosNTP if field_length == 8 => {
                let (i, seconds) = u32::parse_be(remaining)?;
                let (i, fraction) = u32::parse_be(i)?;
                (
                    i,
                    FieldValue::Duration(DurationValue::NanosNtp { seconds, fraction }),
                )
            }
            FieldDataType::DurationMicrosNTP | FieldDataType::DurationNanosNTP => {
                let (i, taken) = take(field_length)(remaining)?;
                (i, FieldValue::Vec(taken.to_vec()))
            }
            FieldDataType::ProtocolType if field_length == 1 => {
                let (i, protocol) = ProtocolTypes::parse(remaining)?;
                (i, FieldValue::ProtocolType(protocol))
            }
            FieldDataType::ForwardingStatus if field_length == 1 => {
                let (i, status) = ForwardingStatus::parse(remaining)?;
                (i, FieldValue::ForwardingStatus(status))
            }
            FieldDataType::FragmentFlags if field_length == 1 => {
                let (i, flags) = FragmentFlags::parse(remaining)?;
                (i, FieldValue::FragmentFlags(flags))
            }
            FieldDataType::TcpControlBits if field_length == 2 => {
                let (i, bits) = TcpControlBits::parse(remaining)?;
                (i, FieldValue::TcpControlBits(bits, 2))
            }
            FieldDataType::TcpControlBits if field_length == 1 => {
                let (i, byte) = u8::parse(remaining)?;
                (
                    i,
                    FieldValue::TcpControlBits(TcpControlBits::from(u16::from(byte)), 1),
                )
            }
            FieldDataType::Ipv6ExtensionHeaders if field_length == 4 => {
                let (i, headers) = Ipv6ExtensionHeaders::parse(remaining)?;
                (i, FieldValue::Ipv6ExtensionHeaders(headers))
            }
            FieldDataType::Ipv4Options if field_length == 4 => {
                let (i, opts) = Ipv4Options::parse(remaining)?;
                (i, FieldValue::Ipv4Options(opts))
            }
            FieldDataType::TcpOptions if field_length == 8 => {
                let (i, opts) = TcpOptions::parse(remaining)?;
                (i, FieldValue::TcpOptions(opts))
            }
            FieldDataType::IsMulticast if field_length == 1 => {
                let (i, m) = IsMulticast::parse(remaining)?;
                (i, FieldValue::IsMulticast(m))
            }
            FieldDataType::MplsLabelExp if field_length == 1 => {
                let (i, exp) = MplsLabelExp::parse(remaining)?;
                (i, FieldValue::MplsLabelExp(exp))
            }
            FieldDataType::FlowEndReason if field_length == 1 => {
                let (i, reason) = FlowEndReason::parse(remaining)?;
                (i, FieldValue::FlowEndReason(reason))
            }
            FieldDataType::NatEvent if field_length == 1 => {
                let (i, event) = NatEvent::parse(remaining)?;
                (i, FieldValue::NatEvent(event))
            }
            FieldDataType::FirewallEvent if field_length == 1 => {
                let (i, event) = FirewallEvent::parse(remaining)?;
                (i, FieldValue::FirewallEvent(event))
            }
            FieldDataType::MplsTopLabelType if field_length == 1 => {
                let (i, lt) = MplsTopLabelType::parse(remaining)?;
                (i, FieldValue::MplsTopLabelType(lt))
            }
            FieldDataType::NatOriginatingAddressRealm if field_length == 1 => {
                let (i, realm) = NatOriginatingAddressRealm::parse(remaining)?;
                (i, FieldValue::NatOriginatingAddressRealm(realm))
            }
            FieldDataType::Float64 if field_length == 8 => {
                let (i, f) = f64::parse(remaining)?;
                (i, FieldValue::Float64(f))
            }
            // Fall back to raw bytes for typed fields with unexpected length
            FieldDataType::ProtocolType
            | FieldDataType::ForwardingStatus
            | FieldDataType::FragmentFlags
            | FieldDataType::TcpControlBits
            | FieldDataType::Ipv6ExtensionHeaders
            | FieldDataType::Ipv4Options
            | FieldDataType::TcpOptions
            | FieldDataType::IsMulticast
            | FieldDataType::MplsLabelExp
            | FieldDataType::FlowEndReason
            | FieldDataType::NatEvent
            | FieldDataType::FirewallEvent
            | FieldDataType::MplsTopLabelType
            | FieldDataType::NatOriginatingAddressRealm
            | FieldDataType::Float64
            | FieldDataType::DurationSeconds
            | FieldDataType::DurationMillis => {
                let (i, taken) = take(field_length)(remaining)?;
                (i, FieldValue::Vec(taken.to_vec()))
            }
            FieldDataType::Vec => {
                let (i, taken) = take(field_length)(remaining)?;
                (i, FieldValue::Vec(taken.to_vec()))
            }
            FieldDataType::Unknown => parse_unknown_fields(remaining, field_length)?,
        };
        Ok((remaining, field_value))
    }
}

/// Specifies the data type for IPFIX/NetFlow field values.
///
/// Each IPFIX field has an associated `FieldDataType` that determines how
/// its raw bytes should be parsed and interpreted. This enum represents all
/// supported data types in the parser.
///
/// # Type Categories
///
/// ## Network Types
/// - [`Ip4Addr`](Self::Ip4Addr) - IPv4 address (4 bytes)
/// - [`Ip6Addr`](Self::Ip6Addr) - IPv6 address (16 bytes)
/// - [`MacAddr`](Self::MacAddr) - MAC address (6 bytes)
///
/// ## Numeric Types
/// - [`UnsignedDataNumber`](Self::UnsignedDataNumber) - Unsigned integers (1-16 bytes)
/// - [`SignedDataNumber`](Self::SignedDataNumber) - Signed integers (1-16 bytes)
/// - [`Float64`](Self::Float64) - 64-bit floating point
///
/// ## Time/Duration Types
/// - [`DurationSeconds`](Self::DurationSeconds) - Duration in seconds
/// - [`DurationMillis`](Self::DurationMillis) - Duration in milliseconds
/// - [`DurationMicrosNTP`](Self::DurationMicrosNTP) - Duration in microseconds (NTP format)
/// - [`DurationNanosNTP`](Self::DurationNanosNTP) - Duration in nanoseconds (NTP format)
///
/// ## Text and Binary Types
/// - [`String`](Self::String) - UTF-8 string data
/// - [`Vec`](Self::Vec) - Raw byte vector
///
/// ## Special Types
/// - [`ApplicationId`](Self::ApplicationId) - Application identifier field
/// - [`ProtocolType`](Self::ProtocolType) - IP protocol number (maps to [`ProtocolTypes`])
/// - [`Unknown`](Self::Unknown) - Unknown or unsupported type
///
/// # Examples
///
/// ```
/// use netflow_parser::variable_versions::field_value::FieldDataType;
/// use netflow_parser::variable_versions::ipfix::lookup::IANAIPFixField;
///
/// // Get the data type for a specific field
/// let field = IANAIPFixField::SourceIpv4address;
/// let data_type: FieldDataType = field.into();
/// assert_eq!(data_type, FieldDataType::Ip4Addr);
///
/// // Different fields have different types
/// let proto_field = IANAIPFixField::ProtocolIdentifier;
/// let proto_type: FieldDataType = proto_field.into();
/// assert_eq!(proto_type, FieldDataType::ProtocolType);
/// ```
///
/// [`ProtocolTypes`]: crate::protocol::ProtocolTypes
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum FieldDataType {
    /// Application identifier field
    ApplicationId,
    /// UTF-8 string data
    String,
    /// Signed integer (can be i8, i16, i24, i32, i64, i128)
    SignedDataNumber,
    /// Unsigned integer (can be u8, u16, u24, u32, u64, u128)
    UnsignedDataNumber,
    /// 64-bit floating point number
    Float64,
    /// Duration in seconds
    DurationSeconds,
    /// Duration in milliseconds
    DurationMillis,
    /// Duration in microseconds (NTP timestamp format)
    DurationMicrosNTP,
    /// Duration in nanoseconds (NTP timestamp format)
    DurationNanosNTP,
    /// IPv4 address (4 bytes)
    Ip4Addr,
    /// IPv6 address (16 bytes)
    Ip6Addr,
    /// MAC address (6 bytes)
    MacAddr,
    /// Raw byte vector for variable-length fields
    Vec,
    /// IP protocol number (see [`ProtocolTypes`])
    ProtocolType,
    /// Forwarding status (see [`ForwardingStatus`])
    ForwardingStatus,
    /// Fragment flags bitmask (field 197)
    FragmentFlags,
    /// TCP control bits / header flags (field 6)
    TcpControlBits,
    /// IPv6 extension headers bitmask (field 64)
    Ipv6ExtensionHeaders,
    /// IPv4 options bitmask (field 208)
    Ipv4Options,
    /// TCP options bitmask (field 209)
    TcpOptions,
    /// Multicast indicator (field 206)
    IsMulticast,
    /// MPLS label experimental bits (fields 203, 237)
    MplsLabelExp,
    /// Flow end reason (field 136)
    FlowEndReason,
    /// NAT event type (field 230)
    NatEvent,
    /// Firewall event (field 233)
    FirewallEvent,
    /// MPLS top label type (field 46)
    MplsTopLabelType,
    /// NAT originating address realm (field 229)
    NatOriginatingAddressRealm,
    /// Unknown or unsupported field type
    Unknown,
}

#[cfg(test)]
mod field_value_tests {
    use super::{
        DataNumber, DurationValue, FieldDataType, FieldValue, ProtocolTypes, StringValue,
    };
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn it_tests_3_byte_data_number_exports() {
        let data = DataNumber::parse(&[1, 246, 118], 3, false).unwrap().1;
        let mut buf = Vec::new();
        data.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![1, 246, 118]);
    }

    #[test]
    fn it_tests_field_value_to_be_bytes() {
        let mut buf = Vec::new();

        let field_value = FieldValue::String(StringValue {
            value: "test".to_string(),
            raw: b"test".to_vec(),
        });
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![116, 101, 115, 116]);

        let field_value = FieldValue::DataNumber(DataNumber::U16(12345));
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![48, 57]);

        let field_value = FieldValue::Float64(123.456);
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, 123.456f64.to_be_bytes().to_vec());

        let field_value = FieldValue::Duration(DurationValue::Seconds {
            value: 12345,
            width: 4,
        });
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![0, 0, 48, 57]);

        let field_value = FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 0, 1));
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![192, 168, 0, 1]);

        let field_value = FieldValue::Ip6Addr(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1));
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(
            buf,
            vec![32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        );

        let field_value = FieldValue::MacAddr([0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7]);
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7]);

        let field_value = FieldValue::ProtocolType(ProtocolTypes::Tcp);
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![6]);

        let field_value = FieldValue::Vec(vec![1, 2, 3, 4]);
        buf.clear();
        field_value.write_be_bytes(&mut buf).unwrap();
        assert_eq!(buf, vec![1, 2, 3, 4]);
    }

    #[test]
    fn it_tests_field_value_from_field_type() {
        let data = &[1, 2, 3, 4];
        let field_value =
            FieldValue::from_field_type(data, FieldDataType::UnsignedDataNumber, 4)
                .unwrap()
                .1;
        assert_eq!(
            field_value,
            FieldValue::DataNumber(DataNumber::U32(16909060))
        );

        let data = &[192, 168, 0, 1];
        let field_value = FieldValue::from_field_type(data, FieldDataType::Ip4Addr, 4)
            .unwrap()
            .1;
        assert_eq!(
            field_value,
            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 0, 1))
        );

        let data = &[32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];
        let field_value = FieldValue::from_field_type(data, FieldDataType::Ip6Addr, 16)
            .unwrap()
            .1;
        assert_eq!(
            field_value,
            FieldValue::Ip6Addr(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1))
        );
    }

    #[test]
    fn test_data_number_as_u8() {
        assert_eq!(DataNumber::U8(42).as_u8(), Some(42));
        assert_eq!(DataNumber::U16(255).as_u8(), Some(255));
        assert_eq!(DataNumber::U16(256).as_u8(), None);
        assert_eq!(DataNumber::U32(100).as_u8(), Some(100));
        assert_eq!(DataNumber::U64(300).as_u8(), None);
        assert_eq!(DataNumber::I8(-1).as_u8(), None);
        assert_eq!(DataNumber::I8(127).as_u8(), Some(127));
        assert_eq!(DataNumber::I16(-1).as_u8(), None);
        assert_eq!(DataNumber::I32(200).as_u8(), Some(200));
        assert_eq!(DataNumber::U128(255).as_u8(), Some(255));
        assert_eq!(DataNumber::U128(256).as_u8(), None);
        assert_eq!(DataNumber::Vec(vec![1, 2]).as_u8(), None);
    }

    #[test]
    fn test_data_number_as_u16() {
        assert_eq!(DataNumber::U8(42).as_u16(), Some(42));
        assert_eq!(DataNumber::U16(65535).as_u16(), Some(65535));
        assert_eq!(DataNumber::U32(65536).as_u16(), None);
        assert_eq!(DataNumber::U32(1000).as_u16(), Some(1000));
        assert_eq!(DataNumber::I8(-1).as_u16(), None);
        assert_eq!(DataNumber::I16(32000).as_u16(), Some(32000));
        assert_eq!(DataNumber::I16(-1).as_u16(), None);
        assert_eq!(DataNumber::U64(70000).as_u16(), None);
        assert_eq!(DataNumber::Vec(vec![1]).as_u16(), None);
    }

    #[test]
    fn test_data_number_as_u64() {
        assert_eq!(DataNumber::U8(42).as_u64(), Some(42));
        assert_eq!(DataNumber::U16(1000).as_u64(), Some(1000));
        assert_eq!(DataNumber::U32(100_000).as_u64(), Some(100_000));
        assert_eq!(DataNumber::U64(u64::MAX).as_u64(), Some(u64::MAX));
        assert_eq!(DataNumber::I8(-1).as_u64(), None);
        assert_eq!(DataNumber::I64(1_000_000).as_u64(), Some(1_000_000));
        assert_eq!(DataNumber::I64(-1).as_u64(), None);
        assert_eq!(DataNumber::U128(u64::MAX as u128).as_u64(), Some(u64::MAX));
        assert_eq!(DataNumber::U128(u64::MAX as u128 + 1).as_u64(), None);
        assert_eq!(DataNumber::Vec(vec![1]).as_u64(), None);
    }

    #[test]
    fn test_field_value_as_u8() {
        assert_eq!(FieldValue::DataNumber(DataNumber::U8(6)).as_u8(), Some(6));
        assert_eq!(
            FieldValue::ProtocolType(ProtocolTypes::Tcp).as_u8(),
            Some(6)
        );
        assert_eq!(FieldValue::Float64(1.0).as_u8(), None);
        assert_eq!(FieldValue::Ip4Addr(Ipv4Addr::LOCALHOST).as_u8(), None);
    }

    #[test]
    fn test_field_value_as_u16() {
        assert_eq!(
            FieldValue::DataNumber(DataNumber::U16(80)).as_u16(),
            Some(80)
        );
        assert_eq!(FieldValue::Float64(1.0).as_u16(), None);
    }

    #[test]
    fn test_field_value_as_u64() {
        assert_eq!(
            FieldValue::DataNumber(DataNumber::U32(1000)).as_u64(),
            Some(1000)
        );
        assert_eq!(
            FieldValue::Duration(DurationValue::Millis {
                value: 5000,
                width: 4
            })
            .as_u64(),
            Some(5000)
        );
        assert_eq!(
            FieldValue::Duration(DurationValue::Seconds {
                value: 10,
                width: 4
            })
            .as_u64(),
            Some(10_000)
        );
        assert_eq!(FieldValue::Float64(1.0).as_u64(), None);
    }
}
