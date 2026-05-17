use crate::backend::{BackendError, RdpBackend, RdpBackendSession};
#[cfg(serviceradar_rdp_connector_link_probe)]
use crate::media_frame::{
    encode_desktop_media_frame, DesktopMediaFrame, DesktopMediaPayloadFamily,
};
#[cfg(serviceradar_rdp_connector_link_probe)]
use crate::protocol::DesktopClosePayload;
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
    "IronRDP backend is linked, but the connector loop is not implemented";
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
#[cfg(serviceradar_rdp_connector_link_probe)]
const MAX_DIAL_HOST_LEN: usize = 253;

#[derive(Debug, Eq, PartialEq)]
struct NonSecretConnectionPlan {
    upstream_host: String,
    upstream_port: u16,
    tls_server_name: String,
    tls_trust_source: TlsTrustSource,
    desktop_width: u16,
    desktop_height: u16,
}

#[derive(Debug, Eq, PartialEq)]
enum TlsTrustSource {
    SystemRoots,
    RegisteredCaBundle { id: String, pem: String },
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ConnectorUpgradeBoundaryProbe {
    requires_security_upgrade: bool,
    requires_credssp_after_upgrade: bool,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct BlockingConnectBeginProbe {
    requires_security_upgrade: bool,
    contains_cleartext_password: bool,
    written_bytes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct BlockingConnectFinalizeProbe {
    wrote_credssp_bytes: bool,
    contains_cleartext_password: bool,
    written_bytes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorBeginHandoff<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    should_upgrade: ironrdp_blocking::ShouldUpgrade,
    connector: ironrdp_connector::ClientConnector,
    dial_target: ConnectorDialTarget,
    tls_config: VerifiedTlsClientConfig,
    server_name: ironrdp_connector::ServerName,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> ConnectorBeginHandoff<S> {
    fn requires_security_upgrade(&self) -> bool {
        let _should_upgrade = &self.should_upgrade;

        self.connector.should_perform_security_upgrade()
    }

    fn tls_probe(&self) -> VerifiedTlsClientConfigProbe {
        self.tls_config.probe()
    }

    fn server_name(&self) -> &str {
        self.server_name.as_str()
    }

    fn client_addr(&self) -> SocketAddr {
        self.connector.client_addr
    }

    fn remote_endpoint(&self) -> &str {
        self.dial_target.endpoint.as_str()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorCredsspHandoff<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    upgraded: ironrdp_blocking::Upgraded,
    connector: ironrdp_connector::ClientConnector,
    server_name: ironrdp_connector::ServerName,
    server_public_key: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> ConnectorCredsspHandoff<S> {
    fn requires_credssp(&self) -> bool {
        self.connector.should_perform_credssp()
    }

    fn server_name(&self) -> &str {
        self.server_name.as_str()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorFinalizedHandoff<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    connection_result: ironrdp_connector::ConnectionResult,
    desktop_size: ironrdp_connector::DesktopSize,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> ConnectorFinalizedHandoff<S> {
    #[allow(clippy::too_many_arguments)]
    fn into_network_pump_session<W: Write>(
        self,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
        timestamp_unix_nano: i64,
    ) -> ActiveStageNetworkPumpSessionProbe<S, W> {
        ActiveStageNetworkPumpSessionProbe::from_connection_result(
            self.framed,
            self.connection_result,
            self.desktop_size,
            upstream,
            policy,
            session_binding_id,
            media_session_id,
            timestamp_unix_nano,
        )
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorFinalizeFailure<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    error: BackendError,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct VerifiedTlsClientConfigProbe {
    trusted_root_count: usize,
    resumption_disabled_for_credssp: bool,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct VerifiedTlsClientConfig {
    config: rustls::ClientConfig,
    trusted_root_count: usize,
    resumption_disabled_for_credssp: bool,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl VerifiedTlsClientConfig {
    fn probe(&self) -> VerifiedTlsClientConfigProbe {
        let _client_config = &self.config;

        VerifiedTlsClientConfigProbe {
            trusted_root_count: self.trusted_root_count,
            resumption_disabled_for_credssp: self.resumption_disabled_for_credssp,
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ActiveStageInputProbe {
    response_frames: usize,
    response_bytes: usize,
    graphics_updates: usize,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ActiveStageOutputProbe {
    rdp_response_frames: usize,
    rdp_response_bytes: usize,
    queued_media_frames: usize,
    queued_media_bytes: usize,
    terminal_outputs: usize,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ActiveStageSessionProbe<W: Write> {
    active_stage: ironrdp_session::ActiveStage,
    image: ironrdp_session::image::DecodedImage,
    upstream: W,
    media_queue: VecDeque<Vec<u8>>,
    policy: DesktopScreenPolicy,
    session_binding_id: String,
    media_session_id: String,
    next_sequence: u64,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<W: Write> ActiveStageSessionProbe<W> {
    fn new(
        plan: &NonSecretConnectionPlan,
        credential: &MemoryUserCredential,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
    ) -> Self {
        let (connection_result, desktop_size) = build_connection_result_for_probe(plan, credential);

        Self::from_connection_result(
            connection_result,
            desktop_size,
            upstream,
            policy,
            session_binding_id,
            media_session_id,
        )
    }

    fn from_connection_result(
        connection_result: ironrdp_connector::ConnectionResult,
        desktop_size: ironrdp_connector::DesktopSize,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
    ) -> Self {
        let active_stage = ironrdp_session::ActiveStage::new(connection_result);
        let image = ironrdp_session::image::DecodedImage::new(
            ironrdp_graphics::image_processing::PixelFormat::RgbA32,
            desktop_size.width,
            desktop_size.height,
        );

        Self {
            active_stage,
            image,
            upstream,
            media_queue: VecDeque::new(),
            policy: copy_screen_policy_for_probe(policy),
            session_binding_id,
            media_session_id,
            next_sequence: 0,
        }
    }

    fn input(&mut self, frame: &DesktopFrame) -> Result<ActiveStageOutputProbe, BackendError> {
        let events = map_desktop_input_events_for_probe(frame)?;
        let outputs = self
            .active_stage
            .process_fastpath_input(&mut self.image, &events)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        handle_active_stage_outputs_for_probe(
            outputs,
            &mut self.upstream,
            &mut self.media_queue,
            &self.image,
            &self.policy,
            &self.session_binding_id,
            &self.media_session_id,
            &mut self.next_sequence,
            frame.timestamp,
        )
    }

    fn graceful_shutdown(&mut self) -> Result<ActiveStageOutputProbe, BackendError> {
        let outputs = self
            .active_stage
            .graceful_shutdown()
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        handle_active_stage_outputs_for_probe(
            outputs,
            &mut self.upstream,
            &mut self.media_queue,
            &self.image,
            &self.policy,
            &self.session_binding_id,
            &self.media_session_id,
            &mut self.next_sequence,
            0,
        )
    }

    fn server_frame(
        &mut self,
        action: ironrdp_pdu::Action,
        frame: &[u8],
        timestamp_unix_nano: i64,
    ) -> Result<ActiveStageOutputProbe, BackendError> {
        let outputs = self
            .active_stage
            .process(&mut self.image, action, frame)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        handle_active_stage_outputs_for_probe(
            outputs,
            &mut self.upstream,
            &mut self.media_queue,
            &self.image,
            &self.policy,
            &self.session_binding_id,
            &self.media_session_id,
            &mut self.next_sequence,
            timestamp_unix_nano,
        )
    }

    fn drain_media_frames(&mut self) -> Vec<Vec<u8>> {
        self.media_queue.drain(..).collect()
    }

    fn upstream_ref(&self) -> &W {
        &self.upstream
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<W: Write> RdpBackendSession for ActiveStageSessionProbe<W> {
    fn input(&mut self, frame: &DesktopFrame) -> Result<(), BackendError> {
        ActiveStageSessionProbe::input(self, frame).map(|_| ())
    }

    fn ack(&mut self, _ack: &crate::protocol::DesktopMediaAck) -> Result<(), BackendError> {
        Ok(())
    }

    fn close(&mut self, _payload: &DesktopClosePayload) -> Result<(), BackendError> {
        ActiveStageSessionProbe::graceful_shutdown(self).map(|_| ())
    }

    fn drain_media_frames(&mut self) -> Result<Vec<Vec<u8>>, BackendError> {
        Ok(ActiveStageSessionProbe::drain_media_frames(self))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ActiveStageNetworkPumpSessionProbe<S: Read, W: Write> {
    framed: ironrdp_blocking::Framed<S>,
    inner: ActiveStageSessionProbe<W>,
    timestamp_unix_nano: i64,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read, W: Write> ActiveStageNetworkPumpSessionProbe<S, W> {
    fn new(
        framed: ironrdp_blocking::Framed<S>,
        inner: ActiveStageSessionProbe<W>,
        timestamp_unix_nano: i64,
    ) -> Self {
        Self {
            framed,
            inner,
            timestamp_unix_nano,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn from_connection_result(
        framed: ironrdp_blocking::Framed<S>,
        connection_result: ironrdp_connector::ConnectionResult,
        desktop_size: ironrdp_connector::DesktopSize,
        upstream: W,
        policy: &DesktopScreenPolicy,
        session_binding_id: String,
        media_session_id: String,
        timestamp_unix_nano: i64,
    ) -> Self {
        let inner = ActiveStageSessionProbe::from_connection_result(
            connection_result,
            desktop_size,
            upstream,
            policy,
            session_binding_id,
            media_session_id,
        );

        Self::new(framed, inner, timestamp_unix_nano)
    }

    fn drain_media_frames(&mut self) -> Vec<Vec<u8>> {
        self.inner.drain_media_frames()
    }

    fn upstream_ref(&self) -> &W {
        self.inner.upstream_ref()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read, W: Write> RdpBackendSession for ActiveStageNetworkPumpSessionProbe<S, W> {
    fn input(&mut self, frame: &DesktopFrame) -> Result<(), BackendError> {
        self.inner.input(frame).map(|_| ())
    }

    fn ack(&mut self, _ack: &crate::protocol::DesktopMediaAck) -> Result<(), BackendError> {
        Ok(())
    }

    fn close(&mut self, payload: &DesktopClosePayload) -> Result<(), BackendError> {
        self.inner.close(payload)
    }

    fn pump(&mut self) -> Result<(), BackendError> {
        read_active_stage_server_frame_for_probe(
            &mut self.framed,
            &mut self.inner,
            self.timestamp_unix_nano,
        )
        .map(|_| ())
    }

    fn drain_media_frames(&mut self) -> Result<Vec<Vec<u8>>, BackendError> {
        Ok(ActiveStageNetworkPumpSessionProbe::drain_media_frames(self))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct VerifiedTlsPeerPublicKeyForProbe {
    bytes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ExperimentalConnectorOpenPreflight {
    upstream_host: String,
    upstream_port: u16,
    upstream_endpoint: String,
    tls_server_name: String,
    desktop_width: u16,
    desktop_height: u16,
    domain: Option<String>,
    username: String,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct ConnectorDialTarget {
    host: String,
    port: u16,
    endpoint: String,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct DialedConnectorStream<S: Read + Write> {
    stream: S,
    client_addr: SocketAddr,
    dial_target: ConnectorDialTarget,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write> DialedConnectorStream<S> {
    fn endpoint(&self) -> &str {
        self.dial_target.endpoint.as_str()
    }

    fn client_addr(&self) -> SocketAddr {
        self.client_addr
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl VerifiedTlsPeerPublicKeyForProbe {
    fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}

struct MemoryUserCredential {
    domain: Option<Zeroizing<String>>,
    username: Zeroizing<String>,
    password: RedactedSecret,
}

struct RedactedSecret {
    value: Zeroizing<String>,
}

impl MemoryUserCredential {
    fn has_material(&self) -> bool {
        !self.username.is_empty() && !self.password.value.is_empty()
    }

    fn connector_identity(&self) -> (Option<&str>, &str) {
        (
            self.domain.as_ref().map(|domain| domain.as_str()),
            self.username.as_str(),
        )
    }
}

impl std::fmt::Debug for MemoryUserCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryUserCredential")
            .field("domain", &"<redacted>")
            .field("username", &"<redacted>")
            .field("password", &self.password)
            .finish()
    }
}

impl std::fmt::Debug for RedactedSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}

#[derive(Default)]
pub struct IronRdpBackend;

impl RdpBackend for IronRdpBackend {
    fn open(&mut self, request: OpenPayload) -> Result<Box<dyn RdpBackendSession>, BackendError> {
        let Some(grant) = request.credential_grant.as_ref() else {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        };
        if !is_memory_user_grant(grant) {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let plan = build_nonsecret_connection_plan(&request)?;
        let credential = build_memory_user_credential(grant)?;
        if !credential.has_material() {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let _connector_identity = credential.connector_identity();
        #[cfg(serviceradar_rdp_connector_link_probe)]
        prepare_connector_open_for_experimental(&plan, &credential)?;

        // Keep connector readiness false until the real IronRDP loop consumes
        // only zeroizing credential wrappers and proves cleanup ordering.
        Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn prepare_connector_open_for_experimental(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<(), BackendError> {
    let _verified_tls = build_verified_tls_client_config_for_plan(plan)?;
    let _preflight = build_connector_config_preflight_for_experimental(plan, credential)?;

    Ok(())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_config_preflight_for_experimental(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<ExperimentalConnectorOpenPreflight, BackendError> {
    let (domain, username) = credential.connector_identity();
    let dial_target = build_connector_dial_target_for_plan(plan)?;
    if username.trim().is_empty()
        || credential.password.value.is_empty()
        || plan.tls_server_name.trim().is_empty()
        || plan.desktop_width == 0
        || plan.desktop_height == 0
    {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(ExperimentalConnectorOpenPreflight {
        upstream_host: dial_target.host,
        upstream_port: dial_target.port,
        upstream_endpoint: dial_target.endpoint,
        tls_server_name: plan.tls_server_name.clone(),
        desktop_width: plan.desktop_width,
        desktop_height: plan.desktop_height,
        domain: domain.map(str::to_owned),
        username: username.to_owned(),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_dial_target_for_plan(
    plan: &NonSecretConnectionPlan,
) -> Result<ConnectorDialTarget, BackendError> {
    let host = plan.upstream_host.trim();
    if host.is_empty()
        || host.len() > MAX_DIAL_HOST_LEN
        || host
            .chars()
            .any(|ch| ch.is_ascii_control() || ch.is_whitespace())
    {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    let endpoint = match host.parse::<IpAddr>() {
        Ok(IpAddr::V6(_)) => format!("[{host}]:{}", plan.upstream_port),
        _ => format!("{host}:{}", plan.upstream_port),
    };

    Ok(ConnectorDialTarget {
        host: host.to_owned(),
        port: plan.upstream_port,
        endpoint,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn dial_connector_tcp_for_probe(
    plan: &NonSecretConnectionPlan,
    timeout: Duration,
) -> Result<DialedConnectorStream<TcpStream>, BackendError> {
    let dial_target = build_connector_dial_target_for_plan(plan)?;
    let mut addresses = dial_target
        .endpoint
        .to_socket_addrs()
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let remote_addr = addresses
        .next()
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let stream = TcpStream::connect_timeout(&remote_addr, timeout)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let client_addr = stream
        .local_addr()
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(DialedConnectorStream {
        stream,
        client_addr,
        dial_target,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connector_config_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> ironrdp_connector::Config {
    let (domain, username) = credential.connector_identity();

    ironrdp_connector::Config {
        desktop_size: ironrdp_connector::DesktopSize {
            width: plan.desktop_width,
            height: plan.desktop_height,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: ironrdp_connector::Credentials::UsernamePassword {
            username: username.to_owned(),
            password: credential.password.value.as_str().to_owned(),
        },
        domain: domain.map(str::to_owned),
        client_build: 1,
        client_name: "serviceradar".to_owned(),
        keyboard_type: ironrdp_pdu::gcc::KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        platform: ironrdp_pdu::rdp::capability_sets::MajorPlatformType::UNIX,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        performance_flags: ironrdp_pdu::rdp::client_info::PerformanceFlags::default(),
        license_cache: None,
        timezone_info: ironrdp_pdu::rdp::client_info::TimezoneInfo::default(),
        enable_server_pointer: false,
        pointer_software_rendering: false,
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_initial_connector_pdu_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<Vec<u8>, BackendError> {
    let config = build_connector_config_for_probe(plan, credential);
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, default_connector_client_addr_for_probe());
    let mut buffer = ironrdp_core::WriteBuf::new();
    let written = ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let written_len = written
        .size()
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(buffer.filled()[..written_len].to_vec())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn decode_initial_connection_request_for_probe(
    bytes: &[u8],
) -> Result<ironrdp_pdu::nego::ConnectionRequest, BackendError> {
    let request = ironrdp_core::decode::<
        ironrdp_pdu::x224::X224<ironrdp_pdu::nego::ConnectionRequest>,
    >(bytes)
    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?
    .0;

    Ok(request)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_connector_to_upgrade_boundary_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<ConnectorUpgradeBoundaryProbe, BackendError> {
    let config = build_connector_config_for_probe(plan, credential);
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, default_connector_client_addr_for_probe());
    let mut initial = ironrdp_core::WriteBuf::new();
    ironrdp_connector::Sequence::step_no_input(&mut connector, &mut initial)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    let server_confirm = encode_server_confirm_for_probe(selected_protocol)?;
    let mut output = ironrdp_core::WriteBuf::new();
    ironrdp_connector::Sequence::step(&mut connector, &server_confirm, &mut output)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    let requires_security_upgrade = connector.should_perform_security_upgrade();
    connector.mark_security_upgrade_as_done();

    Ok(ConnectorUpgradeBoundaryProbe {
        requires_security_upgrade,
        requires_credssp_after_upgrade: connector.should_perform_credssp(),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_server_confirm_for_probe(
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<Vec<u8>, BackendError> {
    ironrdp_core::encode_vec(&ironrdp_pdu::x224::X224(
        ironrdp_pdu::nego::ConnectionConfirm::Response {
            flags: ironrdp_pdu::nego::ResponseFlags::empty(),
            protocol: selected_protocol,
        },
    ))
    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_blocking_connect_begin_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<BlockingConnectBeginProbe, BackendError> {
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let handoff = begin_connector_handoff_for_probe(
        plan,
        credential,
        ScriptedStream::new(vec![server_confirm]),
    )?;
    let requires_security_upgrade = handoff.requires_security_upgrade();
    let (stream, leftover) = handoff.framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    Ok(BlockingConnectBeginProbe {
        requires_security_upgrade,
        contains_cleartext_password: bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ),
        written_bytes: stream.writes,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    stream: S,
) -> Result<ConnectorBeginHandoff<S>, BackendError>
where
    S: Sync + Read + Write,
{
    begin_connector_handoff_with_client_addr_for_probe(
        plan,
        credential,
        stream,
        default_connector_client_addr_for_probe(),
    )
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_with_tcp_dial_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    timeout: Duration,
) -> Result<ConnectorBeginHandoff<TcpStream>, BackendError> {
    let dialed = dial_connector_tcp_for_probe(plan, timeout)?;

    begin_connector_handoff_with_dialed_stream_for_probe(plan, credential, dialed)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_with_client_addr_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    stream: S,
    client_addr: SocketAddr,
) -> Result<ConnectorBeginHandoff<S>, BackendError>
where
    S: Sync + Read + Write,
{
    let dialed = prepare_dialed_connector_stream_for_probe(plan, stream, client_addr)?;

    begin_connector_handoff_with_dialed_stream_for_probe(plan, credential, dialed)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn prepare_dialed_connector_stream_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    stream: S,
    client_addr: SocketAddr,
) -> Result<DialedConnectorStream<S>, BackendError>
where
    S: Read + Write,
{
    Ok(DialedConnectorStream {
        stream,
        client_addr,
        dial_target: build_connector_dial_target_for_plan(plan)?,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn begin_connector_handoff_with_dialed_stream_for_probe<S>(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    dialed: DialedConnectorStream<S>,
) -> Result<ConnectorBeginHandoff<S>, BackendError>
where
    S: Sync + Read + Write,
{
    let config = build_connector_config_for_probe(plan, credential);
    let tls_config = build_verified_tls_client_config_for_plan(plan)?;
    let server_name = ironrdp_connector::ServerName::from(&plan.tls_server_name);
    let DialedConnectorStream {
        stream,
        client_addr,
        dial_target,
    } = dialed;
    let mut connector = ironrdp_connector::ClientConnector::new(config, client_addr);
    let mut framed = ironrdp_blocking::Framed::new(stream);

    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(ConnectorBeginHandoff {
        framed,
        should_upgrade,
        connector,
        dial_target,
        tls_config,
        server_name,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn default_connector_client_addr_for_probe() -> SocketAddr {
    "127.0.0.1:0".parse().expect("loopback")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_blocking_connect_finalize_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    server_public_key: VerifiedTlsPeerPublicKeyForProbe,
) -> Result<BlockingConnectFinalizeProbe, BackendError> {
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let handoff = begin_connector_handoff_for_probe(
        plan,
        credential,
        ScriptedStream::new(vec![server_confirm]),
    )?;
    let (stream, leftover) = handoff.framed.get_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let initial_write_len = stream.writes.len();
    let credssp_handoff =
        mark_connector_handoff_tls_upgraded_for_probe(handoff, server_public_key)?;
    let mut network_client = RejectingNetworkClient;
    let failure = match finalize_connector_handoff_for_probe(credssp_handoff, &mut network_client) {
        Ok(_) => return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED)),
        Err(failure) => failure,
    };
    let (stream, leftover) = failure.framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }
    if failure.error != BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED) {
        return Err(failure.error);
    }

    Ok(BlockingConnectFinalizeProbe {
        wrote_credssp_bytes: stream.writes.len() > initial_write_len,
        contains_cleartext_password: bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ),
        written_bytes: stream.writes,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn finalize_connector_handoff_for_probe<S, N>(
    handoff: ConnectorCredsspHandoff<S>,
    network_client: &mut N,
) -> Result<ConnectorFinalizedHandoff<S>, ConnectorFinalizeFailure<S>>
where
    S: Read + Write,
    N: ironrdp_connector::sspi::network_client::NetworkClient,
{
    let ConnectorCredsspHandoff {
        mut framed,
        upgraded,
        connector,
        server_name,
        server_public_key,
    } = handoff;

    match ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut framed,
        network_client,
        server_name,
        server_public_key,
        None,
    ) {
        Ok(connection_result) => {
            let desktop_size = connection_result.desktop_size;

            Ok(ConnectorFinalizedHandoff {
                framed,
                connection_result,
                desktop_size,
            })
        }
        Err(_) => Err(ConnectorFinalizeFailure {
            framed,
            error: BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED),
        }),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn mark_connector_handoff_tls_upgraded_for_probe<S>(
    handoff: ConnectorBeginHandoff<S>,
    server_public_key: VerifiedTlsPeerPublicKeyForProbe,
) -> Result<ConnectorCredsspHandoff<S>, BackendError>
where
    S: Read + Write,
{
    let server_public_key = server_public_key.into_bytes();
    if server_public_key.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let ConnectorBeginHandoff {
        framed,
        should_upgrade,
        mut connector,
        dial_target: _dial_target,
        tls_config: _tls_config,
        server_name,
    } = handoff;
    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);

    Ok(ConnectorCredsspHandoff {
        framed,
        upgraded,
        connector,
        server_name,
        server_public_key,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn upgrade_connector_handoff_tls_for_probe<S>(
    handoff: ConnectorBeginHandoff<S>,
) -> Result<ConnectorCredsspHandoff<rustls::StreamOwned<rustls::ClientConnection, S>>, BackendError>
where
    S: Read + Write,
{
    let ConnectorBeginHandoff {
        framed,
        should_upgrade,
        mut connector,
        dial_target: _dial_target,
        tls_config,
        server_name,
    } = handoff;
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let tls_server_name = rustls::pki_types::ServerName::try_from(server_name.as_str().to_owned())
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let client_config = Arc::new(tls_config.config);
    let client_connection = rustls::ClientConnection::new(client_config, tls_server_name)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let mut tls_stream = rustls::StreamOwned::new(client_connection, stream);
    while tls_stream.conn.is_handshaking() {
        tls_stream
            .conn
            .complete_io(&mut tls_stream.sock)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    }

    let peer_certificate = tls_stream
        .conn
        .peer_certificates()
        .and_then(|certificates| certificates.first())
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
        peer_certificate.as_ref(),
    )?
    .into_bytes();
    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);

    Ok(ConnectorCredsspHandoff {
        framed: ironrdp_blocking::Framed::new(tls_stream),
        upgraded,
        connector,
        server_name,
        server_public_key,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
    cert_der: &[u8],
) -> Result<VerifiedTlsPeerPublicKeyForProbe, BackendError> {
    use x509_cert::der::Decode as _;

    let cert = x509_cert::Certificate::from_der(cert_der)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let public_key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    if public_key.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    Ok(VerifiedTlsPeerPublicKeyForProbe {
        bytes: public_key.to_vec(),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_for_registered_ca_bundle(
    ca_bundle: &[u8],
) -> Result<VerifiedTlsClientConfig, BackendError> {
    let certificates = parse_registered_ca_bundle_for_probe(ca_bundle)?;

    build_verified_tls_client_config_from_certificates(certificates, INVALID_TLS_CA_BUNDLE)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_for_system_roots(
) -> Result<VerifiedTlsClientConfig, BackendError> {
    let native = rustls_native_certs::load_native_certs();
    if !native.errors.is_empty() {
        return Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    build_verified_tls_client_config_from_certificates(native.certs, INVALID_TLS_CA_BUNDLE)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_for_plan(
    plan: &NonSecretConnectionPlan,
) -> Result<VerifiedTlsClientConfig, BackendError> {
    match &plan.tls_trust_source {
        TlsTrustSource::SystemRoots => build_verified_tls_client_config_for_system_roots(),
        TlsTrustSource::RegisteredCaBundle { pem, .. } => {
            build_verified_tls_client_config_for_registered_ca_bundle(pem.as_bytes())
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_verified_tls_client_config_from_certificates(
    certificates: Vec<rustls::pki_types::CertificateDer<'static>>,
    error_message: &'static str,
) -> Result<VerifiedTlsClientConfig, BackendError> {
    let mut roots = rustls::RootCertStore::empty();
    let mut added = 0;

    for certificate in certificates {
        roots
            .add(certificate)
            .map_err(|_| BackendError::Unsupported(error_message))?;
        added += 1;
    }
    if added == 0 {
        return Err(BackendError::Unsupported(error_message));
    }

    let mut config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();

    Ok(VerifiedTlsClientConfig {
        config,
        trusted_root_count: added,
        resumption_disabled_for_credssp: true,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn parse_registered_ca_bundle_for_probe(
    ca_bundle: &[u8],
) -> Result<Vec<rustls::pki_types::CertificateDer<'static>>, BackendError> {
    let trimmed = trim_ascii_whitespace(ca_bundle);
    if trimmed.is_empty() {
        return Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    if trimmed
        .windows(b"-----BEGIN CERTIFICATE-----".len())
        .any(|window| window == b"-----BEGIN CERTIFICATE-----")
    {
        use rustls::pki_types::pem::PemObject as _;

        let mut certificates = Vec::new();
        for certificate in rustls::pki_types::CertificateDer::pem_slice_iter(trimmed) {
            certificates
                .push(certificate.map_err(|_| BackendError::Unsupported(INVALID_TLS_CA_BUNDLE))?);
        }
        if certificates.is_empty() {
            return Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
        }

        return Ok(certificates);
    }

    Ok(vec![rustls::pki_types::CertificateDer::from(
        trimmed.to_vec(),
    )])
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn trim_ascii_whitespace(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|byte| !byte.is_ascii_whitespace())
        .map_or(start, |position| position + 1);

    &bytes[start..end]
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_active_stage_keyboard_input_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<ActiveStageInputProbe, BackendError> {
    let frame = DesktopFrame {
        session_id: "session-1".to_owned(),
        protocol: "rdp".to_owned(),
        frame_type: "desktop.input".to_owned(),
        width: 0,
        height: 0,
        input: Some(crate::protocol::DesktopInputEvent {
            kind: "key".to_owned(),
            key: "Enter".to_owned(),
            down: true,
            button: String::new(),
            x: 0,
            y: 0,
            focused: false,
        }),
        quality: None,
        reason: String::new(),
        timestamp: 0,
        metadata: Default::default(),
    };

    encode_active_stage_desktop_input_for_probe(plan, credential, &frame)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_active_stage_desktop_input_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    frame: &DesktopFrame,
) -> Result<ActiveStageInputProbe, BackendError> {
    let (mut active_stage, desktop_size) = build_active_stage_for_probe(plan, credential);
    let mut image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        desktop_size.width,
        desktop_size.height,
    );
    let events = map_desktop_input_events_for_probe(frame)?;
    let outputs = active_stage
        .process_fastpath_input(&mut image, &events)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    Ok(summarize_active_stage_outputs_for_probe(outputs))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn read_active_stage_server_frame_for_probe<S: Read, W: Write>(
    framed: &mut ironrdp_blocking::Framed<S>,
    session: &mut ActiveStageSessionProbe<W>,
    timestamp_unix_nano: i64,
) -> Result<ActiveStageOutputProbe, BackendError> {
    let (action, frame) = framed
        .read_pdu()
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

    session.server_frame(action, &frame, timestamp_unix_nano)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn copy_screen_policy_for_probe(policy: &DesktopScreenPolicy) -> DesktopScreenPolicy {
    DesktopScreenPolicy {
        max_width: policy.max_width,
        max_height: policy.max_height,
        color_depth: policy.color_depth,
        frame_rate: policy.frame_rate,
        bitrate_bps: policy.bitrate_bps,
        idle_seconds: policy.idle_seconds,
        ttl_seconds: policy.ttl_seconds,
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn map_desktop_input_events_for_probe(
    frame: &DesktopFrame,
) -> Result<Vec<ironrdp_pdu::input::fast_path::FastPathInputEvent>, BackendError> {
    let Some(input) = frame.input.as_ref() else {
        return Err(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));
    };

    match input.kind.as_str() {
        "key" => {
            let scancode = browser_key_to_set1_scancode_for_probe(&input.key)
                .ok_or(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT))?;
            let mut flags = ironrdp_pdu::input::fast_path::KeyboardFlags::empty();
            if !input.down {
                flags |= ironrdp_pdu::input::fast_path::KeyboardFlags::RELEASE;
            }

            Ok(vec![
                ironrdp_pdu::input::fast_path::FastPathInputEvent::KeyboardEvent(flags, scancode),
            ])
        }
        "pointer" => {
            let mut flags = ironrdp_pdu::input::mouse::PointerFlags::MOVE;
            match input.button.as_str() {
                "" => {}
                "left" => flags |= ironrdp_pdu::input::mouse::PointerFlags::LEFT_BUTTON,
                "middle" => {
                    flags |= ironrdp_pdu::input::mouse::PointerFlags::MIDDLE_BUTTON_OR_WHEEL;
                }
                "right" => flags |= ironrdp_pdu::input::mouse::PointerFlags::RIGHT_BUTTON,
                _ => return Err(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT)),
            }
            if input.down && !input.button.is_empty() {
                flags |= ironrdp_pdu::input::mouse::PointerFlags::DOWN;
            }

            let x = u16::try_from(input.x)
                .map_err(|_| BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT))?;
            let y = u16::try_from(input.y)
                .map_err(|_| BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT))?;

            Ok(vec![
                ironrdp_pdu::input::fast_path::FastPathInputEvent::MouseEvent(
                    ironrdp_pdu::input::MousePdu {
                        flags,
                        number_of_wheel_rotation_units: 0,
                        x_position: x,
                        y_position: y,
                    },
                ),
            ])
        }
        "focus" => Ok(Vec::new()),
        _ => Err(BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT)),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn browser_key_to_set1_scancode_for_probe(key: &str) -> Option<u8> {
    Some(match key {
        "Escape" => 0x01,
        "1" => 0x02,
        "2" => 0x03,
        "3" => 0x04,
        "4" => 0x05,
        "5" => 0x06,
        "6" => 0x07,
        "7" => 0x08,
        "8" => 0x09,
        "9" => 0x0a,
        "0" => 0x0b,
        "-" => 0x0c,
        "=" => 0x0d,
        "Backspace" => 0x0e,
        "Tab" => 0x0f,
        "q" | "Q" => 0x10,
        "w" | "W" => 0x11,
        "e" | "E" => 0x12,
        "r" | "R" => 0x13,
        "t" | "T" => 0x14,
        "y" | "Y" => 0x15,
        "u" | "U" => 0x16,
        "i" | "I" => 0x17,
        "o" | "O" => 0x18,
        "p" | "P" => 0x19,
        "[" => 0x1a,
        "]" => 0x1b,
        "Enter" => 0x1c,
        "a" | "A" => 0x1e,
        "s" | "S" => 0x1f,
        "d" | "D" => 0x20,
        "f" | "F" => 0x21,
        "g" | "G" => 0x22,
        "h" | "H" => 0x23,
        "j" | "J" => 0x24,
        "k" | "K" => 0x25,
        "l" | "L" => 0x26,
        ";" => 0x27,
        "'" => 0x28,
        "`" => 0x29,
        "\\" => 0x2b,
        "z" | "Z" => 0x2c,
        "x" | "X" => 0x2d,
        "c" | "C" => 0x2e,
        "v" | "V" => 0x2f,
        "b" | "B" => 0x30,
        "n" | "N" => 0x31,
        "m" | "M" => 0x32,
        "," => 0x33,
        "." => 0x34,
        "/" => 0x35,
        " " | "Space" => 0x39,
        _ => return None,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_active_stage_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> (ironrdp_session::ActiveStage, ironrdp_connector::DesktopSize) {
    let (connection_result, desktop_size) = build_connection_result_for_probe(plan, credential);

    (
        ironrdp_session::ActiveStage::new(connection_result),
        desktop_size,
    )
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn build_connection_result_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> (
    ironrdp_connector::ConnectionResult,
    ironrdp_connector::DesktopSize,
) {
    let config = build_connector_config_for_probe(plan, credential);
    let desktop_size = config.desktop_size;
    let connector = ironrdp_connector::ClientConnector::new(
        config.clone(),
        default_connector_client_addr_for_probe(),
    );
    let connection_activation =
        ironrdp_connector::connection_activation::ConnectionActivationSequence::new(
            config, 1003, 1004,
        );
    let connection_result = ironrdp_connector::ConnectionResult {
        io_channel_id: 1003,
        user_channel_id: 1004,
        static_channels: connector.static_channels,
        desktop_size,
        enable_server_pointer: false,
        pointer_software_rendering: false,
        connection_activation,
    };

    (connection_result, desktop_size)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn summarize_active_stage_outputs_for_probe(
    outputs: Vec<ironrdp_session::ActiveStageOutput>,
) -> ActiveStageInputProbe {
    let mut response_frames = 0;
    let mut response_bytes = 0;
    let mut graphics_updates = 0;

    for output in outputs {
        match output {
            ironrdp_session::ActiveStageOutput::ResponseFrame(frame) => {
                response_frames += 1;
                response_bytes += frame.len();
            }
            ironrdp_session::ActiveStageOutput::GraphicsUpdate(_) => {
                graphics_updates += 1;
            }
            ironrdp_session::ActiveStageOutput::PointerDefault
            | ironrdp_session::ActiveStageOutput::PointerHidden
            | ironrdp_session::ActiveStageOutput::PointerPosition { .. }
            | ironrdp_session::ActiveStageOutput::PointerBitmap(_)
            | ironrdp_session::ActiveStageOutput::Terminate(_)
            | ironrdp_session::ActiveStageOutput::DeactivateAll(_) => {}
        }
    }

    ActiveStageInputProbe {
        response_frames,
        response_bytes,
        graphics_updates,
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[allow(clippy::too_many_arguments)]
fn handle_active_stage_outputs_for_probe<W: Write>(
    outputs: Vec<ironrdp_session::ActiveStageOutput>,
    upstream: &mut W,
    media_queue: &mut VecDeque<Vec<u8>>,
    image: &ironrdp_session::image::DecodedImage,
    policy: &DesktopScreenPolicy,
    session_binding_id: &str,
    media_session_id: &str,
    next_sequence: &mut u64,
    timestamp_unix_nano: i64,
) -> Result<ActiveStageOutputProbe, BackendError> {
    let mut probe = ActiveStageOutputProbe {
        rdp_response_frames: 0,
        rdp_response_bytes: 0,
        queued_media_frames: 0,
        queued_media_bytes: 0,
        terminal_outputs: 0,
    };

    for output in outputs {
        match output {
            ironrdp_session::ActiveStageOutput::ResponseFrame(frame) => {
                upstream
                    .write_all(&frame)
                    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
                probe.rdp_response_frames += 1;
                probe.rdp_response_bytes += frame.len();
            }
            ironrdp_session::ActiveStageOutput::GraphicsUpdate(rect) => {
                let media_frame = encode_graphics_update_for_probe(
                    session_binding_id,
                    media_session_id,
                    *next_sequence,
                    timestamp_unix_nano,
                    image,
                    &rect,
                    policy,
                )?;
                *next_sequence = next_sequence
                    .checked_add(1)
                    .ok_or(BackendError::Unsupported(INVALID_GRAPHICS_UPDATE))?;
                probe.queued_media_frames += 1;
                probe.queued_media_bytes += media_frame.len();
                media_queue.push_back(media_frame);
            }
            ironrdp_session::ActiveStageOutput::Terminate(_)
            | ironrdp_session::ActiveStageOutput::DeactivateAll(_) => {
                probe.terminal_outputs += 1;
            }
            ironrdp_session::ActiveStageOutput::PointerDefault
            | ironrdp_session::ActiveStageOutput::PointerHidden
            | ironrdp_session::ActiveStageOutput::PointerPosition { .. }
            | ironrdp_session::ActiveStageOutput::PointerBitmap(_) => {}
        }
    }

    Ok(probe)
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn encode_graphics_update_for_probe(
    session_binding_id: &str,
    media_session_id: &str,
    sequence: u64,
    timestamp_unix_nano: i64,
    image: &ironrdp_session::image::DecodedImage,
    rect: &ironrdp_pdu::geometry::InclusiveRectangle,
    policy: &DesktopScreenPolicy,
) -> Result<Vec<u8>, BackendError> {
    if image.pixel_format() != ironrdp_graphics::image_processing::PixelFormat::RgbA32
        || rect.left > rect.right
        || rect.top > rect.bottom
        || rect.right >= image.width()
        || rect.bottom >= image.height()
    {
        return Err(BackendError::Unsupported(INVALID_GRAPHICS_UPDATE));
    }

    let payload = image.data_for_rect(rect);
    let rect_width = u32::from(rect.right - rect.left + 1);
    let rect_height = u32::from(rect.bottom - rect.top + 1);
    let metadata = format!(
        r#"{{"dirtyRects":[{{"x":{},"y":{},"width":{},"height":{},"payloadOffset":0,"payloadLength":{},"bytesPerRow":{}}}],"pixelFormat":"rgba"}}"#,
        rect.left,
        rect.top,
        rect_width,
        rect_height,
        payload.len(),
        image.stride()
    );
    let frame = DesktopMediaFrame {
        session_binding_id,
        media_session_id,
        sequence,
        timestamp_unix_nano,
        width: u32::from(image.width()),
        height: u32::from(image.height()),
        payload_family: DesktopMediaPayloadFamily::DirtyRect,
        encoding: "rgba",
        metadata: metadata.as_bytes(),
        payload,
        flags: 0,
    };

    encode_desktop_media_frame(&frame, policy)
        .map_err(|_| BackendError::Unsupported(INVALID_GRAPHICS_UPDATE))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct RejectingNetworkClient;

#[cfg(serviceradar_rdp_connector_link_probe)]
impl ironrdp_connector::sspi::network_client::NetworkClient for RejectingNetworkClient {
    fn send(
        &self,
        _request: &ironrdp_connector::sspi::generator::NetworkRequest,
    ) -> ironrdp_connector::sspi::Result<Vec<u8>> {
        Err(ironrdp_connector::sspi::Error::new(
            ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
            "network client is disabled in adapter connector probe",
        ))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ScriptedStream {
    reads: VecDeque<Vec<u8>>,
    read_offset: usize,
    writes: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl ScriptedStream {
    fn new(reads: Vec<Vec<u8>>) -> Self {
        Self {
            reads: reads.into(),
            read_offset: 0,
            writes: Vec::new(),
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Read for ScriptedStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(front) = self.reads.front() else {
            return Ok(0);
        };
        let remaining = &front[self.read_offset..];
        let len = remaining.len().min(buf.len());
        buf[..len].copy_from_slice(&remaining[..len]);
        self.read_offset += len;
        if self.read_offset == front.len() {
            self.reads.pop_front();
            self.read_offset = 0;
        }

        Ok(len)
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Write for ScriptedStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.writes.extend_from_slice(buf);

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn bytes_contain_secret(bytes: &[u8], secret: &[u8]) -> bool {
    !secret.is_empty() && bytes.windows(secret.len()).any(|window| window == secret)
}

fn is_memory_user_grant(grant: &DesktopCredentialGrant) -> bool {
    grant.mode == "memory_user"
        && !grant.username.trim().is_empty()
        && !grant.password.expose().is_empty()
}

fn build_nonsecret_connection_plan(
    request: &OpenPayload,
) -> Result<NonSecretConnectionPlan, BackendError> {
    let upstream_host = request.target.upstream.host.trim();
    let tls_server_name = request.target.tls.server_name.trim();
    let effective_tls_server_name = if tls_server_name.is_empty() {
        upstream_host
    } else {
        tls_server_name
    };
    let tls_trust_source = build_tls_trust_source(request)?;
    let upstream_port = u16::try_from(request.target.upstream.port)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    let desktop_width = u16::try_from(request.target.screen.max_width)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    let desktop_height = u16::try_from(request.target.screen.max_height)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;

    if upstream_host.is_empty() || effective_tls_server_name.is_empty() {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(NonSecretConnectionPlan {
        upstream_host: upstream_host.to_owned(),
        upstream_port,
        tls_server_name: effective_tls_server_name.to_owned(),
        tls_trust_source,
        desktop_width,
        desktop_height,
    })
}

fn build_tls_trust_source(request: &OpenPayload) -> Result<TlsTrustSource, BackendError> {
    let ca_bundle_id = request.target.tls.ca_bundle_id.trim();
    let ca_bundle_pem = request.target.tls.ca_bundle_pem.trim();

    match request.target.tls.mode.as_str() {
        TLS_MODE_SYSTEM => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY if ca_bundle_id.is_empty() => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY if ca_bundle_pem.is_empty() => {
            Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN))
        }
        TLS_MODE_VERIFY => Ok(TlsTrustSource::RegisteredCaBundle {
            id: ca_bundle_id.to_owned(),
            pem: ca_bundle_pem.to_owned(),
        }),
        TLS_MODE_PINNED_CA if ca_bundle_id.is_empty() || ca_bundle_pem.is_empty() => {
            Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN))
        }
        TLS_MODE_PINNED_CA => Ok(TlsTrustSource::RegisteredCaBundle {
            id: ca_bundle_id.to_owned(),
            pem: ca_bundle_pem.to_owned(),
        }),
        _ => Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN)),
    }
}

fn build_memory_user_credential(
    grant: &DesktopCredentialGrant,
) -> Result<MemoryUserCredential, BackendError> {
    let raw_username = grant.username.trim();
    let password = grant.password.expose();
    if raw_username.is_empty() || password.is_empty() {
        return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
    }
    let (domain, username) = split_domain_username(raw_username);
    if username.is_empty() {
        return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
    }

    Ok(MemoryUserCredential {
        domain: domain.map(|value| Zeroizing::new(value.to_owned())),
        username: Zeroizing::new(username.to_owned()),
        password: RedactedSecret {
            value: Zeroizing::new(password.to_owned()),
        },
    })
}

fn split_domain_username(username: &str) -> (Option<&str>, &str) {
    if let Some((domain, login)) = username.split_once('\\') {
        if !domain.is_empty() && !login.is_empty() {
            return (Some(domain), login);
        }
    }

    (None, username)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{parse_open_payload, tests::valid_open_payload};
    use ironrdp_pdu::gcc::KeyboardType;
    use ironrdp_pdu::rdp::capability_sets::MajorPlatformType;
    use ironrdp_pdu::rdp::client_info::PerformanceFlags;

    #[test]
    fn ironrdp_core_pdu_types_are_linked() {
        let _buffer = ironrdp_core::WriteBuf::new();

        assert_eq!(KeyboardType::IbmEnhanced.as_u32(), 4);
        assert_eq!(
            format!("{:?}", MajorPlatformType::UNIX),
            "MajorPlatformType(0x04-UNIX)"
        );
        assert!(PerformanceFlags::default().contains(PerformanceFlags::ENABLE_FONT_SMOOTHING));
    }

    #[test]
    fn nonsecret_connection_plan_uses_registered_endpoint_and_server_name() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan,
            NonSecretConnectionPlan {
                upstream_host: "win.example".to_owned(),
                upstream_port: 3389,
                tls_server_name: "win.example".to_owned(),
                tls_trust_source: TlsTrustSource::SystemRoots,
                desktop_width: 1920,
                desktop_height: 1080,
            }
        );
    }

    #[test]
    fn nonsecret_connection_plan_falls_back_to_upstream_host_for_tls_name() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","nla_mode":"required"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(plan.upstream_host, "win.example");
        assert_eq!(plan.tls_server_name, "win.example");
    }

    #[test]
    fn nonsecret_connection_plan_uses_registered_ca_bundle_for_verify_mode() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"ca-rdp-prod","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan.tls_trust_source,
            TlsTrustSource::RegisteredCaBundle {
                id: "ca-rdp-prod".to_owned(),
                pem: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----".to_owned(),
            }
        );
    }

    #[test]
    fn nonsecret_connection_plan_requires_registered_ca_bundle_material_for_pinned_ca() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","ca_bundle_id":"ca-rdp-prod","nla_mode":"required","server_name":"win.example"}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("pinned CA rejected");

        assert_eq!(err, crate::protocol::OpenPayloadError::UnsupportedTlsPolicy);
    }

    #[test]
    fn nonsecret_connection_plan_uses_registered_ca_bundle_for_pinned_ca() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","ca_bundle_id":"ca-rdp-prod","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan.tls_trust_source,
            TlsTrustSource::RegisteredCaBundle {
                id: "ca-rdp-prod".to_owned(),
                pem: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----".to_owned(),
            }
        );
    }

    #[test]
    fn memory_user_credential_uses_zeroizing_redacted_storage() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        assert!(credential.domain.is_none());
        assert_eq!(credential.username.as_str(), "alice");
        assert_eq!(credential.password.value.as_str(), "secret");
        assert_eq!(
            format!("{credential:?}"),
            r#"MemoryUserCredential { domain: "<redacted>", username: "<redacted>", password: <redacted> }"#
        );
    }

    #[test]
    fn memory_user_credential_splits_windows_domain_username() {
        let raw = valid_open_payload()
            .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
            .replace(
                r#""allowed_principals":["alice"]"#,
                r#""allowed_principals":["EXAMPLE\\alice"]"#,
            );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        assert_eq!(
            credential.domain.as_ref().map(|domain| domain.as_str()),
            Some("EXAMPLE")
        );
        assert_eq!(credential.username.as_str(), "alice");
        assert_eq!(credential.password.value.as_str(), "secret");
        assert!(!format!("{credential:?}").contains("EXAMPLE"));
        assert!(!format!("{credential:?}").contains("alice"));
        assert!(!format!("{credential:?}").contains("secret"));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_builds_config_from_validated_open_payload() {
        let raw = valid_open_payload()
            .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
            .replace(
                r#""allowed_principals":["alice"]"#,
                r#""allowed_principals":["EXAMPLE\\alice"]"#,
            );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let config = build_connector_config_for_probe(&plan, &credential);

        assert_eq!(config.desktop_size.width, 1920);
        assert_eq!(config.desktop_size.height, 1080);
        assert!(!config.enable_tls);
        assert!(config.enable_credssp);
        assert_eq!(config.domain.as_deref(), Some("EXAMPLE"));
        let ironrdp_connector::Credentials::UsernamePassword { username, .. } = config.credentials;
        assert_eq!(username, "alice");
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_experimental_open_preflight_omits_password_copy() {
        let raw = valid_open_payload()
            .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
            .replace(
                r#""allowed_principals":["alice"]"#,
                r#""allowed_principals":["EXAMPLE\\alice"]"#,
            );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let preflight = build_connector_config_preflight_for_experimental(&plan, &credential)
            .expect("preflight");
        let debug = format!("{preflight:?}");

        assert_eq!(preflight.domain.as_deref(), Some("EXAMPLE"));
        assert_eq!(preflight.username, "alice");
        assert_eq!(preflight.upstream_endpoint, "win.example:3389");
        assert!(!debug.contains("secret"));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_dial_target_formats_ipv6_endpoint_without_dns() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        plan.upstream_host = "2001:db8::45".to_owned();

        let dial_target = build_connector_dial_target_for_plan(&plan).expect("dial target");

        assert_eq!(
            dial_target,
            ConnectorDialTarget {
                host: "2001:db8::45".to_owned(),
                port: 3389,
                endpoint: "[2001:db8::45]:3389".to_owned(),
            }
        );
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_dial_target_rejects_invalid_host_text() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        plan.upstream_host = "bad host.example".to_owned();

        let err = build_connector_dial_target_for_plan(&plan)
            .expect_err("host text with whitespace rejected");

        assert_eq!(err, BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_tcp_dial_returns_dialed_stream_for_registered_target() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let listener_addr = listener.local_addr().expect("listener addr");
        plan.upstream_host = listener_addr.ip().to_string();
        plan.upstream_port = listener_addr.port();

        let dialed =
            dial_connector_tcp_for_probe(&plan, Duration::from_secs(1)).expect("dialed stream");

        assert_eq!(
            dialed.endpoint(),
            format!("{}:{}", plan.upstream_host, plan.upstream_port)
        );
        assert_eq!(dialed.client_addr().ip(), listener_addr.ip());
        assert_ne!(dialed.client_addr().port(), 0);
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_tcp_connect_begin_reaches_upgrade_boundary_without_password() {
        use std::io::{Read as _, Write as _};

        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let listener_addr = listener.local_addr().expect("listener addr");
        plan.upstream_host = listener_addr.ip().to_string();
        plan.upstream_port = listener_addr.port();
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
                .expect("server confirm");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accepted connection");
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .expect("read timeout");
            let mut initial_request = [0_u8; 4096];
            let read = stream
                .read(&mut initial_request)
                .expect("initial connector request");
            stream
                .write_all(&server_confirm)
                .expect("server confirm write");

            initial_request[..read].to_vec()
        });

        let handoff = begin_connector_handoff_with_tcp_dial_for_probe(
            &plan,
            &credential,
            Duration::from_secs(1),
        )
        .expect("connector begin handoff");
        let initial_request = server.join().expect("server thread");

        assert!(handoff.requires_security_upgrade());
        assert_eq!(
            handoff.remote_endpoint(),
            format!("{}:{}", plan.upstream_host, plan.upstream_port)
        );
        assert_eq!(handoff.client_addr().ip(), listener_addr.ip());
        assert_ne!(handoff.client_addr().port(), 0);
        assert!(!initial_request.is_empty());
        assert!(!bytes_contain_secret(
            &initial_request,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_tcp_tls_upgrade_enters_credssp_state_without_password() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_tls_server_cert_pem();
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let listener_addr = listener.local_addr().expect("listener addr");
        plan.upstream_host = listener_addr.ip().to_string();
        plan.upstream_port = listener_addr.port();
        plan.tls_server_name = "win.example".to_owned();
        let server = spawn_hybrid_ex_tls_probe_server(listener);

        let begin_handoff = begin_connector_handoff_with_tcp_dial_for_probe(
            &plan,
            &credential,
            Duration::from_secs(1),
        )
        .expect("connector begin handoff");
        let credssp_handoff =
            upgrade_connector_handoff_tls_for_probe(begin_handoff).expect("TLS upgrade");
        let initial_request = server.join().expect("server thread");
        let (_tls_stream, leftover) = credssp_handoff.framed.get_inner();

        assert!(credssp_handoff.requires_credssp());
        assert_eq!(credssp_handoff.server_name(), "win.example");
        assert!(leftover.is_empty());
        assert!(!initial_request.is_empty());
        assert!(!bytes_contain_secret(
            &initial_request,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_tcp_tls_upgrade_rejects_server_name_mismatch_without_password() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_tls_server_cert_pem();
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let listener_addr = listener.local_addr().expect("listener addr");
        plan.upstream_host = listener_addr.ip().to_string();
        plan.upstream_port = listener_addr.port();
        plan.tls_server_name = "rdp-wrong.example".to_owned();
        let server = spawn_hybrid_ex_tls_probe_server(listener);

        let begin_handoff = begin_connector_handoff_with_tcp_dial_for_probe(
            &plan,
            &credential,
            Duration::from_secs(1),
        )
        .expect("connector begin handoff");
        let err = upgrade_connector_handoff_tls_for_probe(begin_handoff)
            .expect_err("server name mismatch rejected");
        let initial_request = server.join().expect("server thread");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
        assert!(!initial_request.is_empty());
        assert!(!bytes_contain_secret(
            &initial_request,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_tcp_tls_upgrade_rejects_untrusted_ca_without_password() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let listener_addr = listener.local_addr().expect("listener addr");
        plan.upstream_host = listener_addr.ip().to_string();
        plan.upstream_port = listener_addr.port();
        plan.tls_server_name = "win.example".to_owned();
        let server = spawn_hybrid_ex_tls_probe_server(listener);

        let begin_handoff = begin_connector_handoff_with_tcp_dial_for_probe(
            &plan,
            &credential,
            Duration::from_secs(1),
        )
        .expect("connector begin handoff");
        let err = upgrade_connector_handoff_tls_for_probe(begin_handoff)
            .expect_err("untrusted CA rejected");
        let initial_request = server.join().expect("server thread");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
        assert!(!initial_request.is_empty());
        assert!(!bytes_contain_secret(
            &initial_request,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_tcp_connect_begin_rejects_tls_only_confirm_without_password() {
        use std::io::{Read as _, Write as _};

        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
        let listener_addr = listener.local_addr().expect("listener addr");
        plan.upstream_host = listener_addr.ip().to_string();
        plan.upstream_port = listener_addr.port();
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::SSL)
                .expect("server confirm");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accepted connection");
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .expect("read timeout");
            let mut initial_request = [0_u8; 4096];
            let read = stream
                .read(&mut initial_request)
                .expect("initial connector request");
            stream
                .write_all(&server_confirm)
                .expect("server confirm write");

            initial_request[..read].to_vec()
        });

        let err = match begin_connector_handoff_with_tcp_dial_for_probe(
            &plan,
            &credential,
            Duration::from_secs(1),
        ) {
            Ok(_) => panic!("tls-only confirm should be rejected"),
            Err(err) => err,
        };
        let initial_request = server.join().expect("server thread");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
        assert!(!initial_request.is_empty());
        assert!(!bytes_contain_secret(
            &initial_request,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_initial_pdu_advertises_nla_without_tls_fallback() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let pdu = build_initial_connector_pdu_for_probe(&plan, &credential).expect("initial pdu");
        let request = decode_initial_connection_request_for_probe(&pdu).expect("decoded pdu");

        assert!(request.protocol.intersects(
            ironrdp_pdu::nego::SecurityProtocol::HYBRID
                | ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX
        ));
        assert!(!request
            .protocol
            .intersects(ironrdp_pdu::nego::SecurityProtocol::SSL));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_hybrid_confirm_reaches_tls_then_credssp_boundary() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        for protocol in [
            ironrdp_pdu::nego::SecurityProtocol::HYBRID,
            ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX,
        ] {
            let boundary =
                drive_connector_to_upgrade_boundary_for_probe(&plan, &credential, protocol)
                    .expect("upgrade boundary");

            assert!(boundary.requires_security_upgrade);
            assert!(boundary.requires_credssp_after_upgrade);
        }
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_rejects_tls_only_server_confirm() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let err = drive_connector_to_upgrade_boundary_for_probe(
            &plan,
            &credential,
            ironrdp_pdu::nego::SecurityProtocol::SSL,
        )
        .expect_err("tls-only confirm rejected");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_blocking_connect_begin_reuses_upstream_loop_without_password() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let probe = drive_blocking_connect_begin_for_probe(&plan, &credential)
            .expect("blocking connect begin");

        assert!(probe.requires_security_upgrade);
        assert!(!probe.contains_cleartext_password);
        assert!(!probe.written_bytes.is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_begin_handoff_carries_upgrade_state_and_verified_tls_config() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
                .expect("server confirm");

        let handoff = begin_connector_handoff_for_probe(
            &plan,
            &credential,
            ScriptedStream::new(vec![server_confirm]),
        )
        .expect("connector begin handoff");
        let (stream, leftover) = handoff.framed.get_inner();

        assert!(handoff.requires_security_upgrade());
        assert_eq!(handoff.server_name(), "win.example");
        assert_eq!(handoff.remote_endpoint(), "win.example:3389");
        assert_eq!(
            handoff.tls_probe(),
            VerifiedTlsClientConfigProbe {
                trusted_root_count: 1,
                resumption_disabled_for_credssp: true,
            }
        );
        assert!(leftover.is_empty());
        assert!(!stream.writes.is_empty());
        assert!(!bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_begin_handoff_uses_supplied_client_socket_addr() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
                .expect("server confirm");
        let client_addr: SocketAddr = "10.7.8.9:49152".parse().expect("client addr");

        let handoff = begin_connector_handoff_with_client_addr_for_probe(
            &plan,
            &credential,
            ScriptedStream::new(vec![server_confirm]),
            client_addr,
        )
        .expect("connector begin handoff");

        assert_eq!(handoff.client_addr(), client_addr);
        assert!(handoff.requires_security_upgrade());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_begin_handoff_accepts_prepared_dialed_stream() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
                .expect("server confirm");
        let client_addr: SocketAddr = "10.7.8.9:49152".parse().expect("client addr");
        let dialed = prepare_dialed_connector_stream_for_probe(
            &plan,
            ScriptedStream::new(vec![server_confirm]),
            client_addr,
        )
        .expect("dialed stream");

        assert_eq!(dialed.endpoint(), "win.example:3389");
        assert_eq!(dialed.client_addr(), client_addr);

        let handoff =
            begin_connector_handoff_with_dialed_stream_for_probe(&plan, &credential, dialed)
                .expect("connector begin handoff");
        let (stream, leftover) = handoff.framed.get_inner();

        assert!(handoff.requires_security_upgrade());
        assert_eq!(handoff.client_addr(), client_addr);
        assert_eq!(handoff.remote_endpoint(), "win.example:3389");
        assert!(leftover.is_empty());
        assert!(!stream.writes.is_empty());
        assert!(!bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_begin_handoff_rejects_tls_only_server_confirm() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::SSL)
                .expect("server confirm");

        let result = begin_connector_handoff_for_probe(
            &plan,
            &credential,
            ScriptedStream::new(vec![server_confirm]),
        );

        assert!(matches!(
            result,
            Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_marked_tls_handoff_enters_credssp_state_without_password() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
                .expect("server confirm");
        let begin_handoff = begin_connector_handoff_for_probe(
            &plan,
            &credential,
            ScriptedStream::new(vec![server_confirm]),
        )
        .expect("connector begin handoff");
        let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
            &fixture_server_cert_der(),
        )
        .expect("server public key");

        let credssp_handoff =
            mark_connector_handoff_tls_upgraded_for_probe(begin_handoff, server_public_key)
                .expect("credssp handoff");
        let (stream, leftover) = credssp_handoff.framed.get_inner();

        assert!(credssp_handoff.requires_credssp());
        assert_eq!(credssp_handoff.server_name(), "win.example");
        assert!(leftover.is_empty());
        assert!(!stream.writes.is_empty());
        assert!(!bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_finalize_failure_preserves_framed_stream_without_password() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
                .expect("server confirm");
        let begin_handoff = begin_connector_handoff_for_probe(
            &plan,
            &credential,
            ScriptedStream::new(vec![server_confirm]),
        )
        .expect("connector begin handoff");
        let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
            &fixture_server_cert_der(),
        )
        .expect("server public key");
        let credssp_handoff =
            mark_connector_handoff_tls_upgraded_for_probe(begin_handoff, server_public_key)
                .expect("credssp handoff");
        let mut network_client = RejectingNetworkClient;

        let failure =
            match finalize_connector_handoff_for_probe(credssp_handoff, &mut network_client) {
                Ok(_) => panic!("rejecting network client should not finalize"),
                Err(failure) => failure,
            };
        let (stream, leftover) = failure.framed.get_inner();

        assert_eq!(
            failure.error,
            BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED)
        );
        assert!(leftover.is_empty());
        assert!(!stream.writes.is_empty());
        assert!(!bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_finalized_handoff_builds_network_pump_session() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let (connection_result, desktop_size) =
            build_connection_result_for_probe(&plan, &credential);
        let handoff = ConnectorFinalizedHandoff {
            framed: ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new())),
            connection_result,
            desktop_size,
        };
        let mut session = handoff.into_network_pump_session(
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
            1234,
        );

        {
            let session_trait: &mut dyn RdpBackendSession = &mut session;
            session_trait
                .input(&desktop_key_frame("Enter", true))
                .expect("input routed after finalized connector handoff");
        }

        assert!(!session.upstream_ref().is_empty());
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_blocking_connect_finalize_writes_credssp_without_password() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
            &fixture_server_cert_der(),
        )
        .expect("server public key");
        let probe =
            drive_blocking_connect_finalize_for_probe(&plan, &credential, server_public_key)
                .expect("blocking connect finalize");

        assert!(probe.wrote_credssp_bytes);
        assert!(!probe.contains_cleartext_password);
        assert!(!probe.written_bytes.is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_blocking_connect_finalize_rejects_empty_public_key() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let err = drive_blocking_connect_finalize_for_probe(
            &plan,
            &credential,
            VerifiedTlsPeerPublicKeyForProbe { bytes: Vec::new() },
        )
        .expect_err("empty public key rejected");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_extracts_tls_public_key_for_credssp_binding() {
        let public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
            &fixture_server_cert_der(),
        )
        .expect("server public key")
        .into_bytes();

        assert_eq!(public_key.len(), 270);
        assert_eq!(&public_key[..2], &[0x30, 0x82]);
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_rejects_invalid_tls_certificate_for_public_key_binding() {
        let err =
            derive_credssp_server_public_key_from_verified_tls_peer_for_probe(b"not a certificate")
                .expect_err("invalid cert rejected");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_registered_ca_bundle_builds_verified_tls_client_config_from_der() {
        let probe =
            build_verified_tls_client_config_for_registered_ca_bundle(&fixture_server_cert_der())
                .expect("verified TLS config")
                .probe();

        assert_eq!(
            probe,
            VerifiedTlsClientConfigProbe {
                trusted_root_count: 1,
                resumption_disabled_for_credssp: true,
            }
        );
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_registered_ca_bundle_builds_verified_tls_client_config_from_pem_chain() {
        let cert_pem = fixture_server_cert_pem();
        let ca_bundle = format!("{cert_pem}\n{cert_pem}");
        let probe = build_verified_tls_client_config_for_registered_ca_bundle(ca_bundle.as_bytes())
            .expect("verified TLS config")
            .probe();

        assert_eq!(
            probe,
            VerifiedTlsClientConfigProbe {
                trusted_root_count: 2,
                resumption_disabled_for_credssp: true,
            }
        );
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_registered_ca_bundle_rejects_empty_or_invalid_material() {
        let empty = build_verified_tls_client_config_for_registered_ca_bundle(b" \n\t")
            .expect_err("empty rejected");
        let invalid =
            build_verified_tls_client_config_for_registered_ca_bundle(b"not a certificate")
                .expect_err("invalid rejected");

        assert_eq!(empty, BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
        assert_eq!(invalid, BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_builds_verified_tls_client_config_from_plan_bundle_material() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        let probe = build_verified_tls_client_config_for_plan(&plan)
            .expect("verified config")
            .probe();

        assert_eq!(
            probe,
            VerifiedTlsClientConfigProbe {
                trusted_root_count: 1,
                resumption_disabled_for_credssp: true,
            }
        );
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_rejects_invalid_plan_bundle_material() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = "not a certificate".to_owned();
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        let err = build_verified_tls_client_config_for_plan(&plan)
            .expect_err("invalid plan bundle rejected");

        assert_eq!(err, BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_backend_open_runs_verified_tls_preflight_before_fail_closed() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
        let mut backend = IronRdpBackend;

        let result = backend.open(payload);

        assert!(matches!(
            result,
            Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_backend_open_rejects_invalid_ca_bundle_before_connector_loop() {
        let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
        payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
        payload.target.tls.ca_bundle_pem = "not a certificate".to_owned();
        let mut backend = IronRdpBackend;

        let result = backend.open(payload);

        assert!(matches!(
            result,
            Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE))
        ));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_system_roots_build_verified_tls_client_config() {
        let probe =
            build_verified_tls_client_config_for_system_roots().expect("system roots TLS config");
        let probe = probe.probe();

        assert!(probe.trusted_root_count > 0);
        assert!(probe.resumption_disabled_for_credssp);
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_active_stage_encodes_keyboard_input_response_frame() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");

        let probe = encode_active_stage_keyboard_input_for_probe(&plan, &credential)
            .expect("active stage input");

        assert_eq!(probe.response_frames, 1);
        assert!(probe.response_bytes > 0);
        assert_eq!(probe.graphics_updates, 0);
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_active_stage_session_routes_browser_input_to_upstream() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let mut session = ActiveStageSessionProbe::new(
            &plan,
            &credential,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
        );

        let probe = session
            .input(&desktop_key_frame("Enter", true))
            .expect("input routed");

        assert_eq!(probe.rdp_response_frames, 1);
        assert!(probe.rdp_response_bytes > 0);
        assert_eq!(probe.queued_media_frames, 0);
        assert_eq!(session.upstream_ref().len(), probe.rdp_response_bytes);
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_active_stage_session_accepts_connection_result_handoff() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let (connection_result, desktop_size) =
            build_connection_result_for_probe(&plan, &credential);
        let mut session = ActiveStageSessionProbe::from_connection_result(
            connection_result,
            desktop_size,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
        );

        let probe = session
            .input(&desktop_key_frame("Enter", true))
            .expect("input routed after connection-result handoff");

        assert_eq!(probe.rdp_response_frames, 1);
        assert!(probe.rdp_response_bytes > 0);
        assert_eq!(probe.queued_media_frames, 0);
        assert_eq!(session.upstream_ref().len(), probe.rdp_response_bytes);
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_active_stage_session_rejects_unsupported_browser_input() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let mut session = ActiveStageSessionProbe::new(
            &plan,
            &credential,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
        );

        let err = session
            .input(&desktop_key_frame("F13", true))
            .expect_err("unsupported input rejected");

        assert_eq!(err, BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));
        assert!(session.upstream_ref().is_empty());
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_active_stage_session_implements_backend_session_contract() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let mut session = ActiveStageSessionProbe::new(
            &plan,
            &credential,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
        );

        {
            let session_trait: &mut dyn RdpBackendSession = &mut session;
            session_trait
                .input(&desktop_key_frame("Enter", true))
                .expect("input routed through trait");
            session_trait
                .ack(&crate::protocol::DesktopMediaAck {
                    session_binding_id: "session-1".to_owned(),
                    media_session_id: "media-1".to_owned(),
                    last_accepted_seq: 0,
                    credit_bytes: 4096,
                    quality_level: String::new(),
                    pause: false,
                    resume: false,
                    close_reason: String::new(),
                })
                .expect("ack accepted through trait");
            assert!(session_trait
                .drain_media_frames()
                .expect("drain through trait")
                .is_empty());
            session_trait
                .close(&DesktopClosePayload {
                    reason: "done".to_owned(),
                })
                .expect("graceful close through trait");
        }

        assert!(!session.upstream_ref().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_active_stage_session_rejects_malformed_server_frames() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let mut session = ActiveStageSessionProbe::new(
            &plan,
            &credential,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
        );

        let err = session
            .server_frame(ironrdp_pdu::Action::X224, b"not-a-valid-pdu", 1234)
            .expect_err("malformed server frame rejected");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
        assert!(session.upstream_ref().is_empty());
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_server_read_loop_rejects_malformed_pdu_before_active_stage() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let mut session = ActiveStageSessionProbe::new(
            &plan,
            &credential,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
        );
        let mut framed =
            ironrdp_blocking::Framed::new(ScriptedStream::new(vec![b"not-a-pdu".to_vec()]));

        let err = read_active_stage_server_frame_for_probe(&mut framed, &mut session, 1234)
            .expect_err("malformed pdu rejected");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
        assert!(session.upstream_ref().is_empty());
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_backend_session_pump_reads_server_frames() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let inner = ActiveStageSessionProbe::new(
            &plan,
            &credential,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
        );
        let framed =
            ironrdp_blocking::Framed::new(ScriptedStream::new(vec![b"not-a-pdu".to_vec()]));
        let mut session = ActiveStageNetworkPumpSessionProbe::new(framed, inner, 1234);

        let err = {
            let session_trait: &mut dyn RdpBackendSession = &mut session;
            session_trait
                .pump()
                .expect_err("malformed pumped server frame rejected")
        };

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
        assert!(session.upstream_ref().is_empty());
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_network_pump_session_accepts_connection_result_handoff() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");
        let credential = build_memory_user_credential(
            payload
                .credential_grant
                .as_ref()
                .expect("memory user credential grant"),
        )
        .expect("credential");
        let (connection_result, desktop_size) =
            build_connection_result_for_probe(&plan, &credential);
        let framed = ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new()));
        let mut session = ActiveStageNetworkPumpSessionProbe::from_connection_result(
            framed,
            connection_result,
            desktop_size,
            Vec::<u8>::new(),
            &payload.target.screen,
            "session-1".to_owned(),
            "media-1".to_owned(),
            1234,
        );

        {
            let session_trait: &mut dyn RdpBackendSession = &mut session;
            session_trait
                .input(&desktop_key_frame("Enter", true))
                .expect("input routed after network-pump handoff");
        }

        assert!(!session.upstream_ref().is_empty());
        assert!(session.drain_media_frames().is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_encodes_graphics_update_as_srdp_dirty_rect_frame() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let image = ironrdp_session::image::DecodedImage::new(
            ironrdp_graphics::image_processing::PixelFormat::RgbA32,
            800,
            600,
        );
        let rect = ironrdp_pdu::geometry::InclusiveRectangle {
            left: 4,
            top: 6,
            right: 7,
            bottom: 8,
        };

        let encoded = encode_graphics_update_for_probe(
            "session-1",
            "media-1",
            99,
            1234,
            &image,
            &rect,
            &payload.target.screen,
        )
        .expect("graphics update encoded");

        assert_eq!(&encoded[0..4], b"SRDP");
        assert_eq!(encoded[4], 1);
        assert_eq!(encoded[6], 2);
        assert_eq!(u64::from_be_bytes(encoded[8..16].try_into().unwrap()), 99);
        assert_eq!(
            i64::from_be_bytes(encoded[16..24].try_into().unwrap()),
            1234
        );
        assert_eq!(u32::from_be_bytes(encoded[24..28].try_into().unwrap()), 800);
        assert_eq!(u32::from_be_bytes(encoded[28..32].try_into().unwrap()), 600);

        let metadata_len = u32::from_be_bytes(encoded[32..36].try_into().unwrap()) as usize;
        let payload_len = u32::from_be_bytes(encoded[36..40].try_into().unwrap()) as usize;
        let encoding_len = u16::from_be_bytes(encoded[40..42].try_into().unwrap()) as usize;
        let session_len = u16::from_be_bytes(encoded[42..44].try_into().unwrap()) as usize;
        let media_len = u16::from_be_bytes(encoded[44..46].try_into().unwrap()) as usize;
        let metadata_offset = 48 + session_len + media_len + encoding_len;
        let metadata =
            std::str::from_utf8(&encoded[metadata_offset..metadata_offset + metadata_len])
                .expect("metadata utf8");

        assert_eq!(&encoded[48..48 + session_len], b"session-1");
        assert_eq!(
            &encoded[48 + session_len..48 + session_len + media_len],
            b"media-1"
        );
        assert_eq!(
            &encoded[48 + session_len + media_len..metadata_offset],
            b"rgba"
        );
        assert!(metadata.contains(r#""dirtyRects":[{"x":4,"y":6,"width":4,"height":3"#));
        assert!(metadata.contains(r#""payloadOffset":0"#));
        assert!(metadata.contains(r#""payloadLength":6416"#));
        assert!(metadata.contains(r#""bytesPerRow":3200"#));
        assert!(metadata.contains(r#""pixelFormat":"rgba""#));
        assert_eq!(payload_len, 6416);
        assert_eq!(encoded.len(), metadata_offset + metadata_len + payload_len);
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_rejects_invalid_graphics_update_rectangles() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let image = ironrdp_session::image::DecodedImage::new(
            ironrdp_graphics::image_processing::PixelFormat::RgbA32,
            800,
            600,
        );
        let rect = ironrdp_pdu::geometry::InclusiveRectangle {
            left: 4,
            top: 6,
            right: 801,
            bottom: 8,
        };

        let err = encode_graphics_update_for_probe(
            "session-1",
            "media-1",
            99,
            1234,
            &image,
            &rect,
            &payload.target.screen,
        )
        .expect_err("invalid graphics rect rejected");

        assert_eq!(err, BackendError::Unsupported(INVALID_GRAPHICS_UPDATE));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_routes_active_stage_outputs_to_upstream_and_media_queue() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let image = ironrdp_session::image::DecodedImage::new(
            ironrdp_graphics::image_processing::PixelFormat::RgbA32,
            800,
            600,
        );
        let rect = ironrdp_pdu::geometry::InclusiveRectangle {
            left: 4,
            top: 6,
            right: 7,
            bottom: 8,
        };
        let mut upstream = Vec::new();
        let mut media_queue = VecDeque::new();
        let mut next_sequence = 7;

        let probe = handle_active_stage_outputs_for_probe(
            vec![
                ironrdp_session::ActiveStageOutput::ResponseFrame(vec![0xaa, 0xbb]),
                ironrdp_session::ActiveStageOutput::GraphicsUpdate(rect),
                ironrdp_session::ActiveStageOutput::PointerHidden,
            ],
            &mut upstream,
            &mut media_queue,
            &image,
            &payload.target.screen,
            "session-1",
            "media-1",
            &mut next_sequence,
            1234,
        )
        .expect("active stage outputs routed");

        assert_eq!(upstream, vec![0xaa, 0xbb]);
        assert_eq!(next_sequence, 8);
        assert_eq!(media_queue.len(), 1);
        assert_eq!(
            probe,
            ActiveStageOutputProbe {
                rdp_response_frames: 1,
                rdp_response_bytes: 2,
                queued_media_frames: 1,
                queued_media_bytes: media_queue.front().expect("media frame").len(),
                terminal_outputs: 0,
            }
        );

        let media = media_queue.pop_front().expect("queued media");
        assert_eq!(&media[0..4], b"SRDP");
        assert_eq!(u64::from_be_bytes(media[8..16].try_into().unwrap()), 7);
        assert_eq!(u32::from_be_bytes(media[24..28].try_into().unwrap()), 800);
        assert_eq!(u32::from_be_bytes(media[28..32].try_into().unwrap()), 600);
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_rejects_active_stage_response_write_failures() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let image = ironrdp_session::image::DecodedImage::new(
            ironrdp_graphics::image_processing::PixelFormat::RgbA32,
            800,
            600,
        );
        let mut upstream = FailingWriter;
        let mut media_queue = VecDeque::new();
        let mut next_sequence = 7;

        let err = handle_active_stage_outputs_for_probe(
            vec![ironrdp_session::ActiveStageOutput::ResponseFrame(vec![
                0xaa, 0xbb,
            ])],
            &mut upstream,
            &mut media_queue,
            &image,
            &payload.target.screen,
            "session-1",
            "media-1",
            &mut next_sequence,
            1234,
        )
        .expect_err("write failure rejected");

        assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
        assert!(media_queue.is_empty());
        assert_eq!(next_sequence, 7);
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_maps_browser_key_input_to_rdp_scancode_events() {
        let events = map_desktop_input_events_for_probe(&desktop_key_frame("Enter", true))
            .expect("key down event");

        assert_eq!(
            events,
            vec![
                ironrdp_pdu::input::fast_path::FastPathInputEvent::KeyboardEvent(
                    ironrdp_pdu::input::fast_path::KeyboardFlags::empty(),
                    0x1c,
                ),
            ]
        );

        let events = map_desktop_input_events_for_probe(&desktop_key_frame("Enter", false))
            .expect("key up event");

        assert_eq!(
            events,
            vec![
                ironrdp_pdu::input::fast_path::FastPathInputEvent::KeyboardEvent(
                    ironrdp_pdu::input::fast_path::KeyboardFlags::RELEASE,
                    0x1c,
                ),
            ]
        );
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_maps_browser_pointer_input_to_rdp_mouse_events() {
        let events =
            map_desktop_input_events_for_probe(&desktop_pointer_frame("left", true, 100, 200))
                .expect("pointer event");

        assert_eq!(
            events,
            vec![
                ironrdp_pdu::input::fast_path::FastPathInputEvent::MouseEvent(
                    ironrdp_pdu::input::MousePdu {
                        flags: ironrdp_pdu::input::mouse::PointerFlags::MOVE
                            | ironrdp_pdu::input::mouse::PointerFlags::LEFT_BUTTON
                            | ironrdp_pdu::input::mouse::PointerFlags::DOWN,
                        number_of_wheel_rotation_units: 0,
                        x_position: 100,
                        y_position: 200,
                    },
                ),
            ]
        );
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_rejects_unsupported_browser_input_tokens() {
        let err = map_desktop_input_events_for_probe(&desktop_key_frame("F13", true))
            .expect_err("unsupported key rejected");

        assert_eq!(err, BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));

        let err =
            map_desktop_input_events_for_probe(&desktop_pointer_frame("side", true, 100, 200))
                .expect_err("unsupported pointer button rejected");

        assert_eq!(err, BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    #[test]
    fn connector_probe_focus_input_does_not_emit_rdp_events() {
        let events = map_desktop_input_events_for_probe(&DesktopFrame {
            session_id: "session-1".to_owned(),
            protocol: "rdp".to_owned(),
            frame_type: "desktop.input".to_owned(),
            width: 0,
            height: 0,
            input: Some(crate::protocol::DesktopInputEvent {
                kind: "focus".to_owned(),
                key: String::new(),
                down: false,
                button: String::new(),
                x: 0,
                y: 0,
                focused: true,
            }),
            quality: None,
            reason: String::new(),
            timestamp: 0,
            metadata: Default::default(),
        })
        .expect("focus event");

        assert!(events.is_empty());
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn desktop_key_frame(key: &str, down: bool) -> DesktopFrame {
        DesktopFrame {
            session_id: "session-1".to_owned(),
            protocol: "rdp".to_owned(),
            frame_type: "desktop.input".to_owned(),
            width: 0,
            height: 0,
            input: Some(crate::protocol::DesktopInputEvent {
                kind: "key".to_owned(),
                key: key.to_owned(),
                down,
                button: String::new(),
                x: 0,
                y: 0,
                focused: false,
            }),
            quality: None,
            reason: String::new(),
            timestamp: 0,
            metadata: Default::default(),
        }
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn desktop_pointer_frame(button: &str, down: bool, x: u32, y: u32) -> DesktopFrame {
        DesktopFrame {
            session_id: "session-1".to_owned(),
            protocol: "rdp".to_owned(),
            frame_type: "desktop.input".to_owned(),
            width: 0,
            height: 0,
            input: Some(crate::protocol::DesktopInputEvent {
                kind: "pointer".to_owned(),
                key: String::new(),
                down,
                button: button.to_owned(),
                x,
                y,
                focused: false,
            }),
            quality: None,
            reason: String::new(),
            timestamp: 0,
            metadata: Default::default(),
        }
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    struct FailingWriter;

    #[cfg(serviceradar_rdp_connector_link_probe)]
    impl Write for FailingWriter {
        fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed"))
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn fixture_server_cert_der() -> Vec<u8> {
        use base64::{engine::general_purpose::STANDARD, Engine as _};

        STANDARD
            .decode(
                "MIIDDTCCAfWgAwIBAgIUFaHwQBAFyvmfso6OPbcQ+2/fVSUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE2MTYzNzQ3WhcNMjYwNTE3MTYzNzQ3WjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALbcS3SPVJlbV5AwbziMjXX0Z5CXcOIMt67zeIzoh6hmiAou1IIVZ14FrWStQj4kJNcAwdYQWtZcjM0ya6Hx3fd/M4H3FIatWkrlZcwDtxPeMHxoLzJ0mP/yLdacyvjfKqQDn8f0JEd4KY5dN1eD/OFBGF+XuQyIBsAom6SFuo7uZA4+HmC01P5ac0zAyJKOVDpgdBWa9FYn+YszqAwjrRau1m4A8K5BgRPDBs1FQwjGhRGePEuRgOKsHdBGq/PJ1Iw4mES4pwStTgGvFHJnIPxxZHX0WHiDZnbNx+K+HJh0eaWEjYUazuQtvsyllNM6KmZIHb/bgcZ0VTRQZ87l9lUCAwEAAaNTMFEwHQYDVR0OBBYEFOEi76jfCExGDeYivuwXNMm6uGnAMB8GA1UdIwQYMBaAFOEi76jfCExGDeYivuwXNMm6uGnAMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAI6IdjMvys+AEAoeZ31Lo0IbMsM4EChsvXwpE9BZ5zuPEtRwxoxLwVKrhfjkQjuX6CWFcMlWPvUqKU4t8G3b6/5ym67vJqYkLXgF5UG5Aj7AuiLIY6j8zBcZ4dFsx7hheXZC4em5e6D16eDgATWEBKf/kfbmnX8EET5gkqolAjYI4D1M3gT5yJrulhNmfXThW5A2Vvn70AhsrhMylogKRejaMOelRi1XA0AAXkZ53JWNTCJLJtRg/6PAeyT6nJwpTZi1iKJs0gRTv2TAnUFKeVfDV1CE63YM8953dq+xwqmrTmyZabWJb6yAXEepIUPMscB2UcHKFAqgWZ+4herSzfY=",
            )
            .expect("fixture certificate")
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn fixture_server_cert_pem() -> String {
        use base64::{engine::general_purpose::STANDARD, Engine as _};

        let body = STANDARD.encode(fixture_server_cert_der());
        let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
        for chunk in body.as_bytes().chunks(64) {
            pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
            pem.push('\n');
        }
        pem.push_str("-----END CERTIFICATE-----\n");

        pem
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn spawn_hybrid_ex_tls_probe_server(
        listener: std::net::TcpListener,
    ) -> std::thread::JoinHandle<Vec<u8>> {
        use std::io::{Read as _, Write as _};

        let server_confirm =
            encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
                .expect("server confirm");

        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accepted connection");
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .expect("read timeout");
            stream
                .set_write_timeout(Some(Duration::from_secs(1)))
                .expect("write timeout");
            let mut initial_request = [0_u8; 4096];
            let read = stream
                .read(&mut initial_request)
                .expect("initial connector request");
            stream
                .write_all(&server_confirm)
                .expect("server confirm write");
            let server_config = fixture_tls_server_config_for_probe();
            let mut server_connection =
                rustls::ServerConnection::new(Arc::new(server_config)).expect("server connection");
            while server_connection.is_handshaking() {
                if server_connection.complete_io(&mut stream).is_err() {
                    break;
                }
            }

            initial_request[..read].to_vec()
        })
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn fixture_tls_server_config_for_probe() -> rustls::ServerConfig {
        let cert = rustls::pki_types::CertificateDer::from(fixture_tls_server_cert_der());
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(
            rustls::pki_types::PrivatePkcs8KeyDer::from(fixture_tls_server_key_der()),
        );

        rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .expect("fixture TLS server config")
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn fixture_tls_server_cert_der() -> Vec<u8> {
        use base64::{engine::general_purpose::STANDARD, Engine as _};

        STANDARD
            .decode(
                "MIIDJTCCAg2gAwIBAgIUaVf+hJE9biQOeCj7Hlnyp0pWaqAwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE3MDUxMDQxWhcNMjYwNTE4MDUxMDQxWjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKGuZfZ1QqXmZtoBDjgHfUW7AqXIsIP9AaWsECA7SFNDwVLAzrlw3s1GauZFzpRkByxC73+Tf9P4eqhBlR23zY9AZ9I//fJVOKLDJIHQjjUZba2y4ipb+/ns4GRFBsu7hw3QQd8l+egLZrDzZEYuaZQxtTtSjFcZadDZPSzkGuJ4Q1YqAryl6yrLKeLlsxonUNfnCu7rEgiRRfl6fUAzHLz9/Ewi69NpmykR3AGwbS9pf1FmYIBxhlpIw4fqQGw+pVRaCz6XnCWCaut4sEhBEDIShfRW8ZxXfrdJ4C5Ndw4rKbny9vrr2X65OW8i9vq4jctJvGq2CV5s09A9udoEpecCAwEAAaNrMGkwHQYDVR0OBBYEFEnORq1zs4ze0Cjw9dYRSpM0U3ZfMB8GA1UdIwQYMBaAFEnORq1zs4ze0Cjw9dYRSpM0U3ZfMA8GA1UdEwEB/wQFMAMBAf8wFgYDVR0RBA8wDYILd2luLmV4YW1wbGUwDQYJKoZIhvcNAQELBQADggEBADq9Cr8CFhXREqA1+UJNjkm4LrsiSSfTEzOkjExutLshFzfA9jJbtDyfVNF+9mYQlGpJJIFy3FVlL4GsVxG9wtHgL6c3jwWaFjT3RJCo37eqUGfwGI9lbxlSvdfqPZmmpGHv+3pqE9zs7s1nPicIwHs9V21TH8EsJrI/p8bGayx2hW7hKiRZ+lHdyc6T0JYGorMOUNzrabd8FLAt+tlQN0PKx8d1AvbQ2liADhBrUqfSZnSge5q/Ei8/BXtpO2QIR+0aR6gCABEgCh9Dn8hF3rYhShl7dSmaaZw7sB/oetco1b+hS1/trjsG6tdnQhvpcy206OmzMsuCsWj+nLhodXw=",
            )
            .expect("fixture TLS certificate")
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn fixture_tls_server_cert_pem() -> String {
        use base64::{engine::general_purpose::STANDARD, Engine as _};

        let body = STANDARD.encode(fixture_tls_server_cert_der());
        let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
        for chunk in body.as_bytes().chunks(64) {
            pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
            pem.push('\n');
        }
        pem.push_str("-----END CERTIFICATE-----\n");

        pem
    }

    #[cfg(serviceradar_rdp_connector_link_probe)]
    fn fixture_tls_server_key_der() -> Vec<u8> {
        use base64::{engine::general_purpose::STANDARD, Engine as _};

        STANDARD
            .decode(
                "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQChrmX2dUKl5mbaAQ44B31FuwKlyLCD/QGlrBAgO0hTQ8FSwM65cN7NRmrmRc6UZAcsQu9/k3/T+HqoQZUdt82PQGfSP/3yVTiiwySB0I41GW2tsuIqW/v57OBkRQbLu4cN0EHfJfnoC2aw82RGLmmUMbU7UoxXGWnQ2T0s5BrieENWKgK8pesqyyni5bMaJ1DX5wru6xIIkUX5en1AMxy8/fxMIuvTaZspEdwBsG0vaX9RZmCAcYZaSMOH6kBsPqVUWgs+l5wlgmrreLBIQRAyEoX0VvGcV363SeAuTXcOKym58vb669l+uTlvIvb6uI3LSbxqtglebNPQPbnaBKXnAgMBAAECggEAQadUbzahmEWNqWP5VqYv6ANvKUvr5cT1CMXsjHIWRf2DAOwbZfEgAEJigVyCbP6LbR1HLMqEA1roz+9FspojJlMUdauXnvKdO3a7md1LCePoBjtYHLRah1v5qK3g+xUM2/6f6RH+P4x1qFBFfTw2kj93JP45z9qZff3hGhwMkL54rp+ObfwGnu97Egy51Xzx94C5LK86KmwgfytGOpKAHLWijf+md61exTn+4danJcMkx550ynKBFoXEqRFZ2phiKP3/I8Ni9k67vktJ6mrpR1ymGtcBmDwZDqhc1IpWIZLmbf6iSSvmrunImDdYelZgINh+fD3oU28duou9IYhKtQKBgQDYCpOyaACRNc66xlzThE2JknN/8wm6nCvDyNIfAdMXgITRezuOoEPoHRSxGc87GZ/oIlQ72Jicp390U50YC4Q/vCXHi9omTycuH62Cd8+CrI7HjWons5989p8uDn+cRQLNtZqtotFY/tH/nQwH3zG5rp7GoR8couqTMRKFuTUtZQKBgQC/lefKcNExAcitENlQJrG5G2XPLrmqyit3DDxJ7byxfcXu9kObLOLx8rTLQCwaZxHcnEFT8QGByuxVFpYmy8MvyLbH9aYGYitydpVeu3+prODj3FNX3zVAHRZX50weerXDB2EUs/4Meupyxe0e7ecRTLxIHmulUYpeqD6/s0THWwKBgGoHJt2UNVMO+VqpJ72XXQZ7nbvZ55hyNPhtgtI87wDFzmmQ9XXWKf2s6A7S/+WdeeFPl8+XSa74dZD9yEeYv1sYV+JLPNE4X54/ZcR2UJ1tWtWNDeBWQ5vs3cqYywBCzlFvI268TcpDpYSx6smiPKFIlhwdz0samc2Lc++1KegRAoGBALK4VJI0y/C7iUho/1AVyJS1SjQLkogQMJvNfjA45l1sxsg0UrzfEpZBowY3xuyaWb9CxG5Z1N4PPofhmhB25I4e3uOJ9GbgDUep9413u4+9Bc2KKvU9857rg3xc+FU2g3h72cRGZCegQjTvDlRb+cHZo4pjVmfRuRK0QFT0FqUhAoGAFaZzpX5A75HegMY2RfGIivRPgWdDquAHzlsUHYPbfOYVAABAnUOvWD6tZzTxDfrwixfALYIa/4sU0j+H2mun+8ypmU7jMh/B/OzW6gltNgUkgXfiqxfRBoMXIPydwlFKgqOOryEFJjf14YBQv7OLd80BXXOmbIaY0+tOYOwX1ME=",
            )
            .expect("fixture TLS key")
    }
}
