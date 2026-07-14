use std::net::IpAddr;
use std::str::FromStr;

use crate::models::{
    Asn, Bgp4MpEnum, Bgp4MpMessage, Bgp4MpType, BgpMessage, BgpUpdateMessage, CommonHeader,
    EntryType, MrtMessage,
};
use crate::utils::convert_timestamp;
use crate::BgpElem;
use bytes::{Bytes, BytesMut};

#[derive(Debug, Default)]
pub struct MrtUpdatesEncoder {
    cached_elems: Vec<BgpElem>,
}

impl MrtUpdatesEncoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        self.cached_elems.clear();
    }

    pub fn process_elem(&mut self, elem: &BgpElem) {
        self.cached_elems.push(elem.clone());
    }

    pub fn export_bytes(&mut self) -> Bytes {
        let mut bytes = BytesMut::new();

        for elem in &self.cached_elems {
            let msg = BgpUpdateMessage::from(elem);
            let peer_asn = Asn::new_32bit(elem.peer_asn.to_u32());
            let local_asn = Asn::new_32bit(0);
            let local_ip = match elem.peer_ip {
                IpAddr::V4(_) => IpAddr::from_str("0.0.0.0").unwrap(),
                IpAddr::V6(_) => IpAddr::from_str("::").unwrap(),
            };
            let msg_type = Bgp4MpType::MessageAs4;

            let bgp4mp_msg = Bgp4MpMessage {
                msg_type,
                peer_asn,
                local_asn,
                interface_index: 0,
                peer_ip: elem.peer_ip,
                local_ip,
                bgp_message: BgpMessage::Update(msg),
            };

            let mrt_message = MrtMessage::Bgp4Mp(Bgp4MpEnum::Message(bgp4mp_msg));

            let (seconds, microseconds) = convert_timestamp(elem.timestamp);

            let subtype = Bgp4MpType::MessageAs4 as u16;
            let data_bytes = mrt_message.encode(subtype);
            let header_bytes = CommonHeader {
                timestamp: seconds,
                microsecond_timestamp: Some(microseconds),
                entry_type: EntryType::BGP4MP_ET,
                entry_subtype: subtype,
                length: data_bytes.len() as u32,
            }
            .encode();
            bytes.extend(header_bytes);
            bytes.extend(data_bytes);
        }

        self.reset();

        bytes.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::NetworkPrefix;
    use crate::parse_mrt_record;
    use bytes::Buf;
    use std::io::Cursor;

    #[test]
    fn test_encoding_updates() {
        let mut encoder = MrtUpdatesEncoder::new();
        let mut elem = BgpElem {
            peer_ip: IpAddr::V4("10.0.0.1".parse().unwrap()),
            peer_asn: Asn::from(65000),
            ..Default::default()
        };
        elem.prefix.prefix = "10.250.0.0/24".parse().unwrap();
        encoder.process_elem(&elem);
        elem.prefix.prefix = "10.251.0.0/24".parse().unwrap();
        encoder.process_elem(&elem);
        let bytes = encoder.export_bytes();

        let mut cursor = Cursor::new(bytes.clone());
        while cursor.has_remaining() {
            let _parsed = parse_mrt_record(&mut cursor).unwrap();
        }
    }

    #[test]
    fn test_encoding_updates_v6() {
        let mut encoder = MrtUpdatesEncoder::new();

        let mut elem = BgpElem {
            peer_ip: IpAddr::V6("::1".parse().unwrap()),
            peer_asn: Asn::from(65000),
            ..Default::default()
        };
        // ipv6 prefix
        elem.prefix = NetworkPrefix::from_str("2001:db8::/32").unwrap();
        encoder.process_elem(&elem);
        let bytes = encoder.export_bytes();
        let mut cursor = Cursor::new(bytes.clone());
        while cursor.has_remaining() {
            let _parsed = parse_mrt_record(&mut cursor).unwrap();
        }
    }
}
