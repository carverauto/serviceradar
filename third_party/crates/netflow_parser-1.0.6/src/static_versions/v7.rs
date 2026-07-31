//! # Netflow V7
//!
//! References:
//! - <https://www.cisco.com/en/US/technologies/tk648/tk362/technologies_white_paper09186a00800a3db9.html>

use crate::protocol::ProtocolTypes;
use crate::{NetflowError, NetflowPacket, ParsedNetflow};

use nom::error::{Error, ErrorKind};
use serde::Serialize;

use std::net::Ipv4Addr;

pub struct V7Parser;

impl V7Parser {
    pub(crate) fn parse(packet: &[u8]) -> ParsedNetflow<'_> {
        match V7::parse_direct(packet) {
            Ok((remaining, v7)) => ParsedNetflow::Success {
                packet: NetflowPacket::V7(v7),
                remaining,
            },
            Err(e) => ParsedNetflow::Error {
                error: NetflowError::Partial {
                    message: format!("V7 parse error: {}", e),
                },
            },
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Serialize)]
pub struct V7 {
    /// V7 Header
    pub header: Header,
    /// V7 Sets
    pub flowsets: Vec<FlowSet>,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub struct Header {
    /// NetFlow export format version number
    pub version: u16,
    /// Number of flows exported in this flow frame (protocol data unit, or PDU)
    pub count: u16,
    /// Current time in milliseconds since the export device booted
    pub sys_up_time: u32,
    /// Current count of seconds since 0000 UTC 1970
    pub unix_secs: u32,
    /// Residual nanoseconds since 0000 UTC 1970
    pub unix_nsecs: u32,

    /// Sequence counter of total flows seen
    pub flow_sequence: u32,
    /// Unused (zero) bytes
    pub reserved: u32,
}

#[derive(Debug, PartialEq, Eq, Clone, Serialize)]
pub struct FlowSet {
    /// Source IP address; in case of destination-only flows, set to zero.
    pub src_addr: Ipv4Addr,
    /// Destination IP address.
    pub dst_addr: Ipv4Addr,
    /// Next hop router; always set to zero.
    pub next_hop: Ipv4Addr,
    /// SNMP index of input interface; always set to zero.
    pub input: u16,
    /// SNMP index of output interface.
    pub output: u16,
    /// Packets in the flow.
    pub d_pkts: u32,
    /// Total number of Layer 3 bytes in the packets of the flow.
    pub d_octets: u32,
    /// SysUptime, in milliseconds, at start of flow.
    pub first: u32,
    /// SysUptime, in milliseconds, at the time the last packet of the flow was received.
    pub last: u32,
    /// TCP/UDP source port number; set to zero if flow mask is destination-only or source-destination.
    pub src_port: u16,
    /// TCP/UDP destination port number; set to zero if flow mask is destination-only or source-destination.
    pub dst_port: u16,
    /// Flags indicating, among other things, what flow fields are invalid.
    pub flags_fields_valid: u8,
    /// TCP flags; always set to zero.
    pub tcp_flags: u8,
    /// IP protocol type (for example, TCP = 6; UDP = 17); set to zero if flow mask is destination-only or source-destination.
    pub protocol_number: u8,
    pub protocol_type: ProtocolTypes,
    /// IP type of service; switch sets it to the ToS of the first packet of the flow.
    pub tos: u8,
    /// Source autonomous system number, either origin or peer; always set to zero.
    pub src_as: u16,
    /// Destination autonomous system number, either origin or peer; always set to zero.
    pub dst_as: u16,
    /// Source address prefix mask; always set to zero.
    pub src_mask: u8,
    /// Destination address prefix mask; always set to zero.
    pub dst_mask: u8,
    /// Flags indicating, among other things, what flows are invalid.
    pub flags_fields_invalid: u16,
    /// IP address of the router that is bypassed by the Catalyst 5000 series switch. This is the same address the router uses when it sends NetFlow export packets. This IP address is propagated to all switches bypassing the router through the FCP protocol.
    pub router_src: Ipv4Addr,
}

/// Header size in bytes (excluding the 2-byte version already consumed).
const HEADER_SIZE: usize = 22;
/// Each V7 flow record is exactly 52 bytes.
const FLOW_SIZE: usize = 52;
/// Maximum number of flows per V7 packet per the Cisco specification.
const MAX_FLOWS: u16 = 28;

impl V7 {
    /// Parse a V7 packet from bytes using direct reads.
    ///
    /// The 2-byte version field has already been consumed by `GenericNetflowHeader`,
    /// so `input` starts at the count field.
    #[inline]
    pub fn parse_direct(input: &[u8]) -> nom::IResult<&[u8], V7> {
        if input.len() < HEADER_SIZE {
            return Err(nom::Err::Error(Error::new(input, ErrorKind::Eof)));
        }

        let count = u16::from_be_bytes([input[0], input[1]]);
        if count == 0 || count > MAX_FLOWS {
            return Err(nom::Err::Error(Error::new(input, ErrorKind::TooLarge)));
        }
        let header = Header {
            version: 7,
            count,
            sys_up_time: u32::from_be_bytes([input[2], input[3], input[4], input[5]]),
            unix_secs: u32::from_be_bytes([input[6], input[7], input[8], input[9]]),
            unix_nsecs: u32::from_be_bytes([input[10], input[11], input[12], input[13]]),
            flow_sequence: u32::from_be_bytes([input[14], input[15], input[16], input[17]]),
            reserved: u32::from_be_bytes([input[18], input[19], input[20], input[21]]),
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
                flags_fields_valid: b[36],
                tcp_flags: b[37],
                protocol_number,
                protocol_type: ProtocolTypes::from(protocol_number),
                tos: b[39],
                src_as: u16::from_be_bytes([b[40], b[41]]),
                dst_as: u16::from_be_bytes([b[42], b[43]]),
                src_mask: b[44],
                dst_mask: b[45],
                flags_fields_invalid: u16::from_be_bytes([b[46], b[47]]),
                router_src: Ipv4Addr::new(b[48], b[49], b[50], b[51]),
            });
            offset += FLOW_SIZE;
        }

        Ok((&input[total..], V7 { header, flowsets }))
    }

    /// Convert the V7 struct to a `Vec<u8>` of bytes in big-endian order for exporting.
    ///
    /// The output includes the 2-byte version prefix. To re-parse, use the top-level
    /// `NetflowParser::parse_bytes` (not `V7::parse_direct`, which expects the version
    /// to already be consumed).
    pub fn to_be_bytes(&self) -> Vec<u8> {
        // V7 packets hold at most MAX_FLOWS (28) records per the Cisco spec.
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
        result.extend_from_slice(&self.header.reserved.to_be_bytes());

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
            result.extend_from_slice(&set.flags_fields_valid.to_be_bytes());
            result.extend_from_slice(&set.tcp_flags.to_be_bytes());
            result.extend_from_slice(&set.protocol_number.to_be_bytes());
            result.extend_from_slice(&set.tos.to_be_bytes());
            result.extend_from_slice(&set.src_as.to_be_bytes());
            result.extend_from_slice(&set.dst_as.to_be_bytes());
            result.extend_from_slice(&set.src_mask.to_be_bytes());
            result.extend_from_slice(&set.dst_mask.to_be_bytes());
            result.extend_from_slice(&set.flags_fields_invalid.to_be_bytes());
            result.extend_from_slice(&set.router_src.octets());
        }

        result
    }
}
