/*!
Provides parsing functions for [RIS-Live](https://ris-live.ripe.net/manual/) real-time
BGP message stream JSON data.

The main parsing function, [parse_ris_live_message] converts a JSON-formatted message string into a
vector of [BgpElem]s.

Here is an example parsing stream data from one collector:
```no_run
use bgpkit_parser::parse_ris_live_message;
use serde_json::json;
use tungstenite::{connect, Message};

const RIS_LIVE_URL: &str = "ws://ris-live.ripe.net/v1/ws/?client=rust-bgpkit-parser";

/// This is an example of subscribing to RIS-Live's streaming data from one host (`rrc21`).
///
/// For more RIS-Live details, check out their documentation at https://ris-live.ripe.net/manual/
fn main() {
    // connect to RIPE RIS Live websocket server
    let (mut socket, _response) =
        connect(RIS_LIVE_URL)
            .expect("Can't connect to RIS Live websocket server");

    // subscribe to messages from one collector
    let msg = json!({"type": "ris_subscribe", "data": {"host": "rrc21"}}).to_string();
    socket.send(Message::Text(msg.into())).unwrap();

    loop {
        let msg = socket.read().expect("Error reading message").to_string();
        if let Ok(elems) = parse_ris_live_message(msg.as_str()) {
            for elem in elems {
                println!("{}", elem);
            }
        }
    }
}
```
*/
use crate::parser::rislive::error::ParserRisliveError;
use crate::parser::rislive::messages::{RisLiveMessage, RisMessageEnum};

use crate::models::*;
use ipnet::IpNet;
use std::net::Ipv4Addr;

pub mod error;
pub mod messages;

// simple macro to make the code look a bit nicer
macro_rules! unwrap_or_return {
    ( $e:expr, $msg_string:expr ) => {
        match $e {
            Ok(x) => x,
            Err(_) => return Err(ParserRisliveError::IncorrectJson($msg_string)),
        }
    };
}

/// parse prefix string into IpNet
fn parse_prefix(prefix_str: &str) -> Result<IpNet, ParserRisliveError> {
    let p = match prefix_str.parse::<IpNet>() {
        Ok(net) => net,
        Err(_) => {
            if prefix_str == "eor" {
                return Err(ParserRisliveError::ElemEndOfRibPrefix);
            }
            return Err(ParserRisliveError::ElemIncorrectPrefix(
                prefix_str.to_string(),
            ));
        }
    };
    Ok(p)
}

/// This function parses one message and returns a result of a vector of [BgpElem]s or an error
pub fn parse_ris_live_message(msg_str: &str) -> Result<Vec<BgpElem>, ParserRisliveError> {
    let msg_string = msg_str.to_string();

    // parse RIS Live message to internal struct using serde.
    let msg: RisLiveMessage = match serde_json::from_str(msg_str) {
        Ok(m) => m,
        Err(_e) => return Err(ParserRisliveError::IncorrectJson(msg_string)),
    };

    match msg {
        RisLiveMessage::RisMessage(ris_msg) => {
            // we currently only handles the `ris_message` data type. other
            // types provides meta information, but reveals no BGP elements, and
            // thus for now will be ignored.

            if ris_msg.msg.is_none() {
                return Ok(vec![]);
            }

            match ris_msg.msg.unwrap() {
                RisMessageEnum::UPDATE {
                    path,
                    community,
                    origin,
                    med,
                    aggregator,
                    announcements,
                    withdrawals,
                } => {
                    let mut elems: Vec<BgpElem> = vec![];

                    // parse community
                    let communities = community.map(|values| {
                        values
                            .into_iter()
                            .map(|(asn, data)| {
                                MetaCommunity::Plain(Community::Custom(Asn::new_32bit(asn), data))
                            })
                            .collect()
                    });

                    // parse origin
                    let bgp_origin = match origin {
                        None => None,
                        Some(o) => Some(match o.as_str() {
                            "igp" | "IGP" => Origin::IGP,
                            "egp" | "EGP" => Origin::EGP,
                            "incomplete" | "INCOMPLETE" => Origin::INCOMPLETE,
                            other => {
                                return Err(ParserRisliveError::ElemUnknownOriginType(
                                    other.to_string(),
                                ));
                            }
                        }),
                    };

                    // parse aggregator
                    let bgp_aggregator = match aggregator {
                        None => (None, None),
                        Some(aggr_str) => {
                            let (asn_str, ip_str) = match aggr_str.split_once(':') {
                                None => {
                                    return Err(ParserRisliveError::ElemIncorrectAggregator(
                                        aggr_str,
                                    ))
                                }
                                Some(v) => v,
                            };

                            let asn = unwrap_or_return!(asn_str.parse::<Asn>(), msg_string);
                            let ip = unwrap_or_return!(ip_str.parse::<Ipv4Addr>(), msg_string);
                            (Some(asn), Some(ip))
                        }
                    };

                    // parser announcements
                    if let Some(announcements) = announcements {
                        for announcement in announcements {
                            for prefix in &announcement.prefixes {
                                let p = parse_prefix(prefix.as_str())?;
                                elems.push(BgpElem {
                                    timestamp: ris_msg.timestamp,
                                    elem_type: ElemType::ANNOUNCE,
                                    peer_ip: ris_msg.peer,
                                    peer_asn: ris_msg.peer_asn,
                                    prefix: NetworkPrefix {
                                        prefix: p,
                                        path_id: None,
                                    },
                                    next_hop: Some(announcement.next_hop),
                                    as_path: path.clone(),
                                    origin_asns: None,
                                    origin: bgp_origin,
                                    local_pref: None,
                                    med,
                                    communities: communities.clone(),
                                    atomic: false,
                                    aggr_asn: bgp_aggregator.0,
                                    aggr_ip: bgp_aggregator.1,
                                    only_to_customer: None,
                                    unknown: None,
                                    deprecated: None,
                                });
                            }
                        }
                    }

                    if let Some(withdrawals) = withdrawals {
                        for prefix in withdrawals {
                            // create new elems for withdrawals and push to elems
                            let p = parse_prefix(prefix.as_str())?;
                            elems.push(BgpElem {
                                timestamp: ris_msg.timestamp,
                                elem_type: ElemType::WITHDRAW,
                                peer_ip: ris_msg.peer,
                                peer_asn: ris_msg.peer_asn,
                                prefix: NetworkPrefix {
                                    prefix: p,
                                    path_id: None,
                                },
                                next_hop: None,
                                as_path: None,
                                origin_asns: None,
                                origin: None,
                                local_pref: None,
                                med: None,
                                communities: None,
                                atomic: false,
                                aggr_asn: None,
                                aggr_ip: None,
                                only_to_customer: None,
                                unknown: None,
                                deprecated: None,
                            })
                        }
                    }

                    Ok(elems)
                }
                _ => Ok(vec![]),
            }
        }
        _ => Ok(vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ris_live_msg() {
        let msg_str = r#"
        {"type": "ris_message","data":{"timestamp":1636247118.76,"peer":"2001:7f8:24::82","peer_asn":"58299","id":"20-5761-238131559","host":"rrc20","type":"UPDATE","path":[58299,49981,397666],"origin":"igp","announcements":[{"next_hop":"2001:7f8:24::82","prefixes":["2602:fd9e:f00::/40"]},{"next_hop":"fe80::768e:f8ff:fea6:b2c4","prefixes":["2602:fd9e:f00::/40"]}],"raw":"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF005A02000000434001010040020E02030000E3BB0000C33D00061162800E2B00020120200107F8002400000000000000000082FE80000000000000768EF8FFFEA6B2C400282602FD9E0F"}}
        "#;
        let msg = parse_ris_live_message(msg_str).unwrap();
        for elem in msg {
            println!("{elem}");
        }
    }

    #[test]
    fn test_error_message() {
        let msg_str = r#"
        {"type": "ris_message","data":{"timestamp":1636342486.17,"peer":"37.49.237.175","peer_asn":"199524","id":"21-587-22045871","host":"rrc21","type":"UPDATE","path":[199524,1299,3356,13904,13904,13904,13904,13904,13904],"origin":"igp","aggregator":"65000:8.42.232.1","announcements":[{"next_hop":"37.49.237.175","prefixes":["64.68.236.0/22"]}]}}
        "#;
        let msg = parse_ris_live_message(msg_str).unwrap();
        for elem in msg {
            println!("{elem}");
        }
    }

    #[test]
    fn test_error_message_2() {
        let msg_str = r#"
        {"type": "ris_message","data":{"timestamp":1636339375.83,"peer":"37.49.236.1","peer_asn":"8218","id":"21-594-37970252","host":"rrc21"}}
        "#;
        let msg = parse_ris_live_message(msg_str).unwrap();
        for elem in msg {
            println!("{elem}");
        }
    }

    #[test]
    fn test_error_message_3() {
        let msg_str = r#"
        {"type": "ris_message","data":{"timestamp":1640553894.84,"peer":"195.66.226.38","peer_asn":"24482","id":"01-2833-11980099","host":"rrc01","type":"UPDATE","path":[24482,30844,328471,328471,328471],"community":[[0,5713],[0,6939],[0,32934],[8714,65010],[8714,65012],[24482,2],[24482,12010],[24482,12011],[24482,65201],[30844,27]],"origin":"igp","aggregator":"4200000002:10.102.100.2","announcements":[{"next_hop":"195.66.224.68","prefixes":["102.66.116.0/24"]}]}}
        "#;
        let msg = parse_ris_live_message(msg_str).unwrap();
        for elem in msg {
            println!("{elem}");
        }
    }

    #[test]
    fn test_ris_live_with_withdrawals() {
        // correct prefix
        let msg_str = r#"{ "type": "ris_message", "data": { "timestamp": 1740561857.910, "peer": "2606:6dc0:1301::1", "peer_asn": "13781", "id": "2606:6dc0:1301::1-019541923d760008", "host": "rrc25.ripe.net", "type": "UPDATE", "path": [], "community": [], "announcements": [], "withdrawals": [ "2605:de00:bb:0:0:0:0:0/48" ] } }"#;
        let elems = parse_ris_live_message(msg_str).unwrap();
        assert_eq!(elems.len(), 1);
        assert_eq!(elems[0].elem_type, ElemType::WITHDRAW);
    }

    #[test]
    fn test_parse_prefix() {
        // parse correct ipv4 prefix
        let prefix_str = "192.0.2.0/24".to_string();
        let parse_result = parse_prefix(&prefix_str);
        assert!(parse_result.is_ok());
        assert_eq!(parse_result.unwrap().to_string().as_str(), &prefix_str);

        // parse correct ipv6 prefix
        let prefix_str = "2001:db8::/32".to_string();
        let parse_result = parse_prefix(&prefix_str);
        assert!(parse_result.is_ok());
        assert_eq!(parse_result.unwrap().to_string().as_str(), &prefix_str);

        // parse incorrect ipv4 prefix
        let prefix_str = "192.0.2.0/38".to_string();
        let parse_result = parse_prefix(&prefix_str);
        assert!(parse_result.is_err());
        matches!(
            parse_result,
            Err(ParserRisliveError::ElemIncorrectPrefix(_))
        );

        // parse eof string
        let prefix_str = "eor".to_string();
        let parse_result = parse_prefix(&prefix_str);
        assert!(parse_result.is_err());
        matches!(parse_result, Err(ParserRisliveError::ElemEndOfRibPrefix));
    }

    #[test]
    fn test_unknown_origin_type() {
        // Test with an unknown origin type
        let msg_str = r#"
        {"type": "ris_message","data":{"timestamp":1636247118.76,"peer":"2001:7f8:24::82","peer_asn":"58299","id":"20-5761-238131559","host":"rrc20","type":"UPDATE","path":[58299,49981,397666],"origin":"unknown","announcements":[{"next_hop":"2001:7f8:24::82","prefixes":["2602:fd9e:f00::/40"]}]}}
        "#;

        let result = parse_ris_live_message(msg_str);
        assert!(result.is_err());

        if let Err(ParserRisliveError::ElemUnknownOriginType(origin_type)) = result {
            assert_eq!(origin_type, "unknown");
        } else {
            panic!("Expected ElemUnknownOriginType error");
        }
    }

    #[test]
    fn test_incorrect_aggregator_format() {
        // Test with an incorrect aggregator format (missing colon)
        let msg_str = r#"
        {"type": "ris_message","data":{"timestamp":1636247118.76,"peer":"2001:7f8:24::82","peer_asn":"58299","id":"20-5761-238131559","host":"rrc20","type":"UPDATE","path":[58299,49981,397666],"origin":"igp","aggregator":"65000-8.42.232.1","announcements":[{"next_hop":"2001:7f8:24::82","prefixes":["2602:fd9e:f00::/40"]}]}}
        "#;

        let result = parse_ris_live_message(msg_str);
        assert!(result.is_err());

        if let Err(ParserRisliveError::ElemIncorrectAggregator(aggregator)) = result {
            assert_eq!(aggregator, "65000-8.42.232.1");
        } else {
            panic!("Expected ElemIncorrectAggregator error");
        }
    }

    #[test]
    fn test_non_ris_message() {
        // Test with a non-RIS message
        let msg_str = r#"
        {"type": "other_message","data":{}}
        "#;

        let result = parse_ris_live_message(msg_str);
        assert!(result.is_err());
    }

    #[test]
    fn test_non_update_message() {
        // Test with a RIS message that is not an UPDATE message
        let msg_str = r#"
        {"type": "ris_message","data":{"timestamp":1636247118.76,"peer":"2001:7f8:24::82","peer_asn":"58299","id":"20-5761-238131559","host":"rrc20","type":"OTHER","msg":{"type":"OTHER"}}}
        "#;

        let result = parse_ris_live_message(msg_str);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 0);
    }
}
