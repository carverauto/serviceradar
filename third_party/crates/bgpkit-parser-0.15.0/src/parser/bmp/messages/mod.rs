//! BMP message parsing.
//!
//! <https://datatracker.ietf.org/doc/html/rfc7854>

pub use headers::*;
pub use initiation_message::*;
pub use peer_down_notification::*;
pub use peer_up_notification::*;
pub use route_mirroring::*;
pub use route_monitoring::*;
pub use stats_report::*;
pub use termination_message::*;

pub(crate) mod headers;
pub(crate) mod initiation_message;
pub(crate) mod peer_down_notification;
pub(crate) mod peer_up_notification;
pub(crate) mod route_mirroring;
pub(crate) mod route_monitoring;
pub(crate) mod stats_report;
pub(crate) mod termination_message;

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BmpMessage {
    pub common_header: BmpCommonHeader,
    pub per_peer_header: Option<BmpPerPeerHeader>,
    pub message_body: BmpMessageBody,
}

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum BmpMessageBody {
    PeerUpNotification(PeerUpNotification),
    PeerDownNotification(PeerDownNotification),
    InitiationMessage(InitiationMessage),
    TerminationMessage(TerminationMessage),
    RouteMonitoring(RouteMonitoring),
    RouteMirroring(RouteMirroring),
    StatsReport(StatsReport),
}
