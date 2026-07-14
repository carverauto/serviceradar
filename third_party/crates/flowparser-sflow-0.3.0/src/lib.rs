#![doc = include_str!("../README.md")]
#![forbid(unsafe_code)]

pub mod counter_records;
pub mod datagram;
pub mod error;
pub mod flow_records;
pub mod samples;

#[cfg(test)]
mod tests;

pub use counter_records::CounterRecord;
pub use datagram::{AddressType, SflowDatagram};
pub use error::{ParseContext, ParseErrorKind, SflowError};
pub use flow_records::FlowRecord;
pub use samples::SflowSample;

use serde::{Deserialize, Serialize};

/// Result of parsing one or more sFlow datagrams from a byte buffer.
///
/// Contains all successfully parsed datagrams and an optional error
/// if parsing failed partway through. This allows partial results
/// when a buffer contains multiple datagrams and one is malformed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParseResult {
    /// Successfully parsed sFlow datagrams.
    pub datagrams: Vec<SflowDatagram>,
    /// Error encountered during parsing, if any. When present,
    /// `datagrams` may still contain successfully parsed entries
    /// from before the error occurred.
    pub error: Option<SflowError>,
}

/// Stateless sFlow v5 datagram parser.
///
/// Unlike NetFlow V9/IPFIX parsers, `SflowParser` requires no mutable state
/// between calls since sFlow v5 is fully self-describing. Each call to
/// [`parse_bytes`](SflowParser::parse_bytes) is independent.
///
/// # Examples
///
/// ```
/// use flowparser_sflow::SflowParser;
///
/// let parser = SflowParser::default();
/// let result = parser.parse_bytes(&[/* sflow datagram bytes */]);
/// for datagram in &result.datagrams {
///     println!("seq={} samples={}", datagram.sequence_number, datagram.samples.len());
/// }
/// ```
#[derive(Debug, Clone, Default)]
pub struct SflowParser {
    max_samples: Option<u32>,
}

impl SflowParser {
    /// Create a builder for configuring the parser.
    pub fn builder() -> SflowParserBuilder {
        SflowParserBuilder { max_samples: None }
    }

    /// Parse one or more sFlow v5 datagrams from a byte slice.
    ///
    /// Returns a [`ParseResult`] containing all successfully parsed datagrams
    /// and an optional error. Parsing is stateless — each call is independent.
    pub fn parse_bytes(&self, packet: &[u8]) -> ParseResult {
        let mut datagrams = Vec::new();
        let mut remaining = packet;

        loop {
            if remaining.is_empty() {
                break;
            }

            if remaining.len() < 4 {
                return ParseResult {
                    datagrams,
                    error: Some(SflowError::Incomplete {
                        available: remaining.len(),
                        expected: None,
                        context: ParseContext::DatagramHeader,
                    }),
                };
            }

            match datagram::parse_datagram(remaining, self.max_samples) {
                Ok((rest, dg)) => {
                    datagrams.push(dg);
                    remaining = rest;
                }
                Err(e) => {
                    return ParseResult {
                        datagrams,
                        error: Some(e),
                    };
                }
            }
        }

        ParseResult {
            datagrams,
            error: None,
        }
    }
}

/// Builder for configuring an [`SflowParser`].
#[derive(Debug, Clone)]
pub struct SflowParserBuilder {
    max_samples: Option<u32>,
}

impl SflowParserBuilder {
    /// Set the maximum number of samples allowed per datagram.
    /// Datagrams exceeding this limit will return a
    /// [`SflowError::TooManySamples`] error before parsing any samples.
    pub fn with_max_samples(mut self, max: u32) -> Self {
        self.max_samples = Some(max);
        self
    }

    /// Build the configured [`SflowParser`].
    pub fn build(self) -> SflowParser {
        SflowParser {
            max_samples: self.max_samples,
        }
    }
}
