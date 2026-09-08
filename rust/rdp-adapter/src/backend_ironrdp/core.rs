use crate::backend::{BackendError, RdpBackend, RdpBackendSession};
#[cfg(serviceradar_rdp_connector_link_probe)]
use crate::media_frame::{
    encode_desktop_media_frame, DesktopMediaFrame, DesktopMediaPayloadFamily,
};
#[cfg(serviceradar_rdp_connector_link_probe)]
use crate::protocol::{parse_open_payload, DesktopClosePayload};
use crate::protocol::{DesktopCredentialGrant, OpenPayload};
#[cfg(serviceradar_rdp_connector_link_probe)]
use crate::protocol::{DesktopFrame, DesktopScreenPolicy};
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::collections::VecDeque;
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::io::{self, Read, Write};
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::sync::Arc;
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::time::Duration;
use zeroize::Zeroizing;

const CONNECTOR_NOT_IMPLEMENTED: &str =
    "IronRDP backend is linked, but live auth/media/demo validation is incomplete";
const ACTIVE_SESSION_TERMINATED: &str =
    "IronRDP active session entered a terminated or unsupported control state";
const MEMORY_USER_REQUIRED: &str =
    "IronRDP backend currently requires a memory-user credential grant";
const INVALID_CONNECTION_PLAN: &str = "IronRDP connection plan is invalid";
#[cfg(serviceradar_rdp_connector_link_probe)]
const INVALID_TLS_CA_BUNDLE: &str = "IronRDP TLS CA bundle is invalid";
const TLS_MODE_PINNED_CA: &str = "pinned_ca";
const TLS_MODE_VERIFY: &str = "verify";
const TLS_MODE_SYSTEM: &str = "system";
#[cfg(serviceradar_rdp_connector_link_probe)]
const UNSUPPORTED_INPUT_EVENT: &str = "IronRDP input event is unsupported";
#[cfg(serviceradar_rdp_connector_link_probe)]
const INVALID_GRAPHICS_UPDATE: &str = "IronRDP graphics update is invalid";
const MAX_DIAL_HOST_LEN: usize = 253;
#[cfg(serviceradar_rdp_connector_link_probe)]
const DEFAULT_CONNECTOR_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(serviceradar_rdp_connector_link_probe)]
const MAX_CONNECTOR_STAGE_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(serviceradar_rdp_connector_link_probe)]
const DEFAULT_KDC_PORT: u16 = 88;
#[cfg(serviceradar_rdp_connector_link_probe)]
const MAX_KDC_RESPONSE_BYTES: u32 = 64 * 1024;
const METADATA_KDC_PROXY_URL: &str = "rdp.kdc_proxy_url";
const METADATA_KERBEROS_HOSTNAME: &str = "rdp.kerberos_hostname";
#[cfg(serviceradar_rdp_connector_link_probe)]
const METADATA_DIAL_TIMEOUT_MS: &str = "rdp.dial_timeout_ms";
#[cfg(serviceradar_rdp_connector_link_probe)]
const METADATA_KDC_TIMEOUT_MS: &str = "rdp.kdc_timeout_ms";
#[cfg(serviceradar_rdp_connector_link_probe)]
const METADATA_MEDIA_SESSION_ID: &str = "media_session_id";
