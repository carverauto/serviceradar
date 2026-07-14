use crate::bgp::attributes::parse_attributes;
use crate::models::{
    Afi, AsnLength, NetworkPrefix, RibAfiEntries, RibEntry, Safi, TableDumpV2Type,
};
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::{Buf, BufMut, Bytes, BytesMut};
use log::warn;

fn extract_afi_safi_from_rib_type(rib_type: &TableDumpV2Type) -> Result<(Afi, Safi), ParserError> {
    let afi: Afi;
    let safi: Safi;
    match rib_type {
        TableDumpV2Type::RibIpv4Unicast | TableDumpV2Type::RibIpv4UnicastAddPath => {
            afi = Afi::Ipv4;
            safi = Safi::Unicast
        }
        TableDumpV2Type::RibIpv4Multicast | TableDumpV2Type::RibIpv4MulticastAddPath => {
            afi = Afi::Ipv4;
            safi = Safi::Multicast
        }
        TableDumpV2Type::RibIpv6Unicast | TableDumpV2Type::RibIpv6UnicastAddPath => {
            afi = Afi::Ipv6;
            safi = Safi::Unicast
        }
        TableDumpV2Type::RibIpv6Multicast | TableDumpV2Type::RibIpv6MulticastAddPath => {
            afi = Afi::Ipv6;
            safi = Safi::Multicast
        }
        _ => {
            return Err(ParserError::ParseError(format!(
                "wrong RIB type for parsing: {rib_type:?}"
            )))
        }
    };

    Ok((afi, safi))
}

/// RIB AFI-specific entries
///
/// https://tools.ietf.org/html/rfc6396#section-4.3
pub fn parse_rib_afi_entries(
    data: &mut Bytes,
    rib_type: TableDumpV2Type,
) -> Result<RibAfiEntries, ParserError> {
    let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type)?;

    let is_add_path = matches!(
        rib_type,
        TableDumpV2Type::RibIpv4UnicastAddPath
            | TableDumpV2Type::RibIpv4MulticastAddPath
            | TableDumpV2Type::RibIpv6UnicastAddPath
            | TableDumpV2Type::RibIpv6MulticastAddPath
    );

    let sequence_number = data.read_u32()?;

    // NOTE: here we parse the prefix as only length and prefix, the path identifier for add_path
    //       entry is not handled here. We follow RFC6396 here https://www.rfc-editor.org/rfc/rfc6396.html#section-4.3.2
    let prefix = data.read_nlri_prefix(&afi, false)?;

    let entry_count = data.read_u16()?;
    // Pre-allocate cautiously to avoid overflow/OOM with malformed inputs
    let min_entry_size =
        2 /*peer_index*/ + 4 /*time*/ + 2 /*attr_len*/ + if is_add_path { 4 } else { 0 };
    let max_possible = data.remaining() / min_entry_size;
    let reserve = (entry_count as usize).min(max_possible).saturating_mul(2);
    let mut rib_entries = Vec::with_capacity(reserve);

    // get the u8 slice of the rest of the data
    // let attr_data_slice = &input.into_inner()[(input.position() as usize)..];

    for _i in 0..entry_count {
        let entry = match parse_rib_entry(data, is_add_path, &afi, &safi, prefix) {
            Ok(entry) => entry,
            Err(e) => {
                warn!("early break due to error {}", e);
                break;
            }
        };
        rib_entries.push(entry);
    }

    Ok(RibAfiEntries {
        rib_type,
        sequence_number,
        prefix,
        rib_entries,
    })
}

/// RIB entry: one prefix per entry
///
///
/// https://datatracker.ietf.org/doc/html/rfc6396#section-4.3.4
/// ```text
///         0                   1                   2                   3
///         0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
///        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///        |         Peer Index            |
///        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///        |                         Originated Time                       |
///        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///        |      Attribute Length         |
///        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///        |                    BGP Attributes... (variable)
///        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///
///                           Figure 10: RIB Entries
/// ```
pub fn parse_rib_entry(
    input: &mut Bytes,
    is_add_path: bool,
    afi: &Afi,
    safi: &Safi,
    prefix: NetworkPrefix,
) -> Result<RibEntry, ParserError> {
    if input.remaining() < 8 {
        // total length - current position less than 16 --
        // meaning less than 16 bytes available to read
        return Err(ParserError::TruncatedMsg("truncated msg".to_string()));
    }

    let peer_index = input.read_u16()?;
    let originated_time = input.read_u32()?;

    let path_id = match is_add_path {
        true => Some(input.read_u32()?),
        false => None,
    };

    let attribute_length = input.read_u16()? as usize;

    input.has_n_remaining(attribute_length)?;
    let attr_data_slice = input.split_to(attribute_length);
    let attributes = parse_attributes(
        attr_data_slice,
        &AsnLength::Bits32,
        is_add_path,
        Some(*afi),
        Some(*safi),
        Some(&[prefix]),
    )?;

    Ok(RibEntry {
        peer_index,
        originated_time,
        path_id,
        attributes,
    })
}

impl RibAfiEntries {
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::new();

        bytes.put_u32(self.sequence_number);
        bytes.extend(self.prefix.encode());

        let entry_count = self.rib_entries.len();
        bytes.put_u16(entry_count as u16);

        for entry in &self.rib_entries {
            bytes.extend(entry.encode());
        }

        bytes.freeze()
    }
}

impl RibEntry {
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::new();
        bytes.put_u16(self.peer_index);
        bytes.put_u32(self.originated_time);
        let attr_bytes = self.attributes.encode(AsnLength::Bits32);
        bytes.put_u16(attr_bytes.len() as u16);
        bytes.extend(attr_bytes);
        bytes.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_afi_safi_from_rib_type() {
        let rib_type = TableDumpV2Type::RibIpv4Unicast;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv4);
        assert_eq!(safi, Safi::Unicast);

        let rib_type = TableDumpV2Type::RibIpv4Multicast;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv4);
        assert_eq!(safi, Safi::Multicast);

        let rib_type = TableDumpV2Type::RibIpv6Unicast;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv6);
        assert_eq!(safi, Safi::Unicast);

        let rib_type = TableDumpV2Type::RibIpv6Multicast;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv6);
        assert_eq!(safi, Safi::Multicast);

        let rib_type = TableDumpV2Type::RibIpv4UnicastAddPath;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv4);
        assert_eq!(safi, Safi::Unicast);

        let rib_type = TableDumpV2Type::RibIpv4MulticastAddPath;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv4);
        assert_eq!(safi, Safi::Multicast);

        let rib_type = TableDumpV2Type::RibIpv6UnicastAddPath;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv6);
        assert_eq!(safi, Safi::Unicast);

        let rib_type = TableDumpV2Type::RibIpv6MulticastAddPath;
        let (afi, safi) = extract_afi_safi_from_rib_type(&rib_type).unwrap();
        assert_eq!(afi, Afi::Ipv6);
        assert_eq!(safi, Safi::Multicast);

        let rib_type = TableDumpV2Type::RibGeneric;
        let res = extract_afi_safi_from_rib_type(&rib_type);
        assert!(res.is_err());
    }

    #[test]
    fn test_rib_entry_encode() {
        use crate::models::{AttributeValue, Attributes, Origin};

        let mut attributes = Attributes::default();
        attributes.add_attr(AttributeValue::Origin(Origin::IGP).into());

        let rib_entry = RibEntry {
            peer_index: 1,
            originated_time: 12345,
            path_id: Some(42),
            attributes,
        };

        // This should exercise the self.attributes.encode(AsnLength::Bits32) line
        let _encoded = rib_entry.encode();
    }
}
