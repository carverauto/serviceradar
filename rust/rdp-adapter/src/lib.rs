mod backend;
#[cfg(feature = "ironrdp-backend")]
mod backend_ironrdp;
#[cfg(serviceradar_rdp_connector_link_probe)]
mod connector_link_probe;
mod error;
mod media_frame;
mod process_hardening;
mod protocol;
mod runtime;
mod wire;

use std::io::{self, Write};

pub use backend::{BackendError, RdpBackend, RdpBackendSession, UnavailableBackend};
#[cfg(feature = "ironrdp-backend")]
pub use backend_ironrdp::IronRdpBackend;
#[cfg(all(feature = "ironrdp-backend", serviceradar_rdp_connector_link_probe))]
pub use backend_ironrdp::run_live_helper_open_probe_from_env;
#[cfg(serviceradar_rdp_connector_link_probe)]
pub use connector_link_probe::connector_link_probe_capabilities;
pub use error::ProtocolError;
pub use protocol::{
    DesktopClosePayload, DesktopFrame, DesktopMediaAck, OpenPayload, parse_open_payload,
};
pub use runtime::{
    run_stdio, run_stdio_pumped, run_stdio_with_backend, run_stdio_with_backend_pump,
};

#[cfg(test)]
pub(crate) use runtime::{
    parse_and_clear_ack_payload, parse_and_clear_close_payload, parse_and_clear_input_payload,
    parse_and_clear_open_payload,
};
#[cfg(test)]
pub(crate) use wire::{
    Frame, MAX_CONTROL_FRAME_LENGTH, MAX_FRAME_LENGTH, MSG_ACK, MSG_CLOSE, MSG_ERROR, MSG_INPUT,
    MSG_MEDIA_FRAME, MSG_OPEN, read_frame, write_frame,
};

pub const HELPER_CAPABILITIES_ARG: &str = "--capabilities";
pub const HELPER_CAPABILITIES_SCHEMA: &str = "serviceradar.rdp.helper.capabilities.v1";
pub const HELPER_PROTOCOL_VERSION: u32 = 1;
pub const HELPER_CONNECTOR_NOT_READY_REASON: &str = "live_auth_media_demo_not_validated";
pub const HELPER_BACKEND_NOT_LINKED_REASON: &str = "ironrdp_backend_not_linked";

pub fn harden_process_for_secrets() -> io::Result<()> {
    process_hardening::harden_process_for_secrets()
}

pub fn write_capabilities<W>(writer: &mut W) -> io::Result<()>
where
    W: Write,
{
    let ironrdp_backend_linked = cfg!(feature = "ironrdp-backend");
    let connector_ready = cfg!(all(
        feature = "ironrdp-backend",
        serviceradar_rdp_connector_link_probe
    ));

    if connector_ready {
        return writeln!(
            writer,
            "{{\"schema\":\"{}\",\"protocol\":\"rdp\",\"helper_protocol_version\":{},\"ironrdp_backend_linked\":true,\"connector_ready\":true}}",
            HELPER_CAPABILITIES_SCHEMA, HELPER_PROTOCOL_VERSION
        );
    }

    let connector_ready_reason = if ironrdp_backend_linked {
        HELPER_CONNECTOR_NOT_READY_REASON
    } else {
        HELPER_BACKEND_NOT_LINKED_REASON
    };

    writeln!(
        writer,
        "{{\"schema\":\"{}\",\"protocol\":\"rdp\",\"helper_protocol_version\":{},\"ironrdp_backend_linked\":{},\"connector_ready\":false,\"connector_ready_reason\":\"{}\"}}",
        HELPER_CAPABILITIES_SCHEMA,
        HELPER_PROTOCOL_VERSION,
        ironrdp_backend_linked,
        connector_ready_reason
    )
}

#[cfg(test)]
mod lib_tests;
