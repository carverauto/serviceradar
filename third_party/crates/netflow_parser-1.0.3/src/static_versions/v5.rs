//! # Netflow V5
//!
//! References:
//! - <https://www.cisco.com/en/US/technologies/tk648/tk362/technologies_white_paper09186a00800a3db9.html>

use crate::protocol::ProtocolTypes;
use crate::{NetflowError, NetflowPacket, ParsedNetflow};

use nom::error::{Error, ErrorKind};
use serde::Serialize;

use std::net::Ipv4Addr;
pub struct V5Parser;

impl V5Parser {
    pub(crate) fn parse(packet: &[u8]) -> ParsedNetflow<'_> {
        match V5::parse_direct(packet) {
            Ok((remaining, v5)) => ParsedNetflow::Success {
                packet: NetflowPacket::V5(v5),
                remaining,
            },
            Err(e) => ParsedNetflow::Error {
                error: NetflowError::Partial {
                    message: format!("V5 parse error: {}", e),
                },
            },
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Serialize)]
pub struct V5 {
    /// V5 Header
    pub header: Header,
    /// V5 Sets
    pub flowsets: Vec<FlowSet>,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub struct Header {
    /// NetFlow export format version number
    pub version: u16,
    /// Number of flows exported in this packet (1-30)
    pub count: u16,
    /// Current time in milliseconds since the export device booted
    pub sys_up_time: u32,
    /// Current count of seconds since 0000 UTC 1970
    pub unix_secs: u32,
    /// Residual nanoseconds since 0000 UTC 1970
    pub unix_nsecs: u32,
    /// Sequence counter of total flows seen
    pub flow_sequence: u32,
    /// Type of flow-switching engine
    pub engine_type: u8,
    /// Slot number of the flow-switching engine
    pub engine_id: u8,
    /// First two bits hold the sampling mode; remaining 14 bits hold value of sampling interval
    pub sampling_interval: u16,
}

#[derive(Debug, PartialEq, Eq, Clone, Serialize)]
pub struct FlowSet {
    /// Source IP address
    pub src_addr: Ipv4Addr,
    /// Destination IP address
    pub dst_addr: Ipv4Addr,
    /// IP address of next hop router
    pub next_hop: Ipv4Addr,
    /// SNMP index of input interface
    pub input: u16,
    /// SNMP index of output interface
    pub output: u16,
    /// Packets in the flow
    pub d_pkts: u32,
    /// Total number of Layer 3 bytes in the packets of the flow
    pub d_octets: u32,
    /// SysUptime at start of flow
    pub first: u32,
    /// SysUptime at the time the last packet of the flow was received
    pub last: u32,
    /// TCP/UDP source port number or equivalent
    pub src_port: u16,
    /// TCP/UDP destination port number or equivalent
    pub dst_port: u16,
    /// Unused (zero) bytes
    pub pad1: u8,
    /// Cumulative OR of TCP flags
    pub tcp_flags: u8,
    /// IP protocol type (for example, TCP = 6; UDP = 17)
    pub protocol_number: u8,
    pub protocol_type: ProtocolTypes,
    /// IP type of service (ToS)
    pub tos: u8,
    /// Autonomous system number of the source, either origin or peer
    pub src_as: u16,
    /// Autonomous system number of the destination, either origin or peer
    pub dst_as: u16,
    /// Source address prefix mask bits
    pub src_mask: u8,
    /// Destination address prefix mask bits
    pub dst_mask: u8,
    /// Unused (zero) bytes
    pub pad2: u16,
}

/// Header size in bytes (excluding the 2-byte version already consumed).
const HEADER_SIZE: usize = 22;
/// Each V5 flow record is exactly 48 bytes.
const FLOW_SIZE: usize = 48;
/// Maximum number of flows per V5 packet per the Cisco specification.
const MAX_FLOWS: u16 = 30;

impl V5 {
    /// Parse a V5 packet from bytes using direct reads.
    ///
    /// The 2-byte version field has already been consumed by `GenericNetflowHeader`,
    /// so `input` starts at the count field.
    #[inline]
    pub fn parse_direct(input: &[u8]) -> nom::IResult<&[u8], V5> {
        if input.len() < HEADER_SIZE {
            return Err(nom::Err::Error(Error::new(input, ErrorKind::Eof)));
        }

        let count = u16::from_be_bytes([input[0], input[1]]);
        if count == 0 || count > MAX_FLOWS {
            return Err(nom::Err::Error(Error::new(input, ErrorKind::TooLarge)));
        }
        let header = Header {
            version: 5,
            count,
            sys_up_time: u32::from_be_bytes([input[2], input[3], input[4], input[5]]),
            unix_secs: u32::from_be_bytes([input[6], input[7], input[8], input[9]]),
            unix_nsecs: u32::from_be_bytes([input[10], input[11], input[12], input[13]]),
            flow_sequence: u32::from_be_bytes([input[14], input[15], input[16], input[17]]),
            engine_type: input[18],
            engine_id: input[19],
            sampling_interval: u16::from_be_bytes([input[20], input[21]]),
        };

        let total = (count as usize)
            .checked_mul(FLOW_SIZE)
            .and_then(|flows_len| flows_len.checked_add(HEADER_SIZE))
            .ok_or_else(|| nom::Err::Error(Error::new(input, ErrorKind::TooLarge)))?;
        if input.len() < total {
            return Err(nom::Err::Error(Error::new(input, ErrorKind::Eof)));
        }

        let mut flowsets = Vec::with_capacity(count as usize);
        let mut offset = HEADER_SIZE;

        for _ in 0..count {
            let b = &input[offset..offset + FLOW_SIZE];
            let protocol_number = b[38];
            flowsets.push(FlowSet {
                src_addr: Ipv4Addr::new(b[0], b[1], b[2], b[3]),
                dst_addr: Ipv4Addr::new(b[4], b[5], b[6], b[7]),
                next_hop: Ipv4Addr::new(b[8], b[9], b[10], b[11]),
                input: u16::from_be_bytes([b[12], b[13]]),
                output: u16::from_be_bytes([b[14], b[15]]),
                d_pkts: u32::from_be_bytes([b[16], b[17], b[18], b[19]]),
                d_octets: u32::from_be_bytes([b[20], b[21], b[22], b[23]]),
                first: u32::from_be_bytes([b[24], b[25], b[26], b[27]]),
                last: u32::from_be_bytes([b[28], b[29], b[30], b[31]]),
                src_port: u16::from_be_bytes([b[32], b[33]]),
                dst_port: u16::from_be_bytes([b[34], b[35]]),
                pad1: b[36],
                tcp_flags: b[37],
                protocol_number,
                protocol_type: ProtocolTypes::from(protocol_number),
                tos: b[39],
                src_as: u16::from_be_bytes([b[40], b[41]]),
                dst_as: u16::from_be_bytes([b[42], b[43]]),
                src_mask: b[44],
                dst_mask: b[45],
                pad2: u16::from_be_bytes([b[46], b[47]]),
            });
            offset += FLOW_SIZE;
        }

        Ok((&input[total..], V5 { header, flowsets }))
    }

    /// Convert the V5 struct to a `Vec<u8>` of bytes in big-endian order for exporting.
    ///
    /// The output includes the 2-byte version prefix. To re-parse, use the top-level
    /// `NetflowParser::parse_bytes` (not `V5::parse_direct`, which expects the version
    /// to already be consumed).
    pub fn to_be_bytes(&self) -> Vec<u8> {
        // V5 packets hold at most MAX_FLOWS (30) records per the Cisco spec.
        // Serialize up to that limit so count and body stay in sync.
        let to_emit = self.flowsets.len().min(MAX_FLOWS as usize);
        let mut result = Vec::with_capacity(2 + HEADER_SIZE + to_emit * FLOW_SIZE);
        let count = to_emit as u16;
        result.extend_from_slice(&self.header.version.to_be_bytes());
        result.extend_from_slice(&count.to_be_bytes());
        result.extend_from_slice(&self.header.sys_up_time.to_be_bytes());
        result.extend_from_slice(&self.header.unix_secs.to_be_bytes());
        result.extend_from_slice(&self.header.unix_nsecs.to_be_bytes());
        result.extend_from_slice(&self.header.flow_sequence.to_be_bytes());
        result.extend_from_slice(&self.header.engine_type.to_be_bytes());
        result.extend_from_slice(&self.header.engine_id.to_be_bytes());
        result.extend_from_slice(&self.header.sampling_interval.to_be_bytes());

        for set in self.flowsets.iter().take(to_emit) {
            result.extend_from_slice(&set.src_addr.octets());
            result.extend_from_slice(&set.dst_addr.octets());
            result.extend_from_slice(&set.next_hop.octets());
            result.extend_from_slice(&set.input.to_be_bytes());
            result.extend_from_slice(&set.output.to_be_bytes());
            result.extend_from_slice(&set.d_pkts.to_be_bytes());
            result.extend_from_slice(&set.d_octets.to_be_bytes());
            result.extend_from_slice(&set.first.to_be_bytes());
            result.extend_from_slice(&set.last.to_be_bytes());
            result.extend_from_slice(&set.src_port.to_be_bytes());
            result.extend_from_slice(&set.dst_port.to_be_bytes());
            result.extend_from_slice(&set.pad1.to_be_bytes());
            result.extend_from_slice(&set.tcp_flags.to_be_bytes());
            result.extend_from_slice(&set.protocol_number.to_be_bytes());
            result.extend_from_slice(&set.tos.to_be_bytes());
            result.extend_from_slice(&set.src_as.to_be_bytes());
            result.extend_from_slice(&set.dst_as.to_be_bytes());
            result.extend_from_slice(&set.src_mask.to_be_bytes());
            result.extend_from_slice(&set.dst_mask.to_be_bytes());
            result.extend_from_slice(&set.pad2.to_be_bytes());
        }

        result
    }
}
