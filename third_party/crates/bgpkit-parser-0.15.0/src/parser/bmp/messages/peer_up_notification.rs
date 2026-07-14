use crate::bgp::parse_bgp_message;
use crate::models::capabilities::BgpCapabilityType;
use crate::models::*;
use crate::parser::bmp::error::ParserBmpError;
use crate::parser::bmp::messages::BmpPeerType;
use crate::parser::ReadUtils;
use bytes::{Buf, Bytes};
use log::warn;
use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::net::IpAddr;

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct PeerUpNotification {
    pub local_addr: IpAddr,
    pub local_port: u16,
    pub remote_port: u16,
    pub sent_open: BgpMessage,
    pub received_open: BgpMessage,
    pub tlvs: Vec<PeerUpNotificationTlv>,
}

///Type-Length-Value Type
///
/// https://www.iana.org/assignments/bmp-parameters/bmp-parameters.xhtml#initiation-peer-up-tlvs
#[derive(Debug, TryFromPrimitive, IntoPrimitive, PartialEq, Clone, Copy)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum PeerUpTlvType {
    String = 0,
    SysDescr = 1,
    SysName = 2,
    VrTableName = 3,
    AdminLabel = 4,
}

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct PeerUpNotificationTlv {
    pub info_type: PeerUpTlvType,
    pub info_len: u16,
    pub info_value: String,
}

pub fn parse_peer_up_notification(
    data: &mut Bytes,
    afi: &Afi,
    asn_len: &AsnLength,
    peer_type: Option<&BmpPeerType>,
) -> Result<PeerUpNotification, ParserBmpError> {
    let local_addr: IpAddr = match afi {
        Afi::Ipv4 => {
            data.has_n_remaining(12)?;
            data.advance(12);
            let ip = data.read_ipv4_address()?;
            ip.into()
        }
        Afi::Ipv6 => data.read_ipv6_address()?.into(),
        Afi::LinkState => {
            // Link-State doesn't use traditional IP addresses for local address
            // Use IPv4 zero address as placeholder
            data.has_n_remaining(12)?;
            data.advance(12);
            std::net::Ipv4Addr::new(0, 0, 0, 0).into()
        }
    };

    let local_port = data.read_u16()?;
    let remote_port = data.read_u16()?;

    // Extract first BGP message with proper boundary
    data.has_n_remaining(19)?; // BGP header
    let bgp1_length = u16::from_be_bytes([data[16], data[17]]) as usize;
    data.has_n_remaining(bgp1_length)?;
    let mut bgp1_data = data.split_to(bgp1_length);
    let sent_open = parse_bgp_message(&mut bgp1_data, false, asn_len)?;

    // Extract second BGP message with proper boundary
    data.has_n_remaining(19)?; // BGP header
    let bgp2_length = u16::from_be_bytes([data[16], data[17]]) as usize;
    data.has_n_remaining(bgp2_length)?;
    let mut bgp2_data = data.split_to(bgp2_length);
    let received_open = parse_bgp_message(&mut bgp2_data, false, asn_len)?;

    // RFC 9069: For Local RIB, the BGP OPEN messages MUST be fabricated
    if let Some(BmpPeerType::LocalRib) = peer_type {
        // Validate that the OPEN messages contain appropriate capabilities for Local RIB
        if let BgpMessage::Open(ref open_msg) = &sent_open {
            let has_multiprotocol_capability = open_msg.opt_params.iter().any(|param| {
                if let ParamValue::Capacities(caps) = &param.param_value {
                    caps.iter()
                        .any(|cap| cap.ty == BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4)
                } else {
                    false
                }
            });
            if !has_multiprotocol_capability {
                warn!("RFC 9069: Local RIB peer up notification should include multiprotocol capabilities in fabricated OPEN messages");
            }
        }
    }

    let mut tlvs = vec![];
    let mut has_vr_table_name = false;

    while data.remaining() >= 4 {
        let info_type = PeerUpTlvType::try_from(data.read_u16()?)?;
        let info_len = data.read_u16()?;
        let info_value = data.read_n_bytes_to_string(info_len as usize)?;

        // RFC 9069: VrTableName TLV validation for Local RIB
        if let Some(BmpPeerType::LocalRib) = peer_type {
            if info_type == PeerUpTlvType::VrTableName {
                has_vr_table_name = true;
                // RFC 9069: VrTableName MUST be UTF-8 string of 1-255 bytes
                if info_value.is_empty() || info_value.len() > 255 {
                    warn!(
                        "RFC 9069: VrTableName TLV length must be 1-255 bytes, found {} bytes",
                        info_value.len()
                    );
                }
            }
        }

        tlvs.push(PeerUpNotificationTlv {
            info_type,
            info_len,
            info_value,
        })
    }

    // RFC 9069: Local RIB instances SHOULD include VrTableName TLV
    if let Some(BmpPeerType::LocalRib) = peer_type {
        if !has_vr_table_name {
            warn!("RFC 9069: Local RIB peer up notification should include VrTableName TLV");
        }
    }
    Ok(PeerUpNotification {
        local_addr,
        local_port,
        remote_port,
        sent_open,
        received_open,
        tlvs,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::capabilities::{BgpCapabilityType, MultiprotocolExtensionsCapability};
    use bytes::BytesMut;
    use std::net::{IpAddr, Ipv4Addr};

    #[test]
    fn test_parse_peer_up_notification() {
        let mut data = BytesMut::new();
        // Assuming setup for test where local address is "10.1.1.1" IPv4
        // local port is 8000, remote port is 9000. Adjust accordingly.
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x01,
            0x01, 0x01,
        ]);
        data.extend_from_slice(&[0x1F, 0x40]); // 8000 in network byte order
        data.extend_from_slice(&[0x23, 0x28]); // 9000 in network byte order

        let bgp_open_message = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 0,
            asn: Default::default(),
            hold_time: 0,
            sender_ip: Ipv4Addr::new(0, 0, 0, 0),
            extended_length: false,
            opt_params: vec![],
        });
        let bgp_open_message_bytes = bgp_open_message.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_open_message_bytes);
        data.extend_from_slice(&bgp_open_message_bytes);

        // add tlv
        data.extend_from_slice(&[0x00, 0x01]); // info_type
        data.extend_from_slice(&[0x00, 0x02]); // info_len
        data.extend_from_slice(&[0x00, 0x03]); // info_value

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;

        let result = parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, None);

        match result {
            Ok(peer_notification) => {
                assert_eq!(
                    peer_notification.local_addr,
                    IpAddr::V4(std::net::Ipv4Addr::new(10, 1, 1, 1))
                );
                assert_eq!(peer_notification.local_port, 8000);
                assert_eq!(peer_notification.remote_port, 9000);

                // Continue to check other values from peer_notification like sent_open, received_open, tlvs
                let tlv = peer_notification.tlvs.first().unwrap();
                assert_eq!(tlv.info_type, PeerUpTlvType::SysDescr);
                assert_eq!(tlv.info_len, 2);
                assert_eq!(tlv.info_value, "\u{0}\u{3}");
            }
            Err(_) => {
                panic!("parse_peer_up_notification should return Ok");
            }
        }
    }

    // Helper function to set up warning capture for tests
    fn setup_warning_logger() -> std::sync::Arc<std::sync::Mutex<Vec<String>>> {
        use log::{Level, Record};
        use std::sync::{Arc, Mutex};

        struct TestLogger(Arc<Mutex<Vec<String>>>);

        impl log::Log for TestLogger {
            fn enabled(&self, metadata: &log::Metadata) -> bool {
                metadata.level() <= Level::Warn
            }

            fn log(&self, record: &Record) {
                if record.level() <= Level::Warn {
                    self.0.lock().unwrap().push(record.args().to_string());
                }
            }

            fn flush(&self) {}
        }

        let warnings = Arc::new(Mutex::new(Vec::new()));
        let logger = TestLogger(warnings.clone());
        let _ = log::set_boxed_logger(Box::new(logger));
        log::set_max_level(log::LevelFilter::Warn);
        warnings
    }

    // Note: These tests verify that the parser handles LocalRib validation correctly.
    // The actual warning messages are logged via the `log` crate and would appear
    // in production use. For testing purposes, we verify that parsing succeeds
    // and the code paths are exercised.

    #[test]
    fn test_parse_peer_up_notification_no_warnings() {
        let warnings = setup_warning_logger();

        // Regression test: This test creates a scenario with two consecutive BGP OPEN messages
        // that would have triggered BGP length warnings in the old implementation.
        // The new implementation should parse cleanly without warnings.

        let mut data = BytesMut::new();

        // Local address (IPv4): 192.168.1.1 + ports
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create two different BGP OPEN messages that will be concatenated
        // This test verifies that the boundary extraction fix prevents BGP length warnings

        // First BGP OPEN message
        let bgp1 = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_16bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![],
        });
        let bgp1_bytes = bgp1.encode(AsnLength::Bits32);

        // Second BGP OPEN message
        let bgp2 = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_16bit(65002),
            hold_time: 90,
            sender_ip: Ipv4Addr::new(192, 168, 1, 2),
            extended_length: false,
            opt_params: vec![],
        });
        let bgp2_bytes = bgp2.encode(AsnLength::Bits32);

        // Add both BGP messages consecutively
        data.extend_from_slice(&bgp1_bytes);
        data.extend_from_slice(&bgp2_bytes);

        // Add a TLV (String type, length 8, "TestNode")
        data.extend_from_slice(&[
            0x00, 0x00, // String TLV type
            0x00, 0x08, // length 8
        ]);
        data.extend_from_slice(b"TestNode");

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;

        let result = parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, None);

        // Test should succeed without any BGP length warnings
        assert!(result.is_ok(), "Parsing should succeed without warnings");

        let peer_notification = result.unwrap();
        assert_eq!(
            peer_notification.local_addr,
            IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))
        );
        assert_eq!(peer_notification.local_port, 179);
        assert_eq!(peer_notification.remote_port, 179);

        // Ensure both BGP messages were parsed correctly with different ASNs
        if let crate::models::BgpMessage::Open(ref open1) = &peer_notification.sent_open {
            assert_eq!(open1.asn, crate::models::Asn::new_16bit(65001));
        } else {
            panic!("sent_open should be an OPEN message");
        }

        if let crate::models::BgpMessage::Open(ref open2) = &peer_notification.received_open {
            assert_eq!(open2.asn, crate::models::Asn::new_16bit(65002));
        } else {
            panic!("received_open should be an OPEN message");
        }

        // Verify TLV was parsed correctly
        assert_eq!(peer_notification.tlvs.len(), 1);
        assert_eq!(peer_notification.tlvs[0].info_type, PeerUpTlvType::String);
        assert_eq!(peer_notification.tlvs[0].info_value, "TestNode");

        // The main assertion: verify no warnings were logged
        let captured_warnings = warnings.lock().unwrap();
        assert!(
            captured_warnings.is_empty(),
            "Test should not produce warnings, but got: {:?}",
            *captured_warnings
        );
    }

    #[test]
    fn test_parse_peer_up_insufficient_data_first_bgp() {
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x01,
            0x01, 0x01,
        ]);
        data.extend_from_slice(&[0x1F, 0x40]); // local port
        data.extend_from_slice(&[0x23, 0x28]); // remote port

        // Add incomplete first BGP message (only header, no body)
        data.extend_from_slice(&[
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // BGP marker
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
            0x40, // Length = 64 bytes (but we won't provide 64 bytes)
            0x01, // OPEN message type
        ]);
        // Missing the remaining 45 bytes of the BGP OPEN message

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let result = parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, None);

        assert!(
            result.is_err(),
            "Should fail with insufficient data for first BGP message"
        );
    }

    #[test]
    fn test_parse_peer_up_insufficient_data_second_bgp() {
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x01,
            0x01, 0x01,
        ]);
        data.extend_from_slice(&[0x1F, 0x40]); // local port
        data.extend_from_slice(&[0x23, 0x28]); // remote port

        // Add complete first BGP message
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: Default::default(),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(0, 0, 0, 0),
            extended_length: false,
            opt_params: vec![],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);

        // Add incomplete second BGP message (only partial header)
        data.extend_from_slice(&[
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // BGP marker
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00,
            0x30, // Length = 48 bytes
                  // Missing message type and body
        ]);

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let result = parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, None);

        assert!(
            result.is_err(),
            "Should fail with insufficient data for second BGP message"
        );
    }

    #[test]
    fn test_parse_peer_up_excess_data_in_tlvs() {
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x01,
            0x01, 0x01,
        ]);
        data.extend_from_slice(&[0x1F, 0x40]); // local port
        data.extend_from_slice(&[0x23, 0x28]); // remote port

        // Add two complete BGP messages
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: Default::default(),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(0, 0, 0, 0),
            extended_length: false,
            opt_params: vec![],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        // Add valid TLVs
        data.extend_from_slice(&[0x00, 0x00]); // String TLV
        data.extend_from_slice(&[0x00, 0x04]); // length 4
        data.extend_from_slice(b"Test"); // value

        data.extend_from_slice(&[0x00, 0x00]); // String TLV
        data.extend_from_slice(&[0x00, 0x06]); // length 6
        data.extend_from_slice(b"Router"); // value

        // Add some random extra bytes (should be safely ignored due to TLV parsing logic)
        data.extend_from_slice(&[0x00, 0x01, 0x02]); // Less than 4 bytes, should exit TLV parsing loop

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let result = parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, None);

        // Should succeed - TLV parsing handles excess data gracefully
        assert!(result.is_ok(), "Should handle excess data gracefully");

        let peer_notification = result.unwrap();
        assert_eq!(peer_notification.tlvs.len(), 2); // Should have parsed 2 TLVs
        assert_eq!(peer_notification.tlvs[0].info_type, PeerUpTlvType::String);
        assert_eq!(peer_notification.tlvs[0].info_value, "Test");
        assert_eq!(peer_notification.tlvs[1].info_type, PeerUpTlvType::String);
        assert_eq!(peer_notification.tlvs[1].info_value, "Router");
    }

    #[test]
    fn test_local_rib_without_multiprotocol_capability() {
        // This test verifies that LocalRib peer up notifications without multiprotocol
        // capabilities are parsed successfully. In production, a warning would be logged.
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create BGP OPEN message WITHOUT multiprotocol capabilities (RFC 9069 violation)
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_32bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![], // No capabilities
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let peer_type = BmpPeerType::LocalRib;

        let result =
            parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // In production, a warning would be logged about missing multiprotocol capability
    }

    #[test]
    fn test_local_rib_with_multiprotocol_capability() {
        // This test verifies that LocalRib peer up notifications WITH multiprotocol
        // capabilities are parsed successfully without warnings.
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create BGP OPEN message WITH multiprotocol capabilities (RFC 9069 compliant)
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_32bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 6,
                param_value: ParamValue::Capacities(vec![Capability {
                    ty: BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4,
                    value: CapabilityValue::MultiprotocolExtensions(
                        MultiprotocolExtensionsCapability {
                            afi: Afi::Ipv4,
                            safi: Safi::Unicast,
                        },
                    ),
                }]),
            }],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let peer_type = BmpPeerType::LocalRib;

        let result =
            parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // No warning should be logged when multiprotocol capability is present
    }

    #[test]
    fn test_local_rib_without_vr_table_name_tlv() {
        // This test verifies that LocalRib peer up notifications without VrTableName TLV
        // are parsed successfully. In production, a warning would be logged.
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create BGP OPEN message with capabilities
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_32bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 6,
                param_value: ParamValue::Capacities(vec![Capability {
                    ty: BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4,
                    value: CapabilityValue::MultiprotocolExtensions(
                        MultiprotocolExtensionsCapability {
                            afi: Afi::Ipv4,
                            safi: Safi::Unicast,
                        },
                    ),
                }]),
            }],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        // Add TLVs but NO VrTableName (RFC 9069 violation)
        data.extend_from_slice(&[0x00, 0x00]); // String TLV
        data.extend_from_slice(&[0x00, 0x04]); // length 4
        data.extend_from_slice(b"Test");

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let peer_type = BmpPeerType::LocalRib;

        let result =
            parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // In production, a warning would be logged about missing VrTableName TLV
    }

    #[test]
    fn test_local_rib_with_valid_vr_table_name_tlv() {
        // This test verifies that LocalRib peer up notifications with valid VrTableName TLV
        // are parsed successfully without warnings.
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create BGP OPEN message with capabilities
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_32bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 6,
                param_value: ParamValue::Capacities(vec![Capability {
                    ty: BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4,
                    value: CapabilityValue::MultiprotocolExtensions(
                        MultiprotocolExtensionsCapability {
                            afi: Afi::Ipv4,
                            safi: Safi::Unicast,
                        },
                    ),
                }]),
            }],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        // Add VrTableName TLV with valid length (1-255 bytes)
        data.extend_from_slice(&[0x00, 0x03]); // VrTableName TLV type
        data.extend_from_slice(&[0x00, 0x08]); // length 8
        data.extend_from_slice(b"LocalRIB");

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let peer_type = BmpPeerType::LocalRib;

        let result =
            parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");

        let peer_notification = result.unwrap();
        assert_eq!(peer_notification.tlvs.len(), 1);
        assert_eq!(
            peer_notification.tlvs[0].info_type,
            PeerUpTlvType::VrTableName
        );
        assert_eq!(peer_notification.tlvs[0].info_value, "LocalRIB");
        // No warnings should be logged with valid VrTableName
    }

    #[test]
    fn test_local_rib_with_empty_vr_table_name() {
        // This test verifies that LocalRib peer up notifications with empty VrTableName
        // are parsed successfully. In production, a warning would be logged.
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create BGP OPEN message with capabilities
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_32bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 6,
                param_value: ParamValue::Capacities(vec![Capability {
                    ty: BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4,
                    value: CapabilityValue::MultiprotocolExtensions(
                        MultiprotocolExtensionsCapability {
                            afi: Afi::Ipv4,
                            safi: Safi::Unicast,
                        },
                    ),
                }]),
            }],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        // Add VrTableName TLV with EMPTY value (RFC 9069 violation)
        data.extend_from_slice(&[0x00, 0x03]); // VrTableName TLV type
        data.extend_from_slice(&[0x00, 0x00]); // length 0 (empty)

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let peer_type = BmpPeerType::LocalRib;

        let result =
            parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // In production, a warning would be logged about invalid VrTableName length
    }

    #[test]
    fn test_local_rib_with_oversized_vr_table_name() {
        // This test verifies that LocalRib peer up notifications with oversized VrTableName
        // are parsed successfully. In production, a warning would be logged.
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create BGP OPEN message with capabilities
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_32bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 6,
                param_value: ParamValue::Capacities(vec![Capability {
                    ty: BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4,
                    value: CapabilityValue::MultiprotocolExtensions(
                        MultiprotocolExtensionsCapability {
                            afi: Afi::Ipv4,
                            safi: Safi::Unicast,
                        },
                    ),
                }]),
            }],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        // Add VrTableName TLV with oversized value (>255 bytes, RFC 9069 violation)
        let oversized_name = "A".repeat(256);
        data.extend_from_slice(&[0x00, 0x03]); // VrTableName TLV type
        data.extend_from_slice(&[0x01, 0x00]); // length 256
        data.extend_from_slice(oversized_name.as_bytes());

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let peer_type = BmpPeerType::LocalRib;

        let result =
            parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // In production, a warning would be logged about oversized VrTableName
    }

    #[test]
    fn test_non_local_rib_no_validation() {
        // This test verifies that non-LocalRib peer types don't trigger LocalRib validations
        let mut data = BytesMut::new();

        // Local address setup
        data.extend_from_slice(&[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xA8,
            0x01, 0x01, // 192.168.1.1
            0x00, 0xB3, // local port 179
            0x00, 0xB3, // remote port 179
        ]);

        // Create BGP OPEN message WITHOUT capabilities (but not LocalRib, so no warning)
        let bgp_open = crate::models::BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: crate::models::Asn::new_32bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 168, 1, 1),
            extended_length: false,
            opt_params: vec![],
        });
        let bgp_bytes = bgp_open.encode(AsnLength::Bits32);
        data.extend_from_slice(&bgp_bytes);
        data.extend_from_slice(&bgp_bytes);

        let afi = Afi::Ipv4;
        let asn_len = AsnLength::Bits32;
        let peer_type = BmpPeerType::Global; // Not LocalRib

        let result =
            parse_peer_up_notification(&mut data.freeze(), &afi, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // No warnings should be logged for non-LocalRib peer types
    }
}
