#![ doc = include_str!( concat!( env!( "CARGO_MANIFEST_DIR" ), "/", "README.md" ) ) ]
#![allow(unknown_lints, clippy::doc_markdown)]

use std::fmt;

pub mod asn1;
pub use asn1::AsnReader;
#[cfg(feature = "mibs")]
pub mod mibs;
pub mod pdu;
pub mod snmp;
mod syncsession;
#[cfg(feature = "v3")]
pub mod v3;
#[cfg(feature = "v3")]
pub use openssl;
pub use syncsession::SyncSession;
#[cfg(feature = "tokio")]
mod asyncsession;
#[cfg(feature = "tokio")]
pub use asyncsession::AsyncSession;

pub use pdu::Pdu;

pub use asn1_rs::Oid;

#[cfg(target_pointer_width = "32")]
const USIZE_LEN: usize = 4;
#[cfg(target_pointer_width = "64")]
const USIZE_LEN: usize = 8;

/// SNMP protocol version.
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
#[repr(i64)]
pub enum Version {
    /// SNMPv1
    V1 = 0,
    /// SNMPv2c
    V2C = 1,
    /// SNMPv3
    V3 = 3,
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Version::V1 => write!(f, "SNMPv1"),
            Version::V2C => write!(f, "SNMPv2c"),
            Version::V3 => write!(f, "SNMPv3"),
        }
    }
}

impl TryFrom<i64> for Version {
    type Error = Error;

    fn try_from(value: i64) -> Result<Version> {
        match value {
            0 => Ok(Version::V1),
            1 => Ok(Version::V2C),
            3 => Ok(Version::V3),
            _ => Err(Error::UnsupportedVersion),
        }
    }
}

#[cfg(test)]
mod tests;

/// SNMP error type.
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Error {
    /// ASN.1 parsing error.
    AsnParse,
    /// ASN.1 invalid length.
    AsnInvalidLen,
    /// ASN.1 wrong type.
    AsnWrongType,
    /// ASN.1 unsupported type.
    AsnUnsupportedType,
    /// ASN.1 unexpected end of file.
    AsnEof,
    /// ASN.1 integer overflow.
    AsnIntOverflow,

    /// Invalid SNMP version.
    UnsupportedVersion,
    /// Invalid request ID.
    RequestIdMismatch,
    /// Invalid SNMP community string.
    CommunityMismatch,
    /// Value out of range.
    ValueOutOfRange,
    /// Buffer overflow.
    BufferOverflow,

    /// Authentication failure
    #[cfg(feature = "v3")]
    AuthFailure(v3::AuthErrorKind),
    /// OpenSSL errors
    #[cfg(feature = "v3")]
    Crypto(String),
    /// Security context has been updated, repeat the request
    #[cfg(feature = "v3")]
    AuthUpdated,

    /// Socket send error.
    Send,
    /// Socket receive error.
    Receive,
    /// MIB errors
    Mib(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::AsnParse => write!(f, "ASN.1 parsing error"),
            Error::AsnInvalidLen => write!(f, "ASN.1 invalid length"),
            Error::AsnWrongType => write!(f, "ASN.1 wrong type"),
            Error::AsnUnsupportedType => write!(f, "ASN.1 unsupported type"),
            Error::AsnEof => write!(f, "ASN.1 unexpected end of file"),
            Error::AsnIntOverflow => write!(f, "ASN.1 integer overflow"),
            Error::UnsupportedVersion => write!(f, "Unsupported SNMP version"),
            Error::RequestIdMismatch => write!(f, "Request ID mismatch"),
            Error::CommunityMismatch => write!(f, "Community string mismatch"),
            Error::ValueOutOfRange => write!(f, "Value out of range"),
            Error::BufferOverflow => write!(f, "Buffer overflow"),
            #[cfg(feature = "v3")]
            Error::AuthFailure(err) => write!(f, "Authentication failure: {}", err),
            #[cfg(feature = "v3")]
            Error::Crypto(e) => write!(f, "Cryptographic engine error: {}", e),
            #[cfg(feature = "v3")]
            Error::AuthUpdated => {
                write!(f, "Security context has been updated, repeat the request")
            }
            Error::Send => write!(f, "Socket send error"),
            Error::Receive => write!(f, "Socket receive error"),
            Error::Mib(ref s) => write!(f, "MIB error: {}", s),
        }
    }
}

#[cfg(feature = "v3")]
impl From<openssl::error::ErrorStack> for Error {
    fn from(err: openssl::error::ErrorStack) -> Error {
        Error::Crypto(err.to_string())
    }
}

impl std::error::Error for Error {}

impl From<std::num::TryFromIntError> for Error {
    fn from(_: std::num::TryFromIntError) -> Error {
        Error::AsnIntOverflow
    }
}

type Result<T> = std::result::Result<T, Error>;

const BUFFER_SIZE: usize = 65_507;

pub enum Value<'a> {
    Boolean(bool),
    Null,
    Integer(i64),
    OctetString(&'a [u8]),
    ObjectIdentifier(Oid<'a>),
    Sequence(AsnReader<'a>),
    Set(AsnReader<'a>),
    Constructed(u8, AsnReader<'a>),

    IpAddress([u8; 4]),
    Counter32(u32),
    Unsigned32(u32),
    Timeticks(u32),
    Opaque(&'a [u8]),
    Counter64(u64),

    EndOfMibView,
    NoSuchObject,
    NoSuchInstance,

    GetRequest(AsnReader<'a>),
    GetNextRequest(AsnReader<'a>),
    GetBulkRequest(AsnReader<'a>),
    Response(AsnReader<'a>),
    SetRequest(AsnReader<'a>),
    InformRequest(AsnReader<'a>),
    Trap(AsnReader<'a>),
    Report(AsnReader<'a>),
}

impl fmt::Debug for Value<'_> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            Value::Boolean(v) => write!(f, "BOOLEAN: {}", v),
            Value::Integer(n) => write!(f, "INTEGER: {}", n),
            Value::OctetString(slice) => {
                write!(f, "OCTET STRING: {}", String::from_utf8_lossy(slice))
            }
            Value::ObjectIdentifier(ref obj_id) => write!(f, "OBJECT IDENTIFIER: {}", obj_id),
            Value::Null => write!(f, "NULL"),
            Value::Sequence(ref val) => write!(f, "SEQUENCE: {:#?}", val),
            Value::Set(ref val) => write!(f, "SET: {:?}", val),
            Value::Constructed(ident, ref val) => write!(f, "CONSTRUCTED-{}: {:#?}", ident, val),
            Value::IpAddress(val) => {
                write!(f, "IP ADDRESS: {}.{}.{}.{}", val[0], val[1], val[2], val[3])
            }
            Value::Counter32(val) => write!(f, "COUNTER32: {}", val),
            Value::Unsigned32(val) => write!(f, "UNSIGNED32: {}", val),
            Value::Timeticks(val) => write!(f, "TIMETICKS: {}", val),
            Value::Opaque(val) => write!(f, "OPAQUE: {:?}", val),
            Value::Counter64(val) => write!(f, "COUNTER64: {}", val),
            Value::EndOfMibView => write!(f, "END OF MIB VIEW"),
            Value::NoSuchObject => write!(f, "NO SUCH OBJECT"),
            Value::NoSuchInstance => write!(f, "NO SUCH INSTANCE"),
            Value::GetRequest(ref val) => write!(f, "SNMP GET REQUEST: {:#?}", val),
            Value::GetNextRequest(ref val) => write!(f, "SNMP GET NEXT REQUEST: {:#?}", val),
            Value::GetBulkRequest(ref val) => write!(f, "SNMP GET BULK REQUEST: {:#?}", val),
            Value::Response(ref val) => write!(f, "SNMP RESPONSE: {:#?}", val),
            Value::SetRequest(ref val) => write!(f, "SNMP SET REQUEST: {:#?}", val),
            Value::InformRequest(ref val) => write!(f, "SNMP INFORM REQUEST: {:#?}", val),
            Value::Trap(ref val) => write!(f, "SNMP TRAP: {:#?}", val),
            Value::Report(ref val) => write!(f, "SNMP REPORT: {:#?}", val),
        }
    }
}

fn zero_len(val: &[u8]) -> Result<&[u8]> {
    if val.is_empty() {
        Ok(val)
    } else {
        Err(Error::AsnInvalidLen)
    }
}

impl<'a> Iterator for AsnReader<'a> {
    type Item = Value<'a>;

    fn next(&mut self) -> Option<Value<'a>> {
        if let Ok(ident) = self.peek_byte() {
            let ret: Result<Value> = match ident {
                asn1::TYPE_BOOLEAN => self.read_asn_boolean().map(Value::Boolean),
                asn1::TYPE_NULL => self.read_asn_null().map(|()| Value::Null),
                asn1::TYPE_INTEGER => self.read_asn_integer().map(Value::Integer),
                asn1::TYPE_OCTETSTRING => self.read_asn_octetstring().map(Value::OctetString),
                asn1::TYPE_OBJECTIDENTIFIER => self
                    .read_asn_objectidentifier()
                    .map(Value::ObjectIdentifier),
                asn1::TYPE_SEQUENCE => self
                    .read_raw(ident)
                    .map(|v| Value::Sequence(AsnReader::from_bytes(v))),
                asn1::TYPE_SET => self
                    .read_raw(ident)
                    .map(|v| Value::Set(AsnReader::from_bytes(v))),
                snmp::TYPE_IPADDRESS => self.read_snmp_ipaddress().map(Value::IpAddress),
                snmp::TYPE_COUNTER32 => self.read_snmp_counter32().map(Value::Counter32),
                snmp::TYPE_UNSIGNED32 => self.read_snmp_unsigned32().map(Value::Unsigned32),
                snmp::TYPE_TIMETICKS => self.read_snmp_timeticks().map(Value::Timeticks),
                snmp::TYPE_OPAQUE => self.read_snmp_opaque().map(Value::Opaque),
                snmp::TYPE_COUNTER64 => self.read_snmp_counter64().map(Value::Counter64),
                snmp::MSG_GET => self
                    .read_raw(ident)
                    .map(|v| Value::GetRequest(AsnReader::from_bytes(v))),
                snmp::MSG_GET_NEXT => self
                    .read_raw(ident)
                    .map(|v| Value::GetNextRequest(AsnReader::from_bytes(v))),
                snmp::MSG_GET_BULK => self
                    .read_raw(ident)
                    .map(|v| Value::GetBulkRequest(AsnReader::from_bytes(v))),
                snmp::MSG_RESPONSE => self
                    .read_raw(ident)
                    .map(|v| Value::Response(AsnReader::from_bytes(v))),
                snmp::MSG_SET => self
                    .read_raw(ident)
                    .map(|v| Value::SetRequest(AsnReader::from_bytes(v))),
                snmp::MSG_INFORM => self
                    .read_raw(ident)
                    .map(|v| Value::InformRequest(AsnReader::from_bytes(v))),
                snmp::MSG_TRAP => self
                    .read_raw(ident)
                    .map(|v| Value::Trap(AsnReader::from_bytes(v))),
                snmp::MSG_REPORT => self
                    .read_raw(ident)
                    .map(|v| Value::Report(AsnReader::from_bytes(v))),
                snmp::SNMP_ENDOFMIBVIEW => self
                    .read_raw(ident)
                    .and_then(zero_len)
                    .map(|_v| Value::EndOfMibView),
                snmp::SNMP_NOSUCHOBJECT => self
                    .read_raw(ident)
                    .and_then(zero_len)
                    .map(|_v| Value::NoSuchObject),
                snmp::SNMP_NOSUCHINSTANCE => self
                    .read_raw(ident)
                    .and_then(zero_len)
                    .map(|_v| Value::NoSuchInstance),
                ident if ident & asn1::CONSTRUCTED == asn1::CONSTRUCTED => self
                    .read_raw(ident)
                    .map(|v| Value::Constructed(ident, AsnReader::from_bytes(v))),
                _ => Err(Error::AsnUnsupportedType),
            };
            ret.ok()
        } else {
            None
        }
    }
}

#[derive(Debug, PartialEq, Copy, Clone, Eq)]
pub enum MessageType {
    GetRequest,
    GetNextRequest,
    GetBulkRequest,
    Response,
    SetRequest,
    InformRequest,
    Trap,
    TrapV1,
    Report,
}

impl MessageType {
    pub fn from_ident(ident: u8) -> Result<MessageType> {
        Ok(match ident {
            snmp::MSG_GET => MessageType::GetRequest,
            snmp::MSG_GET_NEXT => MessageType::GetNextRequest,
            snmp::MSG_GET_BULK => MessageType::GetBulkRequest,
            snmp::MSG_RESPONSE => MessageType::Response,
            snmp::MSG_SET => MessageType::SetRequest,
            snmp::MSG_INFORM => MessageType::InformRequest,
            snmp::MSG_TRAP => MessageType::Trap,
            snmp::MSG_REPORT => MessageType::Report,
            snmp::MSG_TRAP_V1 => MessageType::TrapV1,
            _ => return Err(Error::AsnWrongType),
        })
    }
}

#[derive(Clone)]
pub struct Varbinds<'a> {
    inner: AsnReader<'a>,
}

impl fmt::Debug for Varbinds<'_> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // f.debug_list().entries(self.clone()).finish()
        let mut ds = f.debug_struct("Varbinds");
        for (name, val) in self.clone() {
            ds.field(&format!("{}", name), &format!("{:?}", val));
        }
        ds.finish()
    }
}

impl<'a> Varbinds<'a> {
    pub fn from_bytes(bytes: &'a [u8]) -> Varbinds<'a> {
        Varbinds {
            inner: AsnReader::from_bytes(bytes),
        }
    }
}

impl<'a> Iterator for Varbinds<'a> {
    type Item = (Oid<'a>, Value<'a>);
    fn next(&mut self) -> Option<Self::Item> {
        if let Ok(seq) = self.inner.read_raw(asn1::TYPE_SEQUENCE) {
            let mut pair = AsnReader::from_bytes(seq);
            if let (Ok(name), Some(value)) = (pair.read_asn_objectidentifier(), pair.next()) {
                return Some((name, value));
            }
        }
        None
    }
}
