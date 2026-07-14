/*!
Provides parsing for BMP and OpenBMP binary-formatted messages.
*/
use crate::parser::bmp::error::ParserBmpError;
use crate::parser::bmp::messages::*;
pub use crate::parser::bmp::openbmp::parse_openbmp_header;
use crate::utils::ReadUtils;
use bytes::Bytes;

pub mod error;
pub mod messages;
pub mod openbmp;

/// Parse OpenBMP `raw_bmp` message.
///
/// An OpenBMP `raw_bmp` message contains a [OpenBmpHeader][OpenBmpHeader] and a [BmpMessage].
///
/// [OpenBmpHeader]: crate::parser::bmp::openbmp::OpenBmpHeader
pub fn parse_openbmp_msg(mut data: Bytes) -> Result<BmpMessage, ParserBmpError> {
    let _header = parse_openbmp_header(&mut data)?;
    parse_bmp_msg(&mut data)
}

/// Parse a BMP message.
pub fn parse_bmp_msg(data: &mut Bytes) -> Result<BmpMessage, ParserBmpError> {
    let common_header = parse_bmp_common_header(data)?;

    let msg_len = common_header.msg_len as usize;
    if msg_len < 6 {
        return Err(ParserBmpError::CorruptedBmpMessage);
    }
    let content_length = msg_len - 6;
    data.has_n_remaining(content_length)?;
    let mut content = data.split_to(content_length);

    match &common_header.msg_type {
        BmpMsgType::RouteMonitoring => {
            let per_peer_header = parse_per_peer_header(&mut content)?;
            let msg = parse_route_monitoring(
                &mut content,
                &per_peer_header.asn_length(),
                Some(&per_peer_header.peer_type),
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
            let msg = parse_peer_up_notification(
                &mut content,
                &per_peer_header.afi(),
                &per_peer_header.asn_length(),
                Some(&per_peer_header.peer_type),
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

#[cfg(test)]
#[allow(unused_variables)]
mod tests {
    use super::*;
    use crate::parser::bmp::openbmp::parse_openbmp_header;

    #[test]
    fn test_peer_down_notification() {
        let input = "4f424d500107006400000033800c6184b9c2000c602cbf4f072f3ae149d23486024bc3dadfc4000a69732d63632d626d7031c677060bdd020a9e92be000200de2e3180df3369000000000000000000000000000c726f7574652d76696577733500000001030000003302000000000000000000000000000000000000000000003fda060e00000da30000000061523c36000c0e1c0200000a";
        let decoded = hex::decode(input).unwrap();
        let mut data = Bytes::from(decoded);
        let _header = parse_openbmp_header(&mut data).unwrap();
        let _msg = parse_bmp_msg(&mut data).unwrap();
    }

    #[test]
    fn test_route_monitoring() {
        let input = "4f424d500107005c000000b0800c618881530002f643fef880938d19e9d632c815d1e95a87e1000a69732d61682d626d7031eb4de4e596b282c6a995b067df4abc8cc342f19200000000000000000000000000046c696e780000000103000000b00000c00000000000000000200107f800040000000000001aae000400001aae5474800e02dddf5d00000000ffffffffffffffffffffffffffffffff00800200000069400101005002001602050000192f00001aae0000232a000328eb00032caec008181aae42681aae44581aae464f1aae59d91aae866543000000900e002c00020120200107f800040000000000001aae0004fe8000000000000082711ffffe7f29f100302a0fca8000010a";
        let decoded = hex::decode(input).unwrap();
        let mut data = Bytes::from(decoded);
        let _header = parse_openbmp_header(&mut data).unwrap();
        let _msg = parse_bmp_msg(&mut data).unwrap();
    }

    #[test]
    fn parse_peer_up_notification() {}
}
