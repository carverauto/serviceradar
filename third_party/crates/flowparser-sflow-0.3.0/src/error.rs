use serde::de::{self, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;

/// Identifies the parsing phase or field where an error occurred.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParseContext {
    DatagramHeader,
    DatagramHeaderVersion,
    AgentAddress,
    SubAgentId,
    SequenceNumber,
    Uptime,
    NumSamples,
    SampleDataFormat,
    SampleLength,
    SampleData,
    FlowSample,
    CounterSample,
    ExpandedFlowSample,
    ExpandedCounterSample,
    DiscardedPacket,
}

impl fmt::Display for ParseContext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            ParseContext::DatagramHeader => "datagram header",
            ParseContext::DatagramHeaderVersion => "datagram header version",
            ParseContext::AgentAddress => "agent address",
            ParseContext::SubAgentId => "sub_agent_id",
            ParseContext::SequenceNumber => "sequence_number",
            ParseContext::Uptime => "uptime",
            ParseContext::NumSamples => "num_samples",
            ParseContext::SampleDataFormat => "sample data_format",
            ParseContext::SampleLength => "sample length",
            ParseContext::SampleData => "sample data",
            ParseContext::FlowSample => "flow sample",
            ParseContext::CounterSample => "counter sample",
            ParseContext::ExpandedFlowSample => "expanded flow sample",
            ParseContext::ExpandedCounterSample => "expanded counter sample",
            ParseContext::DiscardedPacket => "discarded packet",
        };
        f.write_str(s)
    }
}

/// Describes the category of a parse error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseErrorKind {
    InvalidAddressType,
    NomError(nom::error::ErrorKind),
}

impl fmt::Display for ParseErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseErrorKind::InvalidAddressType => f.write_str("InvalidAddressType"),
            ParseErrorKind::NomError(kind) => write!(f, "{kind:?}"),
        }
    }
}

impl Serialize for ParseErrorKind {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for ParseErrorKind {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ParseErrorKindVisitor;

        impl<'de> Visitor<'de> for ParseErrorKindVisitor {
            type Value = ParseErrorKind;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a ParseErrorKind string")
            }

            fn visit_str<E: de::Error>(self, value: &str) -> Result<ParseErrorKind, E> {
                if value == "InvalidAddressType" {
                    return Ok(ParseErrorKind::InvalidAddressType);
                }
                // Try to match nom ErrorKind variants by their Debug name
                let kind = match value {
                    "Tag" => nom::error::ErrorKind::Tag,
                    "MapRes" => nom::error::ErrorKind::MapRes,
                    "MapOpt" => nom::error::ErrorKind::MapOpt,
                    "Alt" => nom::error::ErrorKind::Alt,
                    "IsNot" => nom::error::ErrorKind::IsNot,
                    "IsA" => nom::error::ErrorKind::IsA,
                    "SeparatedList" => nom::error::ErrorKind::SeparatedList,
                    "SeparatedNonEmptyList" => nom::error::ErrorKind::SeparatedNonEmptyList,
                    "Many0" => nom::error::ErrorKind::Many0,
                    "Many1" => nom::error::ErrorKind::Many1,
                    "ManyTill" => nom::error::ErrorKind::ManyTill,
                    "Count" => nom::error::ErrorKind::Count,
                    "TakeUntil" => nom::error::ErrorKind::TakeUntil,
                    "LengthValue" => nom::error::ErrorKind::LengthValue,
                    "TagClosure" => nom::error::ErrorKind::TagClosure,
                    "Alpha" => nom::error::ErrorKind::Alpha,
                    "Digit" => nom::error::ErrorKind::Digit,
                    "HexDigit" => nom::error::ErrorKind::HexDigit,
                    "OctDigit" => nom::error::ErrorKind::OctDigit,
                    "AlphaNumeric" => nom::error::ErrorKind::AlphaNumeric,
                    "Space" => nom::error::ErrorKind::Space,
                    "MultiSpace" => nom::error::ErrorKind::MultiSpace,
                    "LengthValueFn" => nom::error::ErrorKind::LengthValueFn,
                    "Eof" => nom::error::ErrorKind::Eof,
                    "Switch" => nom::error::ErrorKind::Switch,
                    "TagBits" => nom::error::ErrorKind::TagBits,
                    "OneOf" => nom::error::ErrorKind::OneOf,
                    "NoneOf" => nom::error::ErrorKind::NoneOf,
                    "Char" => nom::error::ErrorKind::Char,
                    "CrLf" => nom::error::ErrorKind::CrLf,
                    "RegexpMatch" => nom::error::ErrorKind::RegexpMatch,
                    "RegexpMatches" => nom::error::ErrorKind::RegexpMatches,
                    "RegexpFind" => nom::error::ErrorKind::RegexpFind,
                    "RegexpCapture" => nom::error::ErrorKind::RegexpCapture,
                    "RegexpCaptures" => nom::error::ErrorKind::RegexpCaptures,
                    "TakeWhile1" => nom::error::ErrorKind::TakeWhile1,
                    "Complete" => nom::error::ErrorKind::Complete,
                    "Fix" => nom::error::ErrorKind::Fix,
                    "Escaped" => nom::error::ErrorKind::Escaped,
                    "EscapedTransform" => nom::error::ErrorKind::EscapedTransform,
                    "NonEmpty" => nom::error::ErrorKind::NonEmpty,
                    "ManyMN" => nom::error::ErrorKind::ManyMN,
                    "Not" => nom::error::ErrorKind::Not,
                    "Permutation" => nom::error::ErrorKind::Permutation,
                    "Verify" => nom::error::ErrorKind::Verify,
                    "TakeTill1" => nom::error::ErrorKind::TakeTill1,
                    "TakeWhileMN" => nom::error::ErrorKind::TakeWhileMN,
                    "TooLarge" => nom::error::ErrorKind::TooLarge,
                    "Many0Count" => nom::error::ErrorKind::Many0Count,
                    "Many1Count" => nom::error::ErrorKind::Many1Count,
                    "Float" => nom::error::ErrorKind::Float,
                    "Satisfy" => nom::error::ErrorKind::Satisfy,
                    "Fail" => nom::error::ErrorKind::Fail,
                    _ => {
                        return Err(de::Error::unknown_variant(
                            value,
                            &["InvalidAddressType", "<nom ErrorKind variant>"],
                        ));
                    }
                };
                Ok(ParseErrorKind::NomError(kind))
            }
        }

        deserializer.deserialize_str(ParseErrorKindVisitor)
    }
}

/// Errors that can occur when parsing sFlow datagrams.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SflowError {
    /// The input buffer is too short to read the expected field.
    Incomplete {
        /// Number of bytes available.
        available: usize,
        /// Expected number of bytes, when known.
        expected: Option<usize>,
        /// The parsing phase where the error occurred.
        context: ParseContext,
    },
    /// The datagram version is not sFlow v5.
    UnsupportedVersion {
        /// The version number found in the datagram header.
        version: u32,
    },
    /// A structural parse error at a known offset.
    ParseError {
        /// Byte offset from the start of the datagram.
        offset: usize,
        /// The parsing phase where the error occurred.
        context: ParseContext,
        /// The category of parse error.
        kind: ParseErrorKind,
    },
    /// The datagram contains more samples than the configured limit.
    TooManySamples {
        /// Number of samples declared in the datagram header.
        count: u32,
        /// Configured maximum.
        max: u32,
    },
}

impl fmt::Display for SflowError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SflowError::Incomplete {
                available,
                expected: None,
                context,
            } => {
                write!(
                    f,
                    "Incomplete data: only {available} bytes available ({context})"
                )
            }
            SflowError::Incomplete {
                available,
                expected: Some(exp),
                context,
            } => {
                write!(
                    f,
                    "Incomplete data: only {available} bytes available, expected {exp} ({context})"
                )
            }
            SflowError::UnsupportedVersion { version } => {
                write!(f, "Unsupported sFlow version: {version} (expected 5)")
            }
            SflowError::ParseError {
                offset,
                context,
                kind,
            } => {
                write!(f, "Parse error at offset {offset}: {kind} ({context})")
            }
            SflowError::TooManySamples { count, max } => {
                write!(f, "Too many samples: {count} exceeds maximum of {max}")
            }
        }
    }
}

impl std::error::Error for SflowError {}
