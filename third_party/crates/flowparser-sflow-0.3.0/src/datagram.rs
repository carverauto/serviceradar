use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};
use std::net::{Ipv4Addr, Ipv6Addr};

use crate::error::{ParseContext, ParseErrorKind, SflowError};
use crate::samples::{SflowSample, parse_samples};

/// An sFlow address, either IPv4 or IPv6.
///
/// Used for both agent addresses in the datagram header and
/// next-hop addresses in extended router/gateway records.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AddressType {
    /// IPv4 address.
    IPv4(Ipv4Addr),
    /// IPv6 address.
    IPv6(Ipv6Addr),
}

/// A parsed sFlow v5 datagram containing header fields and samples.
///
/// Each datagram is sent by an sFlow agent and contains a header
/// identifying the agent, plus zero or more flow or counter samples.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SflowDatagram {
    /// sFlow version (always 5).
    pub version: u32,
    /// IP address of the sFlow agent.
    pub agent_address: AddressType,
    /// Sub-agent identifier (disambiguates multiple data sources).
    pub sub_agent_id: u32,
    /// Sequence number incremented per datagram from this agent.
    pub sequence_number: u32,
    /// Agent uptime in milliseconds since boot.
    pub uptime: u32,
    /// Flow and counter samples contained in this datagram.
    pub samples: Vec<SflowSample>,
}

pub(crate) fn parse_address(input: &[u8]) -> IResult<&[u8], AddressType> {
    let (input, addr_type) = be_u32(input)?;
    match addr_type {
        1 => {
            let (input, a) = be_u32(input)?;
            Ok((input, AddressType::IPv4(Ipv4Addr::from(a))))
        }
        2 => {
            let (input, hi) = be_u64(input)?;
            let (input, lo) = be_u64(input)?;
            let mut octets = [0u8; 16];
            octets[..8].copy_from_slice(&hi.to_be_bytes());
            octets[8..].copy_from_slice(&lo.to_be_bytes());
            Ok((input, AddressType::IPv6(Ipv6Addr::from(octets))))
        }
        _ => Err(nom::Err::Error(nom::error::Error::new(
            input,
            nom::error::ErrorKind::Switch,
        ))),
    }
}

pub(crate) fn parse_datagram(
    input: &[u8],
    max_samples: Option<u32>,
) -> Result<(&[u8], SflowDatagram), SflowError> {
    let original = input;

    let (input, version) = be_u32(input).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
        SflowError::Incomplete {
            available: original.len(),
            expected: None,
            context: ParseContext::DatagramHeaderVersion,
        }
    })?;

    if version != 5 {
        return Err(SflowError::UnsupportedVersion { version });
    }

    let (input, agent_address) =
        parse_address(input).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
            SflowError::ParseError {
                offset: original.len() - input.len(),
                context: ParseContext::AgentAddress,
                kind: ParseErrorKind::InvalidAddressType,
            }
        })?;

    let (input, sub_agent_id) =
        be_u32(input).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
            SflowError::Incomplete {
                available: input.len(),
                expected: None,
                context: ParseContext::SubAgentId,
            }
        })?;

    let (input, sequence_number) =
        be_u32(input).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
            SflowError::Incomplete {
                available: input.len(),
                expected: None,
                context: ParseContext::SequenceNumber,
            }
        })?;

    let (input, uptime) = be_u32(input).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
        SflowError::Incomplete {
            available: input.len(),
            expected: None,
            context: ParseContext::Uptime,
        }
    })?;

    let (input, num_samples) =
        be_u32(input).map_err(|_: nom::Err<nom::error::Error<&[u8]>>| {
            SflowError::Incomplete {
                available: input.len(),
                expected: None,
                context: ParseContext::NumSamples,
            }
        })?;

    // Enforce max_samples limit before parsing to prevent DoS
    if let Some(max) = max_samples
        && num_samples > max
    {
        return Err(SflowError::TooManySamples {
            count: num_samples,
            max,
        });
    }

    let (input, samples) = parse_samples(input, num_samples)?;

    Ok((
        input,
        SflowDatagram {
            version,
            agent_address,
            sub_agent_id,
            sequence_number,
            uptime,
            samples,
        },
    ))
}
