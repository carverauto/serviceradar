//! Attribute-related definitions as defined in X.501 (and updated by RFC 5280).

use alloc::vec::Vec;
use const_oid::db::{
    rfc4519::{COUNTRY_NAME, DOMAIN_COMPONENT, SERIAL_NUMBER},
    Database, DB,
};
use core::{
    fmt::{self, Write},
    str::FromStr,
};
use der::{
    asn1::{
        Any, Ia5StringRef, ObjectIdentifier, PrintableStringRef, SetOfVec, TeletexStringRef,
        Utf8StringRef,
    },
    Decode, Encode, Error, ErrorKind, Sequence, Tag, Tagged, ValueOrd,
};

/// X.501 `AttributeType` as defined in [RFC 5280 Appendix A.1].
///
/// ```text
/// AttributeType           ::= OBJECT IDENTIFIER
/// ```
///
/// [RFC 5280 Appendix A.1]: https://datatracker.ietf.org/doc/html/rfc5280#appendix-A.1
pub type AttributeType = ObjectIdentifier;

/// X.501 `AttributeValue` as defined in [RFC 5280 Appendix A.1].
///
/// ```text
/// AttributeValue          ::= ANY
/// ```
///
/// [RFC 5280 Appendix A.1]: https://datatracker.ietf.org/doc/html/rfc5280#appendix-A.1
pub type AttributeValue = Any;

/// X.501 `Attribute` as defined in [RFC 5280 Appendix A.1].
///
/// ```text
/// Attribute               ::= SEQUENCE {
///     type             AttributeType,
///     values    SET OF AttributeValue -- at least one value is required
/// }
/// ```
///
/// Note that [RFC 2986 Section 4] defines a constrained version of this type:
///
/// ```text
/// Attribute { ATTRIBUTE:IOSet } ::= SEQUENCE {
///     type   ATTRIBUTE.&id({IOSet}),
///     values SET SIZE(1..MAX) OF ATTRIBUTE.&Type({IOSet}{@type})
/// }
/// ```
///
/// The unconstrained version should be preferred.
///
/// [RFC 2986 Section 4]: https://datatracker.ietf.org/doc/html/rfc2986#section-4
/// [RFC 5280 Appendix A.1]: https://datatracker.ietf.org/doc/html/rfc5280#appendix-A.1
#[derive(Clone, Debug, PartialEq, Eq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct Attribute {
    pub oid: AttributeType,
    pub values: SetOfVec<AttributeValue>,
}

/// X.501 `Attributes` as defined in [RFC 2986 Section 4].
///
/// ```text
/// Attributes { ATTRIBUTE:IOSet } ::= SET OF Attribute{{ IOSet }}
/// ```
///
/// [RFC 2986 Section 4]: https://datatracker.ietf.org/doc/html/rfc2986#section-4
pub type Attributes = SetOfVec<Attribute>;

/// X.501 `AttributeTypeAndValue` as defined in [RFC 5280 Appendix A.1].
///
/// ```text
/// AttributeTypeAndValue ::= SEQUENCE {
///   type     AttributeType,
///   value    AttributeValue
/// }
/// ```
///
/// [RFC 5280 Appendix A.1]: https://datatracker.ietf.org/doc/html/rfc5280#appendix-A.1
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Clone, Debug, Eq, PartialEq, PartialOrd, Ord, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct AttributeTypeAndValue {
    pub oid: AttributeType,
    pub value: AttributeValue,
}

#[derive(Copy, Clone)]
enum Escape {
    None,
    Some,
    Hex(u8),
}

struct Parser {
    state: Escape,
    bytes: Vec<u8>,
}

impl Parser {
    pub fn new() -> Self {
        Self {
            state: Escape::None,
            bytes: Vec::new(),
        }
    }

    fn push(&mut self, c: u8) {
        self.state = Escape::None;
        self.bytes.push(c);
    }

    pub fn add(&mut self, c: u8) -> Result<(), Error> {
        match (self.state, c) {
            (Escape::Hex(p), b'0'..=b'9') => self.push(p | (c - b'0')),
            (Escape::Hex(p), b'a'..=b'f') => self.push(p | (c - b'a' + 10)),
            (Escape::Hex(p), b'A'..=b'F') => self.push(p | (c - b'A' + 10)),

            (Escape::Some, b'0'..=b'9') => self.state = Escape::Hex((c - b'0') << 4),
            (Escape::Some, b'a'..=b'f') => self.state = Escape::Hex((c - b'a' + 10) << 4),
            (Escape::Some, b'A'..=b'F') => self.state = Escape::Hex((c - b'A' + 10) << 4),

            (Escape::Some, b' ' | b'"' | b'#' | b'=' | b'\\') => self.push(c),
            (Escape::Some, b'+' | b',' | b';' | b'<' | b'>') => self.push(c),

            (Escape::None, b'\\') => self.state = Escape::Some,
            (Escape::None, ..) => self.push(c),

            _ => return Err(ErrorKind::Failed.into()),
        }

        Ok(())
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }
}

impl AttributeTypeAndValue {
    /// Parses the hex value in the `OID=#HEX` format.
    fn from_hex(oid: ObjectIdentifier, val: &str) -> Result<Self, Error> {
        // Ensure an even number of hex bytes.
        let mut iter = match val.len() % 2 {
            0 => [].iter().cloned().chain(val.bytes()),
            1 => [0u8].iter().cloned().chain(val.bytes()),
            _ => unreachable!(),
        };

        // Decode der bytes from hex.
        let mut bytes = Vec::with_capacity((val.len() + 1) / 2);

        while let (Some(h), Some(l)) = (iter.next(), iter.next()) {
            let mut byte = 0u8;

            for (half, shift) in [(h, 4), (l, 0)] {
                match half {
                    b'0'..=b'9' => byte |= (half - b'0') << shift,
                    b'a'..=b'f' => byte |= (half - b'a' + 10) << shift,
                    b'A'..=b'F' => byte |= (half - b'A' + 10) << shift,
                    _ => return Err(ErrorKind::Failed.into()),
                }
            }

            bytes.push(byte);
        }

        Ok(Self {
            oid,
            value: Any::from_der(&bytes)?,
        })
    }

    /// Parses the string value in the `NAME=STRING` format.
    fn from_delimited_str(oid: ObjectIdentifier, val: &str) -> Result<Self, Error> {
        // Undo escaping.
        let mut parser = Parser::new();
        for c in val.bytes() {
            parser.add(c)?;
        }

        let tag = match oid {
            COUNTRY_NAME => Tag::PrintableString,
            DOMAIN_COMPONENT => Tag::Ia5String,
            // Serial numbers are formatted as Printable String as per RFC 5280 Appendix A.1:
            // https://datatracker.ietf.org/doc/html/rfc5280#appendix-A.1
            SERIAL_NUMBER => Tag::PrintableString,
            _ => Tag::Utf8String,
        };

        Ok(Self {
            oid,
            value: Any::new(tag, parser.as_bytes())?,
        })
    }

    /// Converts an AttributeTypeAndValue string into an encoded AttributeTypeAndValue
    ///
    /// This function follows the rules in [RFC 4514].
    ///
    /// [RFC 4514]: https://datatracker.ietf.org/doc/html/rfc4514
    #[deprecated(
        since = "0.2.1",
        note = "use AttributeTypeAndValue::from_str(...)?.to_der()"
    )]
    pub fn encode_from_string(s: &str) -> Result<Vec<u8>, Error> {
        Self::from_str(s)?.to_der()
    }
}

/// Parse an [`AttributeTypeAndValue`] string.
///
/// This function follows the rules in [RFC 4514].
///
/// [RFC 4514]: https://datatracker.ietf.org/doc/html/rfc4514
impl FromStr for AttributeTypeAndValue {
    type Err = Error;

    fn from_str(s: &str) -> der::Result<Self> {
        let idx = s.find('=').ok_or_else(|| Error::from(ErrorKind::Failed))?;
        let (key, val) = s.split_at(idx);
        let val = &val[1..];

        // Either decode or lookup the OID for the given key.
        let oid = match DB.by_name(key) {
            Some(oid) => *oid,
            None => ObjectIdentifier::new(key)?,
        };

        // If the value is hex-encoded DER...
        match val.strip_prefix('#') {
            Some(val) => Self::from_hex(oid, val),
            None => Self::from_delimited_str(oid, val),
        }
    }
}

/// Serializes the structure according to the rules in [RFC 4514].
///
/// [RFC 4514]: https://datatracker.ietf.org/doc/html/rfc4514
impl fmt::Display for AttributeTypeAndValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let val = match self.value.tag() {
            Tag::PrintableString => PrintableStringRef::try_from(&self.value)
                .ok()
                .map(|s| s.as_str()),
            Tag::Utf8String => Utf8StringRef::try_from(&self.value)
                .ok()
                .map(|s| s.as_str()),
            Tag::Ia5String => Ia5StringRef::try_from(&self.value).ok().map(|s| s.as_str()),
            Tag::TeletexString => TeletexStringRef::try_from(&self.value)
                .ok()
                .map(|s| s.as_str()),
            _ => None,
        };

        if let (Some(key), Some(val)) = (DB.shortest_name_by_oid(&self.oid), val) {
            write!(f, "{}=", key.to_ascii_uppercase())?;

            let mut iter = val.char_indices().peekable();
            while let Some((i, c)) = iter.next() {
                match c {
                    '#' if i == 0 => write!(f, "\\#")?,
                    ' ' if i == 0 || iter.peek().is_none() => write!(f, "\\ ")?,
                    '"' | '+' | ',' | ';' | '<' | '>' | '\\' => write!(f, "\\{}", c)?,
                    '\x00'..='\x1f' | '\x7f' => write!(f, "\\{:02x}", c as u8)?,
                    _ => f.write_char(c)?,
                }
            }
        } else {
            let value = self.value.to_der().or(Err(fmt::Error))?;

            write!(f, "{}=#", self.oid)?;
            for c in value {
                write!(f, "{:02x}", c)?;
            }
        }

        Ok(())
    }
}

/// Helper trait to bring shortest name by oid lookups to Database
trait ShortestName {
    fn shortest_name_by_oid(&self, oid: &ObjectIdentifier) -> Option<&str>;
}

impl<'a> ShortestName for Database<'a> {
    fn shortest_name_by_oid(&self, oid: &ObjectIdentifier) -> Option<&'a str> {
        let mut best_match: Option<&'a str> = None;

        for m in self.find_names_for_oid(*oid) {
            if let Some(previous) = best_match {
                if m.len() < previous.len() {
                    best_match = Some(m);
                }
            } else {
                best_match = Some(m);
            }
        }

        best_match
    }
}
