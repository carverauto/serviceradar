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

#[derive(Debug, Eq, PartialEq)]
struct NonSecretConnectionPlan {
    upstream_host: String,
    upstream_port: u16,
    tls_server_name: String,
    tls_trust_source: TlsTrustSource,
    kdc_proxy_url: Option<String>,
    kerberos_hostname: Option<String>,
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
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ConnectorRuntimePolicy {
    dial_timeout: Duration,
    kdc_timeout: Duration,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Default for ConnectorRuntimePolicy {
    fn default() -> Self {
        Self {
            dial_timeout: DEFAULT_CONNECTOR_TIMEOUT,
            kdc_timeout: DEFAULT_CONNECTOR_TIMEOUT,
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn connector_runtime_policy_from_request(
    request: &OpenPayload,
) -> Result<ConnectorRuntimePolicy, BackendError> {
    Ok(ConnectorRuntimePolicy {
        dial_timeout: optional_metadata_timeout_ms(
            &request.target.metadata,
            METADATA_DIAL_TIMEOUT_MS,
        )?
        .unwrap_or(DEFAULT_CONNECTOR_TIMEOUT),
        kdc_timeout: optional_metadata_timeout_ms(
            &request.target.metadata,
            METADATA_KDC_TIMEOUT_MS,
        )?
        .unwrap_or(DEFAULT_CONNECTOR_TIMEOUT),
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn optional_metadata_timeout_ms(
    metadata: &std::collections::BTreeMap<String, String>,
    key: &str,
) -> Result<Option<Duration>, BackendError> {
    let Some(value) = metadata.get(key).map(|value| value.trim()) else {
        return Ok(None);
    };
    if value.is_empty() {
        return Ok(None);
    }
    let millis = value
        .parse::<u64>()
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    if millis == 0 {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    let timeout = Duration::from_millis(millis);
    if timeout > MAX_CONNECTOR_STAGE_TIMEOUT {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(Some(timeout))
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct ConnectorBeginHandoff<S: Read + Write> {
    framed: ironrdp_blocking::Framed<S>,
    should_upgrade: ironrdp_blocking::ShouldUpgrade,
    connector: ironrdp_connector::ClientConnector,
    dial_target: ConnectorDialTarget,
    tls_config: VerifiedTlsClientConfig,
    server_name: ironrdp_connector::ServerName,
    kerberos_binding: ConnectorKerberosBinding,
    kerberos_config: Option<ironrdp_connector::credssp::KerberosConfig>,
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
    kerberos_binding: ConnectorKerberosBinding,
    kerberos_config: Option<ironrdp_connector::credssp::KerberosConfig>,
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
#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct ConnectorKerberosBinding {
    kdc_proxy_url: Option<String>,
    hostname: Option<String>,
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
fn finalized_connector_handoff_into_network_pump_session_for_probe<S, W>(
    handoff: ConnectorFinalizedHandoff<S>,
    upstream: W,
    request: &OpenPayload,
) -> Result<ActiveStageNetworkPumpSessionProbe<S, W>, BackendError>
where
    S: Read + Write,
    W: Write,
{
    let media_session_id =
        optional_metadata_value(&request.target.metadata, METADATA_MEDIA_SESSION_ID)
            .ok_or(BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;

    Ok(handoff.into_network_pump_session(
        upstream,
        &request.target.screen,
        request.session_id.clone(),
        media_session_id,
        request.start_unix,
    ))
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

    fn network_writes_len(&self) -> usize
    where
        S: NetworkWriteProbe,
    {
        self.framed.get_inner().0.writes_len()
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write, W: Write> RdpBackendSession for ActiveStageNetworkPumpSessionProbe<S, W> {
    fn input(&mut self, frame: &DesktopFrame) -> Result<(), BackendError> {
        let events = map_desktop_input_events_for_probe(frame)?;
        let outputs = self
            .inner
            .active_stage
            .process_fastpath_input(&mut self.inner.image, &events)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        self.handle_outputs_to_network(outputs, frame.timestamp)
            .map(|_| ())
    }

    fn ack(&mut self, _ack: &crate::protocol::DesktopMediaAck) -> Result<(), BackendError> {
        Ok(())
    }

    fn close(&mut self, payload: &DesktopClosePayload) -> Result<(), BackendError> {
        let _reason = &payload.reason;
        let outputs = self
            .inner
            .active_stage
            .graceful_shutdown()
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        self.handle_outputs_to_network(outputs, 0).map(|_| ())
    }

    fn pump(&mut self) -> Result<(), BackendError> {
        let (action, frame) = self
            .framed
            .read_pdu()
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
        let outputs = self
            .inner
            .active_stage
            .process(&mut self.inner.image, action, &frame)
            .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;

        self.handle_outputs_to_network(outputs, self.timestamp_unix_nano)
            .map(|_| ())
    }

    fn drain_media_frames(&mut self) -> Result<Vec<Vec<u8>>, BackendError> {
        Ok(ActiveStageNetworkPumpSessionProbe::drain_media_frames(self))
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
impl<S: Read + Write, W: Write> ActiveStageNetworkPumpSessionProbe<S, W> {
    fn handle_outputs_to_network(
        &mut self,
        outputs: Vec<ironrdp_session::ActiveStageOutput>,
        timestamp_unix_nano: i64,
    ) -> Result<ActiveStageOutputProbe, BackendError> {
        handle_active_stage_outputs_with_writer_for_probe(
            outputs,
            |frame| {
                self.framed
                    .write_all(frame)
                    .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
            },
            &mut self.inner.media_queue,
            &self.inner.image,
            &self.inner.policy,
            &self.inner.session_binding_id,
            &self.inner.media_session_id,
            &mut self.inner.next_sequence,
            timestamp_unix_nano,
        )
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
trait NetworkWriteProbe {
    fn writes_len(&self) -> usize;
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
        let credential = build_memory_user_credential(grant, &request.actor_id)?;
        if !credential.has_material() {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let _connector_identity = credential.connector_identity();
        #[cfg(serviceradar_rdp_connector_link_probe)]
        {
            return open_connector_for_experimental(&request, &plan, &credential);
        }

        #[cfg(not(serviceradar_rdp_connector_link_probe))]
        {
            let _ = plan;

            Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
        }
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
fn open_connector_for_experimental(
    request: &OpenPayload,
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<Box<dyn RdpBackendSession>, BackendError> {
    let runtime = connector_runtime_policy_from_request(request)?;

    open_connector_for_experimental_with_runtime(request, plan, credential, runtime)
}

