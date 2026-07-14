use super::mrt_header::parse_common_header_with_bytes;
use crate::bmp::messages::{BmpMessage, BmpMessageBody};
use crate::error::ParserError;
use crate::models::*;
use crate::parser::{
    parse_bgp4mp, parse_table_dump_message, parse_table_dump_v2_message, ParserErrorWithBytes,
};
use crate::utils::convert_timestamp;
use bytes::{BufMut, Bytes, BytesMut};
use log::warn;
use std::convert::TryFrom;
use std::fs::File;
use std::io::{Read, Write};
use std::net::IpAddr;
use std::path::Path;
use std::str::FromStr;

/// Raw MRT record containing the common header and unparsed message bytes.
/// This allows for lazy parsing of the MRT message body, and provides
/// utilities for debugging and exporting problematic records.
#[derive(Debug, Clone)]
pub struct RawMrtRecord {
    pub common_header: CommonHeader,
    /// The raw bytes of the MRT common header (as read from the wire).
    pub header_bytes: Bytes,
    /// The raw bytes of the MRT message body (excluding the common header).
    pub message_bytes: Bytes,
}

impl RawMrtRecord {
    /// Parse the raw MRT record into a fully parsed MrtRecord.
    /// This consumes the RawMrtRecord and returns a MrtRecord.
    pub fn parse(self) -> Result<MrtRecord, ParserError> {
        let message = parse_mrt_body(
            self.common_header.entry_type as u16,
            self.common_header.entry_subtype,
            self.message_bytes,
        )?;

        Ok(MrtRecord {
            common_header: self.common_header,
            message,
        })
    }

    /// Returns the complete MRT record as raw bytes (header + message body).
    ///
    /// This returns the exact bytes as they were read from the wire,
    /// without any re-encoding. This is useful for debugging problematic
    /// MRT records by exporting them as-is to a file for further analysis.
    ///
    /// # Example
    /// ```ignore
    /// let raw_record = parser.into_raw_record_iter().next().unwrap();
    /// let bytes = raw_record.raw_bytes();
    /// std::fs::write("record.mrt", &bytes).unwrap();
    /// ```
    pub fn raw_bytes(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(self.header_bytes.len() + self.message_bytes.len());
        bytes.put_slice(&self.header_bytes);
        bytes.put_slice(&self.message_bytes);
        bytes.freeze()
    }

    /// Writes the raw MRT record (header + message body) to a file.
    ///
    /// This is useful for extracting problematic MRT records for debugging
    /// or further analysis with other tools.
    ///
    /// # Arguments
    /// * `path` - The path to write the raw bytes to.
    ///
    /// # Example
    /// ```ignore
    /// let raw_record = parser.into_raw_record_iter().next().unwrap();
    /// raw_record.write_raw_bytes("problematic_record.mrt").unwrap();
    /// ```
    pub fn write_raw_bytes<P: AsRef<Path>>(&self, path: P) -> std::io::Result<()> {
        let mut file = File::create(path)?;
        file.write_all(&self.header_bytes)?;
        file.write_all(&self.message_bytes)?;
        Ok(())
    }

    /// Appends the raw MRT record (header + message body) to a file.
    ///
    /// This is useful for collecting multiple problematic records into a single file.
    ///
    /// # Arguments
    /// * `path` - The path to append the raw bytes to.
    ///
    /// # Example
    /// ```ignore
    /// for raw_record in parser.into_raw_record_iter() {
    ///     if is_problematic(&raw_record) {
    ///         raw_record.append_raw_bytes("problematic_records.mrt").unwrap();
    ///     }
    /// }
    /// ```
    pub fn append_raw_bytes<P: AsRef<Path>>(&self, path: P) -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        file.write_all(&self.header_bytes)?;
        file.write_all(&self.message_bytes)?;
        Ok(())
    }

    /// Returns the total length of the complete MRT record in bytes (header + body).
    pub fn total_bytes_len(&self) -> usize {
        self.header_bytes.len() + self.message_bytes.len()
    }
}

pub fn chunk_mrt_record(input: &mut impl Read) -> Result<RawMrtRecord, ParserErrorWithBytes> {
    // parse common header and capture raw bytes
    let parsed_header = match parse_common_header_with_bytes(input) {
        Ok(v) => v,
        Err(e) => {
            if let ParserError::EofError(e) = &e {
                if e.kind() == std::io::ErrorKind::UnexpectedEof {
                    return Err(ParserErrorWithBytes::from(ParserError::EofExpected));
                }
            }
            return Err(ParserErrorWithBytes {
                error: e,
                bytes: None,
            });
        }
    };

    let common_header = parsed_header.header;
    let header_bytes = parsed_header.raw_bytes;

    // Protect against unreasonable allocations from corrupt headers
    const MAX_MRT_MESSAGE_LEN: u32 = 16 * 1024 * 1024; // 16 MiB upper bound
    if common_header.length > MAX_MRT_MESSAGE_LEN {
        return Err(ParserErrorWithBytes::from(ParserError::Unsupported(
            format!("MRT message too large: {} bytes", common_header.length),
        )));
    }

    // read the whole message bytes to buffer
    let mut buffer = BytesMut::zeroed(common_header.length as usize);
    match input
        .take(common_header.length as u64)
        .read_exact(&mut buffer)
    {
        Ok(_) => {}
        Err(e) => {
            return Err(ParserErrorWithBytes {
                error: ParserError::IoError(e),
                bytes: None,
            })
        }
    }

    Ok(RawMrtRecord {
        common_header,
        header_bytes,
        message_bytes: buffer.freeze(),
    })
}

pub fn parse_mrt_record(input: &mut impl Read) -> Result<MrtRecord, ParserErrorWithBytes> {
    let raw_record = chunk_mrt_record(input)?;
    match raw_record.parse() {
        Ok(record) => Ok(record),
        Err(e) => Err(ParserErrorWithBytes {
            error: e,
            bytes: None,
        }),
    }
}

/// Parse MRT message body with given entry type and subtype.
///
/// The entry type and subtype are parsed from the common header. The message body is parsed
/// according to the entry type and subtype. The message body is the remaining bytes after the
/// common header. The length of the message body is also parsed from the common header.
pub fn parse_mrt_body(
    entry_type: u16,
    entry_subtype: u16,
    data: Bytes,
) -> Result<MrtMessage, ParserError> {
    let etype = EntryType::try_from(entry_type)?;

    let message: MrtMessage = match &etype {
        EntryType::TABLE_DUMP => {
            let msg = parse_table_dump_message(entry_subtype, data);
            match msg {
                Ok(msg) => MrtMessage::TableDumpMessage(msg),
                Err(e) => {
                    return Err(e);
                }
            }
        }
        EntryType::TABLE_DUMP_V2 => {
            let msg = parse_table_dump_v2_message(entry_subtype, data);
            match msg {
                Ok(msg) => MrtMessage::TableDumpV2Message(msg),
                Err(e) => {
                    return Err(e);
                }
            }
        }
        EntryType::BGP4MP | EntryType::BGP4MP_ET => {
            let msg = parse_bgp4mp(entry_subtype, data);
            match msg {
                Ok(msg) => MrtMessage::Bgp4Mp(msg),
                Err(e) => {
                    return Err(e);
                }
            }
        }
        v => {
            // deprecated
            return Err(ParserError::Unsupported(format!(
                "unsupported MRT type: {v:?}"
            )));
        }
    };
    Ok(message)
}

impl MrtRecord {
    pub fn encode(&self) -> Bytes {
        let message_bytes = self.message.encode(self.common_header.entry_subtype);
        let mut new_header = self.common_header;
        if message_bytes.len() < new_header.length as usize {
            warn!("message length is less than the length in the header");
            new_header.length = message_bytes.len() as u32;
        }
        let header_bytes = new_header.encode();

        // // debug begins
        // let parsed_body = parse_mrt_body(
        //     self.common_header.entry_type as u16,
        //     self.common_header.entry_subtype,
        //     message_bytes.clone(),
        // )
        // .unwrap();
        // assert!(self.message == parsed_body);
        // // debug ends

        let mut bytes = BytesMut::with_capacity(header_bytes.len() + message_bytes.len());
        bytes.put_slice(&header_bytes);
        bytes.put_slice(&message_bytes);
        bytes.freeze()
    }
}

impl TryFrom<&BmpMessage> for MrtRecord {
    type Error = String;

    fn try_from(bmp_message: &BmpMessage) -> Result<Self, Self::Error> {
        let bgp_message = match &bmp_message.message_body {
            BmpMessageBody::RouteMonitoring(m) => &m.bgp_message,
            _ => return Err("unsupported bmp message type".to_string()),
        };
        let bmp_header = match &bmp_message.per_peer_header {
            Some(h) => h,
            None => return Err("missing per peer header".to_string()),
        };

        let local_ip = match bmp_header.peer_ip {
            IpAddr::V4(_) => IpAddr::from_str("0.0.0.0").unwrap(),
            IpAddr::V6(_) => IpAddr::from_str("::").unwrap(),
        };
        let local_asn = match bmp_header.peer_asn.is_four_byte() {
            true => Asn::new_32bit(0),
            false => Asn::new_16bit(0),
        };

        let bgp4mp_message = Bgp4MpMessage {
            msg_type: Bgp4MpType::MessageAs4, // TODO: check Message or MessageAs4
            peer_asn: bmp_header.peer_asn,
            local_asn,
            interface_index: 0,
            peer_ip: bmp_header.peer_ip,
            local_ip,
            bgp_message: bgp_message.clone(),
        };

        let mrt_message = MrtMessage::Bgp4Mp(Bgp4MpEnum::Message(bgp4mp_message));

        let (seconds, microseconds) = convert_timestamp(bmp_header.timestamp);

        let subtype = Bgp4MpType::MessageAs4 as u16;
        let mrt_header = CommonHeader {
            timestamp: seconds,
            microsecond_timestamp: Some(microseconds),
            entry_type: EntryType::BGP4MP_ET,
            entry_subtype: Bgp4MpType::MessageAs4 as u16,
            length: mrt_message.encode(subtype).len() as u32,
        };

        Ok(MrtRecord {
            common_header: mrt_header,
            message: mrt_message,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bmp::messages::headers::{BmpPeerType, PeerFlags, PerPeerFlags};
    use crate::bmp::messages::{BmpCommonHeader, BmpMsgType, BmpPerPeerHeader, RouteMonitoring};
    use std::net::Ipv4Addr;
    use tempfile::tempdir;

    #[test]
    fn test_raw_mrt_record_raw_bytes() {
        let header = CommonHeader {
            timestamp: 1609459200,
            microsecond_timestamp: None,
            entry_type: EntryType::BGP4MP,
            entry_subtype: 4,
            length: 10,
        };
        let header_bytes = Bytes::from_static(&[
            0x5f, 0xee, 0x6a, 0x80, // timestamp
            0x00, 0x10, // entry type
            0x00, 0x04, // entry subtype
            0x00, 0x00, 0x00, 0x0a, // length
        ]);
        let message_bytes = Bytes::from_static(&[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

        let raw_record = RawMrtRecord {
            common_header: header,
            header_bytes,
            message_bytes,
        };

        let mrt_bytes = raw_record.raw_bytes();
        // Header is 12 bytes + 10 bytes body = 22 bytes total
        assert_eq!(mrt_bytes.len(), 22);
        assert_eq!(raw_record.total_bytes_len(), 22);
    }

    #[test]
    fn test_raw_mrt_record_raw_bytes_with_et() {
        let header = CommonHeader {
            timestamp: 1609459200,
            microsecond_timestamp: Some(500000),
            entry_type: EntryType::BGP4MP_ET,
            entry_subtype: 4,
            length: 10,
        };
        let header_bytes = Bytes::from_static(&[
            0x5f, 0xee, 0x6a, 0x80, // timestamp
            0x00, 0x11, // entry type (BGP4MP_ET = 17)
            0x00, 0x04, // entry subtype
            0x00, 0x00, 0x00, 0x0e, // length (10 + 4 for microseconds)
            0x00, 0x07, 0xa1, 0x20, // microsecond timestamp (500000)
        ]);
        let message_bytes = Bytes::from_static(&[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

        let raw_record = RawMrtRecord {
            common_header: header,
            header_bytes,
            message_bytes,
        };

        let mrt_bytes = raw_record.raw_bytes();
        // ET Header is 16 bytes + 10 bytes body = 26 bytes total
        assert_eq!(mrt_bytes.len(), 26);
        assert_eq!(raw_record.total_bytes_len(), 26);
    }

    #[test]
    fn test_raw_mrt_record_write_to_file() {
        let dir = tempdir().unwrap();
        let file_path = dir.path().join("test_record.mrt");

        let header = CommonHeader {
            timestamp: 1609459200,
            microsecond_timestamp: None,
            entry_type: EntryType::BGP4MP,
            entry_subtype: 4,
            length: 5,
        };
        let header_bytes = Bytes::from_static(&[
            0x5f, 0xee, 0x6a, 0x80, // timestamp
            0x00, 0x10, // entry type
            0x00, 0x04, // entry subtype
            0x00, 0x00, 0x00, 0x05, // length
        ]);
        let message_bytes = Bytes::from_static(&[1, 2, 3, 4, 5]);

        let raw_record = RawMrtRecord {
            common_header: header,
            header_bytes,
            message_bytes,
        };

        raw_record.write_raw_bytes(&file_path).unwrap();

        let written_bytes = std::fs::read(&file_path).unwrap();
        assert_eq!(written_bytes.len(), 17); // 12 header + 5 body
    }

    #[test]
    fn test_raw_mrt_record_append_to_file() {
        let dir = tempdir().unwrap();
        let file_path = dir.path().join("test_records.mrt");

        let header = CommonHeader {
            timestamp: 1609459200,
            microsecond_timestamp: None,
            entry_type: EntryType::BGP4MP,
            entry_subtype: 4,
            length: 3,
        };
        let header_bytes = Bytes::from_static(&[
            0x5f, 0xee, 0x6a, 0x80, // timestamp
            0x00, 0x10, // entry type
            0x00, 0x04, // entry subtype
            0x00, 0x00, 0x00, 0x03, // length
        ]);
        let message_bytes = Bytes::from_static(&[1, 2, 3]);

        let raw_record = RawMrtRecord {
            common_header: header,
            header_bytes,
            message_bytes,
        };

        raw_record.append_raw_bytes(&file_path).unwrap();
        raw_record.append_raw_bytes(&file_path).unwrap();

        let written_bytes = std::fs::read(&file_path).unwrap();
        assert_eq!(written_bytes.len(), 30); // (12 header + 3 body) * 2
    }

    #[test]
    fn test_try_from_bmp_message() {
        let bmp_message = BmpMessage {
            common_header: BmpCommonHeader {
                version: 0,
                msg_len: 0,
                msg_type: BmpMsgType::RouteMonitoring,
            },
            per_peer_header: Some(BmpPerPeerHeader {
                peer_asn: Asn::new_32bit(0),
                peer_ip: IpAddr::from_str("10.0.0.1").unwrap(),
                peer_bgp_id: Ipv4Addr::from_str("10.0.0.2").unwrap(),
                timestamp: 0.0,
                peer_type: BmpPeerType::Global,
                peer_flags: PerPeerFlags::PeerFlags(PeerFlags::empty()),
                peer_distinguisher: 0,
            }),
            message_body: BmpMessageBody::RouteMonitoring(RouteMonitoring {
                bgp_message: BgpMessage::KeepAlive,
            }),
        };

        let mrt_record = MrtRecord::try_from(&bmp_message).unwrap();
        assert_eq!(mrt_record.common_header.entry_type, EntryType::BGP4MP_ET);
    }

    #[test]
    fn test_parse_mrt_body() {
        let mut data = BytesMut::new();
        data.put_u16(0);
        data.put_u16(0);
        data.put_u32(0);
        data.put_u16(0);

        let result = parse_mrt_body(0, 0, data.freeze());
        assert!(result.is_err());
    }
}
