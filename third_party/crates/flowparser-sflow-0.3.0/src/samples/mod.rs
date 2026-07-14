pub mod counter_sample;
pub mod discarded_packet;
pub mod flow_sample;

use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::error::{ParseContext, ParseErrorKind, SflowError};
pub use counter_sample::{CounterSample, ExpandedCounterSample};
pub use discarded_packet::DiscardedPacket;
pub use flow_sample::{ExpandedFlowSample, FlowSample};

/// An sFlow sample carried within a datagram.
///
/// Each datagram can contain a mix of flow samples (packet-level data)
/// and counter samples (interface statistics). Expanded variants use
/// separate fields for source ID type and index instead of a packed u32.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum SflowSample {
    /// Standard flow sample (enterprise=0, format=1).
    Flow(FlowSample),
    /// Standard counter sample (enterprise=0, format=2).
    Counter(CounterSample),
    /// Expanded flow sample with unpacked source ID (enterprise=0, format=3).
    ExpandedFlow(ExpandedFlowSample),
    /// Expanded counter sample with unpacked source ID (enterprise=0, format=4).
    ExpandedCounter(ExpandedCounterSample),
    /// Discarded packet notification (enterprise=0, format=5).
    DiscardedPacket(DiscardedPacket),
    /// Unrecognized sample type, preserved as raw bytes.
    Unknown {
        /// Enterprise code from the sample header.
        enterprise: u32,
        /// Format code from the sample header.
        format: u32,
        /// Raw sample data.
        data: Vec<u8>,
    },
}

pub(crate) fn parse_samples(
    mut input: &[u8],
    num_samples: u32,
) -> Result<(&[u8], Vec<SflowSample>), SflowError> {
    // Cap capacity to prevent DoS: each sample needs at least 8 bytes (format + length)
    let cap = (num_samples as usize).min(input.len() / 8);
    let mut samples = Vec::with_capacity(cap);

    for _ in 0..num_samples {
        let (rest, data_format) =
            be_u32(input).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
                SflowError::Incomplete {
                    available: input.len(),
                    expected: None,
                    context: ParseContext::SampleDataFormat,
                }
            })?;

        let enterprise = data_format >> 12;
        let format = data_format & 0xFFF;

        let (rest, sample_length) =
            be_u32(rest).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
                SflowError::Incomplete {
                    available: rest.len(),
                    expected: None,
                    context: ParseContext::SampleLength,
                }
            })?;

        let sample_length = sample_length as usize;
        if rest.len() < sample_length {
            return Err(SflowError::Incomplete {
                available: rest.len(),
                expected: Some(sample_length),
                context: ParseContext::SampleData,
            });
        }

        let sample_data = &rest[..sample_length];
        let after_sample = &rest[sample_length..];

        let sample = if enterprise == 0 {
            match format {
                1 => {
                    let (_, fs) = flow_sample::parse_flow_sample(sample_data).map_err(|e| {
                        SflowError::ParseError {
                            offset: 0,
                            context: ParseContext::FlowSample,
                            kind: nom_err_to_kind(&e),
                        }
                    })?;
                    SflowSample::Flow(fs)
                }
                2 => {
                    let (_, cs) =
                        counter_sample::parse_counter_sample(sample_data).map_err(|e| {
                            SflowError::ParseError {
                                offset: 0,
                                context: ParseContext::CounterSample,
                                kind: nom_err_to_kind(&e),
                            }
                        })?;
                    SflowSample::Counter(cs)
                }
                3 => {
                    let (_, efs) = flow_sample::parse_expanded_flow_sample(sample_data)
                        .map_err(|e| SflowError::ParseError {
                            offset: 0,
                            context: ParseContext::ExpandedFlowSample,
                            kind: nom_err_to_kind(&e),
                        })?;
                    SflowSample::ExpandedFlow(efs)
                }
                4 => {
                    let (_, ecs) = counter_sample::parse_expanded_counter_sample(sample_data)
                        .map_err(|e| SflowError::ParseError {
                        offset: 0,
                        context: ParseContext::ExpandedCounterSample,
                        kind: nom_err_to_kind(&e),
                    })?;
                    SflowSample::ExpandedCounter(ecs)
                }
                5 => {
                    let (_, dp) = discarded_packet::parse_discarded_packet(sample_data)
                        .map_err(|e| SflowError::ParseError {
                            offset: 0,
                            context: ParseContext::DiscardedPacket,
                            kind: nom_err_to_kind(&e),
                        })?;
                    SflowSample::DiscardedPacket(dp)
                }
                _ => SflowSample::Unknown {
                    enterprise,
                    format,
                    data: sample_data.to_vec(),
                },
            }
        } else {
            SflowSample::Unknown {
                enterprise,
                format,
                data: sample_data.to_vec(),
            }
        };

        samples.push(sample);
        input = after_sample;
    }

    Ok((input, samples))
}

fn nom_err_to_kind(e: &nom::Err<nom::error::Error<&[u8]>>) -> ParseErrorKind {
    match e {
        nom::Err::Error(e) | nom::Err::Failure(e) => ParseErrorKind::NomError(e.code),
        nom::Err::Incomplete(_) => ParseErrorKind::NomError(nom::error::ErrorKind::Complete),
    }
}
