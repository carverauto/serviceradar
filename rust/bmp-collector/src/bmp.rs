use anyhow::{Context, Result};
use arancini_lib::processor::{peer_down_notification, peer_up_notification, route_monitoring};
use arancini_lib::sender::UpdateSender;
use arancini_lib::state::AsyncState;
use arancini_lib::state_store::store::StateStore;
use arancini_lib::update::new_metadata;
use bgpkit_parser::bgp::messages::parse_bgp_message;
use bgpkit_parser::bmp::messages::{
    BmpMessage, BmpMessageBody, BmpMsgType, PeerUpNotification, PeerUpNotificationTlv,
    PeerUpTlvType, RouteMonitoring, parse_bmp_common_header, parse_initiation_message,
    parse_peer_down_notification, parse_per_peer_header, parse_route_mirroring, parse_stats_report,
    parse_termination_message,
};
use bgpkit_parser::models::{Afi, Asn, AsnLength, BgpMessage, BgpOpenMessage};
use bytes::Bytes;
use log::debug;
use std::net::Ipv4Addr;
use std::net::SocketAddr;

pub async fn process_bmp_message<T: StateStore, S: UpdateSender>(
    state: Option<AsyncState<T>>,
    tx: S,
    socket: SocketAddr,
    bytes: &mut Bytes,
) -> Result<()> {
    let raw_frame = bytes.clone();
    let message = decode_bmp_message(bytes).with_context(|| {
        format!(
            "{socket}: failed to decode BMP message: frame_len={} frame_hex={}",
            raw_frame.len(),
            frame_hex_for_log(&raw_frame)
        )
    })?;

    let metadata = new_metadata(socket, &message);

    match message.message_body {
        BmpMessageBody::InitiationMessage(body) => {
            let tlvs_info = body
                .tlvs
                .iter()
                .map(|tlv| tlv.info.clone())
                .collect::<Vec<_>>();
            debug!("{socket}: InitiationMessage: {tlvs_info:?}");
        }
        BmpMessageBody::PeerUpNotification(body) => {
            let metadata = metadata.clone().ok_or_else(|| {
                anyhow::anyhow!("{socket}: PeerUpNotification: no per-peer header")
            })?;
            debug!("{socket}: PeerUpNotification: {}", metadata.peer_addr);
            peer_up_notification(state, tx, metadata.clone(), body)
                .await
                .with_context(|| {
                    format!(
                        "{socket}: PeerUpNotification processing failed for peer {}",
                        metadata.peer_addr
                    )
                })?;
        }
        BmpMessageBody::RouteMonitoring(body) => {
            let metadata = metadata
                .clone()
                .ok_or_else(|| anyhow::anyhow!("{socket}: RouteMonitoring: no per-peer header"))?;
            if !metadata.peer_addr.is_unspecified() {
                route_monitoring(state, tx, metadata.clone(), body)
                    .await
                    .with_context(|| {
                        format!(
                            "{socket}: RouteMonitoring processing failed for peer {} asn {}",
                            metadata.peer_addr, metadata.peer_asn
                        )
                    })?;
            }
        }
        BmpMessageBody::RouteMirroring(_) => {
            debug!("{socket}: RouteMirroring");
        }
        BmpMessageBody::PeerDownNotification(body) => {
            let metadata = metadata.clone().ok_or_else(|| {
                anyhow::anyhow!("{socket}: PeerDownNotification: no per-peer header")
            })?;
            debug!(
                "{socket}: PeerDownNotification: {}. Reason: {:?}",
                metadata.peer_addr, body.reason
            );
            peer_down_notification(state, tx, metadata.clone(), body)
                .await
                .with_context(|| {
                    format!(
                        "{socket}: PeerDownNotification processing failed for peer {}",
                        metadata.peer_addr
                    )
                })?;
        }
        BmpMessageBody::TerminationMessage(_) => {
            debug!("{socket}: TerminationMessage");
        }
        BmpMessageBody::StatsReport(_) => {
            debug!("{socket}: StatsReport");
        }
    }

    Ok(())
}

fn frame_hex_for_log(frame: &Bytes) -> String {
    const MAX_BYTES_TO_LOG: usize = 512;
    if frame.len() <= MAX_BYTES_TO_LOG {
        return hex::encode(frame);
    }

    let head = hex::encode(&frame[..MAX_BYTES_TO_LOG / 2]);
    let tail = hex::encode(&frame[frame.len() - (MAX_BYTES_TO_LOG / 2)..]);
    format!("{head}...{tail}")
}

fn decode_bmp_message(bytes: &mut Bytes) -> Result<BmpMessage> {
    let common_header = parse_bmp_common_header(bytes)?;
    let msg_len = common_header.msg_len as usize;
    if msg_len < 6 {
        anyhow::bail!("corrupted BMP message: invalid message length {msg_len}");
    }

    let content_length = msg_len - 6;
    if bytes.len() < content_length {
        anyhow::bail!(
            "truncated BMP message: expected {content_length} bytes, found {}",
            bytes.len()
        );
    }
    let mut content = bytes.split_to(content_length);

    match common_header.msg_type {
        BmpMsgType::RouteMonitoring => {
            let per_peer_header = parse_per_peer_header(&mut content)?;
            let msg = parse_route_monitoring_with_add_path_retry(
                &mut content,
                &per_peer_header.asn_length(),
            )?;
            Ok(BmpMessage {
                common_header,
                per_peer_header: Some(per_peer_header),
                message_body: BmpMessageBody::RouteMonitoring(msg),
            })
        }
        BmpMsgType::RouteMirroringMessage => {
            let per_peer_header = parse_per_peer_header(&mut content)?;
            let msg = parse_route_mirroring(
                &mut content,
                &per_peer_header.asn_length(),
                Some(&per_peer_header.peer_type),
            )?;
            Ok(BmpMessage {
                common_header,
                per_peer_header: Some(per_peer_header),
                message_body: BmpMessageBody::RouteMirroring(msg),
            })
        }
        BmpMsgType::StatisticsReport => {
            let per_peer_header = parse_per_peer_header(&mut content)?;
            let msg = parse_stats_report(&mut content)?;
            Ok(BmpMessage {
                common_header,
                per_peer_header: Some(per_peer_header),
                message_body: BmpMessageBody::StatsReport(msg),
            })
        }
        BmpMsgType::PeerDownNotification => {
            let per_peer_header = parse_per_peer_header(&mut content)?;
            let msg = parse_peer_down_notification(&mut content)?;
            Ok(BmpMessage {
                common_header,
                per_peer_header: Some(per_peer_header),
                message_body: BmpMessageBody::PeerDownNotification(msg),
            })
        }
        BmpMsgType::PeerUpNotification => {
            let per_peer_header = parse_per_peer_header(&mut content)?;
            let msg = parse_peer_up_notification_lenient(
                &mut content,
                &per_peer_header.afi(),
                &per_peer_header.asn_length(),
            )?;
            Ok(BmpMessage {
                common_header,
                per_peer_header: Some(per_peer_header),
                message_body: BmpMessageBody::PeerUpNotification(msg),
            })
        }
        BmpMsgType::InitiationMessage => {
            let msg = parse_initiation_message(&mut content)?;
            Ok(BmpMessage {
                common_header,
                per_peer_header: None,
                message_body: BmpMessageBody::InitiationMessage(msg),
            })
        }
        BmpMsgType::TerminationMessage => {
            let msg = parse_termination_message(&mut content)?;
            Ok(BmpMessage {
                common_header,
                per_peer_header: None,
                message_body: BmpMessageBody::TerminationMessage(msg),
            })
        }
    }
}

fn parse_route_monitoring_with_add_path_retry(
    data: &mut Bytes,
    asn_len: &bgpkit_parser::models::AsnLength,
) -> Result<RouteMonitoring> {
    let mut without_add_path = data.clone();
    match parse_bgp_message(&mut without_add_path, false, asn_len) {
        Ok(bgp_message) => {
            *data = without_add_path;
            return Ok(RouteMonitoring { bgp_message });
        }
        Err(primary_err) => {
            let mut with_add_path = data.clone();
            match parse_bgp_message(&mut with_add_path, true, asn_len) {
                Ok(bgp_message) => {
                    *data = with_add_path;
                    debug!("route-monitoring Add-Path retry succeeded after: {primary_err}");
                    Ok(RouteMonitoring { bgp_message })
                }
                Err(retry_err) => Err(anyhow::anyhow!(
                    "failed to parse route-monitoring update without Add-Path ({primary_err}) or with Add-Path ({retry_err})"
                )),
            }
        }
    }
}

fn parse_peer_up_notification_lenient(
    data: &mut Bytes,
    afi: &Afi,
    asn_len: &AsnLength,
) -> Result<PeerUpNotification> {
    let local_addr = match afi {
        Afi::Ipv4 => {
            if data.len() < 16 {
                anyhow::bail!("peer-up notification missing IPv4 local address");
            }
            std::net::IpAddr::V4(Ipv4Addr::new(data[12], data[13], data[14], data[15]))
        }
        Afi::Ipv6 => {
            if data.len() < 16 {
                anyhow::bail!("peer-up notification missing IPv6 local address");
            }
            let mut octets = [0u8; 16];
            octets.copy_from_slice(&data[..16]);
            std::net::IpAddr::V6(octets.into())
        }
        Afi::LinkState => {
            if data.len() < 16 {
                anyhow::bail!("peer-up notification missing link-state local address bytes");
            }
            std::net::IpAddr::V4(Ipv4Addr::UNSPECIFIED)
        }
    };
    let _ = data.split_to(16);

    if data.len() < 4 {
        anyhow::bail!("peer-up notification missing local/remote ports");
    }
    let local_port = u16::from_be_bytes([data[0], data[1]]);
    let remote_port = u16::from_be_bytes([data[2], data[3]]);
    let _ = data.split_to(4);

    let sent_open = parse_bgp_open_with_fallback(data, asn_len, false)?;
    let received_open = parse_bgp_open_with_fallback(data, asn_len, true)?;
    let tlvs = parse_peer_up_tlvs(data);

    Ok(PeerUpNotification {
        local_addr,
        local_port,
        remote_port,
        sent_open,
        received_open,
        tlvs,
    })
}

fn parse_bgp_open_with_fallback(
    data: &mut Bytes,
    asn_len: &AsnLength,
    consume_all_on_failure: bool,
) -> Result<BgpMessage> {
    let original = data.clone();
    match parse_bgp_message_with_declared_length(data, false, asn_len) {
        Ok(message) => Ok(message),
        Err(err) => {
            *data = original.clone();
            let consume_len = if consume_all_on_failure {
                original.len()
            } else {
                declared_bgp_message_length(&original)?
            };
            let message = parse_bgp_open_placeholder(data, consume_len).with_context(|| {
                format!("failed recovering malformed peer-up OPEN after strict parse error: {err}")
            })?;
            debug!(
                "peer-up OPEN fallback consumed {consume_len} bytes after strict parse error: {err}"
            );
            Ok(message)
        }
    }
}

fn parse_bgp_message_with_declared_length(
    data: &mut Bytes,
    add_path: bool,
    asn_len: &AsnLength,
) -> Result<BgpMessage> {
    let length = declared_bgp_message_length(data)?;
    if data.len() < length {
        anyhow::bail!(
            "BGP message declares length {length} but only {} bytes remain",
            data.len()
        );
    }
    let mut bgp_data = data.split_to(length);
    Ok(parse_bgp_message(&mut bgp_data, add_path, asn_len)?)
}

fn declared_bgp_message_length(data: &Bytes) -> Result<usize> {
    if data.len() < 18 {
        anyhow::bail!("BGP message missing common header");
    }
    Ok(u16::from_be_bytes([data[16], data[17]]) as usize)
}

fn parse_bgp_open_placeholder(data: &mut Bytes, consume_len: usize) -> Result<BgpMessage> {
    if data.len() < consume_len {
        anyhow::bail!(
            "cannot recover peer-up OPEN: requested {consume_len} bytes with only {} available",
            data.len()
        );
    }

    let mut raw = data.split_to(consume_len);
    if raw.len() < 29 {
        anyhow::bail!(
            "peer-up OPEN too short for placeholder parse: {}",
            raw.len()
        );
    }

    let _marker = raw.split_to(16);
    let _length = raw.split_to(2);
    let msg_type = raw[0];
    let _ = raw.split_to(1);
    if msg_type != 1 {
        anyhow::bail!("peer-up placeholder expected OPEN message type, found {msg_type}");
    }

    if raw.len() < 10 {
        anyhow::bail!(
            "peer-up OPEN body too short for placeholder parse: {}",
            raw.len()
        );
    }

    let version = raw[0];
    let asn = u16::from_be_bytes([raw[1], raw[2]]);
    let hold_time = u16::from_be_bytes([raw[3], raw[4]]);
    let sender_ip = Ipv4Addr::new(raw[5], raw[6], raw[7], raw[8]);

    Ok(BgpMessage::Open(BgpOpenMessage {
        version,
        asn: Asn::new_16bit(asn),
        hold_time,
        sender_ip,
        extended_length: false,
        opt_params: Vec::new(),
    }))
}

fn parse_peer_up_tlvs(data: &mut Bytes) -> Vec<PeerUpNotificationTlv> {
    let mut tlvs = Vec::new();

    while data.len() >= 4 {
        let info_type_raw = u16::from_be_bytes([data[0], data[1]]);
        let info_len = u16::from_be_bytes([data[2], data[3]]) as usize;
        let Ok(info_type) = PeerUpTlvType::try_from(info_type_raw) else {
            break;
        };
        if data.len() < 4 + info_len {
            break;
        }
        let value_bytes = data[4..4 + info_len].to_vec();
        let info_value = String::from_utf8_lossy(&value_bytes).to_string();
        let _ = data.split_to(4 + info_len);
        tlvs.push(PeerUpNotificationTlv {
            info_type,
            info_len: info_len as u16,
            info_value,
        });
    }

    tlvs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_gobgp_add_path_route_monitoring_frame() {
        let frame = hex::decode("030000009000000000000000000000000000000000000000000000000a000204000620ea0a00020469c6b51c00000000ffffffffffffffffffffffffffffffff00600200000015400101004002004003040a00020440050400000064200a2ba0c320178a7c1220178a7c161a0a2a9e401b178a7c0020178a7c0218c0a806200a2b87ad100a2b200a2b8e3e200a2b4e00").unwrap();
        let mut bytes = Bytes::from(frame);
        let message = decode_bmp_message(&mut bytes).expect("captured GoBGP frame should decode");

        match message.message_body {
            BmpMessageBody::RouteMonitoring(route_monitoring) => {
                assert!(
                    matches!(
                        route_monitoring.bgp_message,
                        bgpkit_parser::models::BgpMessage::Update(_)
                    ),
                    "route-monitoring body should contain a BGP UPDATE"
                );
            }
            other => panic!("expected route monitoring, got {other:?}"),
        }
    }

    #[test]
    fn decodes_gobgp_peer_up_with_malformed_second_open_length() {
        let frame = hex::decode("03000000b403000000000000000000000000000000000000000000000a000203000620ea0a00020369c6b97b000000000000000000000000000000000a2a446ebe9100b3ffffffffffffffffffffffffffffffff002d01045ba0005accd1333b10020e02000104000100014104000620eaffffffffffffffffffffffffffffffff003f01045ba000f00a000203260224010400010001020040060078000101004104000620ea4508000101034600470046004700").unwrap();
        let mut bytes = Bytes::from(frame);
        let message =
            decode_bmp_message(&mut bytes).expect("captured GoBGP peer-up frame should decode");

        match message.message_body {
            BmpMessageBody::PeerUpNotification(peer_up) => {
                assert_eq!(peer_up.local_port, 48785);
                assert_eq!(peer_up.remote_port, 179);
            }
            other => panic!("expected peer up notification, got {other:?}"),
        }
    }
}
