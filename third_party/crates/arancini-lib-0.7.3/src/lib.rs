pub mod processor;
pub mod sender;
pub mod state;
pub mod state_store;
pub mod update;

use anyhow::Result;
use bgpkit_parser::parser::bmp::messages::BmpMessageBody;
use bytes::Bytes;
use metrics::counter;
use std::net::SocketAddr;
use tracing::{debug, trace};

use crate::processor::{
    decode_bmp_message, peer_down_notification, peer_up_notification, route_monitoring,
};
use crate::sender::UpdateSender;
use crate::state::AsyncState;
use crate::state_store::store::StateStore;
use crate::update::new_metadata;

/// Process a BMP message from raw bytes
/// This is a convenience wrapper for BMP collectors
pub async fn process_bmp_message<T: StateStore, S: UpdateSender>(
    state: Option<AsyncState<T>>,
    tx: S,
    socket: SocketAddr,
    bytes: &mut Bytes,
) -> Result<()> {
    // Parse the BMP message
    let message = match decode_bmp_message(bytes) {
        Ok(message) => message,
        Err(e) => {
            anyhow::bail!("failed to decode BMP message: {}", e);
        }
    };

    trace!("{} - {:?}", socket, message);

    // Extract header and peer information
    let metadata = new_metadata(socket, &message);

    let metric_name = "risotto_bmp_messages_total";
    match message.message_body {
        BmpMessageBody::InitiationMessage(body) => {
            trace!("{}: {:?}", socket, body);
            let tlvs_info = body
                .tlvs
                .iter()
                .map(|tlv| tlv.info.clone())
                .collect::<Vec<_>>();
            debug!("{}: InitiationMessage: {:?}", socket, tlvs_info);
            counter!(metric_name, "router" =>  socket.ip().to_string(), "type" => "initiation")
                .increment(1);
            // No-Op
        }
        BmpMessageBody::PeerUpNotification(body) => {
            trace!("{}: {:?}", socket, body);
            if metadata.is_none() {
                anyhow::bail!("{}: PeerUpNotification: no per-peer header", socket);
            }
            let metadata = metadata.unwrap();
            debug!("{}: PeerUpNotification: {}", socket, metadata.peer_addr);
            counter!(metric_name, "router" =>  socket.ip().to_string(), "type" => "peer_up_notification")
                .increment(1);
            peer_up_notification(state, tx, metadata, body).await?;
        }
        BmpMessageBody::RouteMonitoring(body) => {
            trace!("{}: {:?}", socket, body);
            if metadata.is_none() {
                anyhow::bail!("{}: RouteMonitoring - no per-peer header", socket);
            }
            let metadata = metadata.unwrap();
            // We do not process the message if the peer address is unspecified
            // Most likely a local RIB update
            if !metadata.peer_addr.is_unspecified() {
                counter!(metric_name, "router" =>  socket.ip().to_string(), "type" => "route_monitoring")
                .increment(1);
                route_monitoring(state, tx, metadata, body).await?;
            }
        }
        BmpMessageBody::RouteMirroring(body) => {
            trace!("{}: {:?}", socket, body);
            debug!("{}: RouteMirroring", socket);
            counter!(metric_name, "router" =>  socket.ip().to_string(), "type" => "route_mirroring")
                .increment(1);
            // No-Op
        }
        BmpMessageBody::PeerDownNotification(body) => {
            trace!("{}: {:?}", socket, body);
            if metadata.is_none() {
                anyhow::bail!("{}: PeerDownNotification: no per-peer header", socket);
            }
            let metadata = metadata.unwrap();
            debug!(
                "{}: PeerDownNotification: {}. Reason: {:?}",
                socket, metadata.peer_addr, body.reason
            );
            counter!(metric_name, "router" =>  socket.ip().to_string(), "type" => "peer_down_notification")
                .increment(1);
            peer_down_notification(state, tx, metadata, body).await?;
        }

        BmpMessageBody::TerminationMessage(body) => {
            trace!("{}: {:?}", socket, body);
            debug!("{}: TerminationMessage", socket);
            counter!(metric_name, "router" =>  socket.ip().to_string(), "type" => "termination")
                .increment(1);
            // No-Op
        }
        BmpMessageBody::StatsReport(body) => {
            trace!("{}: {:?}", socket, body);
            debug!("{}: StatsReport", socket);
            counter!(metric_name, "router" =>  socket.ip().to_string(), "type" => "stats_report")
                .increment(1);
            // No-Op
        }
    };

    Ok(())
}
