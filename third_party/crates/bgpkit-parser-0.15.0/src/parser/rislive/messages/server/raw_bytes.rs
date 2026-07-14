use crate::models::*;
use crate::parser::bgp::parse_bgp_message;
use crate::parser::rislive::error::ParserRisliveError;
use crate::Elementor;
use bytes::Bytes;
use serde_json::Value;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

// FIXME: This function will panic on any unexpected values
pub fn parse_raw_bytes(msg_str: &str) -> Result<Vec<BgpElem>, ParserRisliveError> {
    let msg: Value = serde_json::from_str(msg_str)?;
    let msg_type = match msg.get("type") {
        None => return Err(ParserRisliveError::IrregularRisLiveFormat),
        Some(t) => t.as_str().unwrap(),
    };

    match msg_type {
        "ris_message" => {}
        "ris_error" | "ris_rrc_list" | "ris_subscribe_ok" | "pong" => {
            return Err(ParserRisliveError::UnsupportedMessage)
        }
        _ => return Err(ParserRisliveError::IrregularRisLiveFormat),
    }

    let data = msg.get("data").unwrap().as_object().unwrap();

    let mut bytes = Bytes::from(hex::decode(data.get("raw").unwrap().as_str().unwrap()).unwrap());

    let timestamp = data.get("timestamp").unwrap().as_f64().unwrap();
    let peer_str = data.get("peer").unwrap().as_str().unwrap().to_owned();

    let peer_ip = peer_str.parse::<IpAddr>().unwrap();
    let local_ip = match peer_ip.is_ipv4() {
        true => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        false => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
    };

    let peer_asn_str = data.get("peer_asn").unwrap().as_str().unwrap().to_owned();

    let peer_asn = peer_asn_str.parse::<Asn>().unwrap();

    let bgp_msg = match parse_bgp_message(&mut bytes, false, &AsnLength::Bits32) {
        Ok(m) => m,
        Err(_) => match parse_bgp_message(&mut bytes, false, &AsnLength::Bits16) {
            Ok(m) => m,
            Err(_) => return Err(ParserRisliveError::IncorrectRawBytes),
        },
    };

    let t_sec = timestamp as u32;
    let t_msec = get_micro_seconds(timestamp);

    let header = CommonHeader {
        timestamp: t_sec,
        microsecond_timestamp: Some(t_msec),
        entry_type: EntryType::BGP4MP,
        entry_subtype: Bgp4MpType::MessageAs4 as u16,
        length: 0,
    };

    let record = MrtRecord {
        common_header: header,
        message: MrtMessage::Bgp4Mp(Bgp4MpEnum::Message(Bgp4MpMessage {
            msg_type: Bgp4MpType::MessageAs4,
            peer_asn,
            local_asn: Asn::RESERVED,
            interface_index: 0,
            peer_ip,
            local_ip,
            bgp_message: bgp_msg,
        })),
    };
    Ok(Elementor::new().record_to_elems(record))
}

fn get_micro_seconds(sec: f64) -> u32 {
    format!("{sec:.6}").split('.').collect::<Vec<&str>>()[1]
        .to_owned()
        .parse::<u32>()
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ris_live_message() {
        let message = r#"
        {
  "type": "ris_message",
  "data": {
    "timestamp": 1636245154.8,
    "peer": "2001:7f8:b:100:1d1:a520:1333:74",
    "peer_asn": "201333",
    "id": "10-183678-175313836",
    "host": "rrc10",
    "type": "UPDATE",
    "path": [
      201333,
      6762,
      174,
      20473
    ],
    "community": [
      [
        6762,
        30
      ],
      [
        6762,
        14400
      ]
    ],
    "origin": "igp",
    "announcements": [
      {
        "next_hop": "2001:7f8:b:100:1d1:a520:1333:74",
        "prefixes": [
          "2a0e:97c7::/48",
          "2a0e:97c6:fe::/48",
          "2a10:cc42:17b7::/48",
          "2a10:cc42:1feb::/48"
        ]
      },
      {
        "next_hop": "fe80::217:a3ff:fefe:2905",
        "prefixes": [
          "2a0e:97c7::/48",
          "2a0e:97c6:fe::/48",
          "2a10:cc42:17b7::/48",
          "2a10:cc42:1feb::/48"
        ]
      }
    ],
    "raw": "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0086020000006F4001010040021202040003127500001A6A000000AE00004FF980040400000000C008081A6A001E1A6A3840800E4100020120200107F8000B010001D1A52013330074FE800000000000000217A3FFFEFE290500302A0E97C70000302A0E97C600FE302A10CC4217B7302A10CC421FEB"
  }
}
        "#;

        let res = parse_raw_bytes(message);
        for elem in res.unwrap() {
            println!("{elem}");
        }
    }
}
