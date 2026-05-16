use serde::Deserialize;
use std::collections::{BTreeMap, VecDeque};
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

const OPEN_SCHEMA: &str = "serviceradar.rdp.helper.open.v1";
const CLIENT_BUILD: u32 = 1;
const CLIENT_NAME: &str = "serviceradar";
const CLIENT_DIR: &str = "C:\\Windows\\System32\\mstscax.dll";
const CLIENT_ADDR: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0);

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarOpenRequest {
    pub schema: String,
    pub session_id: String,
    pub local_agent_id: String,
    #[serde(default)]
    pub gateway_id: String,
    pub start_unix: i64,
    pub target: ServiceRadarTarget,
    #[serde(default)]
    pub credential_grant: ServiceRadarCredentialGrant,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarTarget {
    pub target_id: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub device_uid: String,
    pub protocol: String,
    pub route: ServiceRadarRoute,
    pub upstream: ServiceRadarUpstream,
    pub screen: ServiceRadarScreenPolicy,
    pub tls: ServiceRadarTlsPolicy,
    pub credential: ServiceRadarCredentialPolicy,
    pub redirection: ServiceRadarRedirectionPolicy,
    pub recording: ServiceRadarRecordingPolicy,
    #[serde(default)]
    pub approval_required: bool,
    #[serde(default)]
    pub metadata: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarRoute {
    pub selected_agent_id: String,
    #[serde(default)]
    pub selected_gateway_id: String,
    #[serde(default)]
    pub allowed_agent_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarUpstream {
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarScreenPolicy {
    pub max_width: u16,
    pub max_height: u16,
    #[serde(default)]
    pub color_depth: u32,
    pub frame_rate: u32,
    pub bitrate_bps: u32,
    pub idle_seconds: u32,
    pub ttl_seconds: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarTlsPolicy {
    pub mode: String,
    #[serde(default)]
    pub ca_bundle_id: String,
    pub nla_mode: String,
    #[serde(default)]
    pub server_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarCredentialPolicy {
    pub mode: String,
    #[serde(default)]
    pub allowed_principals: Vec<String>,
    #[serde(default)]
    pub credential_secret_ref: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarRedirectionPolicy {
    pub clipboard_mode: String,
    #[serde(default)]
    pub drive: bool,
    #[serde(default)]
    pub printer: bool,
    #[serde(default)]
    pub audio: bool,
    #[serde(default)]
    pub smart_card: bool,
    #[serde(default)]
    pub file_copy: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarRecordingPolicy {
    pub metadata_enabled: bool,
    #[serde(default)]
    pub screen_enabled: bool,
    #[serde(default)]
    pub clipboard_enabled: bool,
    #[serde(default)]
    pub file_enabled: bool,
    #[serde(default)]
    pub audio_enabled: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceRadarCredentialGrant {
    pub mode: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub credential_secret_ref: String,
    #[serde(default)]
    pub actor_id: String,
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub target_id: String,
    #[serde(default)]
    pub route_id: String,
    #[serde(default)]
    pub expires_unix: i64,
}

#[derive(Debug, Eq, PartialEq)]
pub struct InitialConnectorPdu {
    pub before_state: &'static str,
    pub after_state: &'static str,
    pub advertises_credssp: bool,
    pub advertises_tls_fallback: bool,
    pub mstshash_cookie: Option<String>,
    pub contains_cleartext_password: bool,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ConnectorUpgradeBoundary {
    pub before_confirm_state: &'static str,
    pub after_confirm_state: &'static str,
    pub requires_security_upgrade: bool,
    pub after_upgrade_state: &'static str,
    pub requires_credssp: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub struct BlockingConnectBeginProbe {
    pub before_state: &'static str,
    pub after_state: &'static str,
    pub requires_security_upgrade: bool,
    pub contains_cleartext_password: bool,
    pub written_bytes: Vec<u8>,
}

#[derive(Debug, Eq, PartialEq)]
pub struct BlockingConnectFinalizeProbe {
    pub after_upgrade_state: &'static str,
    pub wrote_credssp_bytes: bool,
    pub contains_cleartext_password: bool,
    pub written_bytes: Vec<u8>,
}

#[derive(Debug)]
pub struct ConnectorPlan {
    pub upstream_host: String,
    pub upstream_port: u16,
    pub tls_server_name: String,
    pub tls_upgrade: TlsUpgradePlan,
    pub connector_config: ironrdp_connector::Config,
}

#[derive(Debug, Eq, PartialEq)]
pub struct TlsUpgradePlan {
    pub server_name: String,
    pub trust_source: TlsTrustSource,
}

#[derive(Debug, Eq, PartialEq)]
pub enum TlsTrustSource {
    SystemRoots,
    RegisteredCaBundle(String),
}

pub fn connector_dependency_is_linked() -> bool {
    let desktop_size = ironrdp_connector::DesktopSize {
        width: 1024,
        height: 768,
    };

    desktop_size.width == 1024 && desktop_size.height == 768
}

pub fn active_stage_dependency_is_linked() -> bool {
    std::mem::size_of::<ironrdp_session::ActiveStageOutput>() > 0
}

pub fn parse_service_radar_open_request(
    payload: &[u8],
) -> Result<ServiceRadarOpenRequest, &'static str> {
    let request: ServiceRadarOpenRequest =
        serde_json::from_slice(payload).map_err(|_| "open payload decode failed")?;
    validate_service_radar_open_request(&request)?;

    Ok(request)
}

pub fn build_connector_config(
    request: ServiceRadarOpenRequest,
) -> Result<ironrdp_connector::Config, &'static str> {
    validate_service_radar_open_request(&request)?;

    let (domain, username) = split_domain_username(request.credential_grant.username);

    Ok(ironrdp_connector::Config {
        desktop_size: ironrdp_connector::DesktopSize {
            width: request.target.screen.max_width,
            height: request.target.screen.max_height,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: ironrdp_connector::Credentials::UsernamePassword {
            username,
            password: request.credential_grant.password,
        },
        domain,
        client_build: CLIENT_BUILD,
        client_name: CLIENT_NAME.to_owned(),
        keyboard_type: ironrdp_pdu::gcc::KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: CLIENT_DIR.to_owned(),
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
    })
}

pub fn build_connector_plan(
    request: ServiceRadarOpenRequest,
) -> Result<ConnectorPlan, &'static str> {
    validate_service_radar_open_request(&request)?;

    let upstream_host = request.target.upstream.host.trim().to_owned();
    let upstream_port = request.target.upstream.port;
    let tls_upgrade = build_tls_upgrade_plan(&request)?;
    let tls_server_name = tls_upgrade.server_name.clone();
    let connector_config = build_connector_config(request)?;

    Ok(ConnectorPlan {
        upstream_host,
        upstream_port,
        tls_server_name,
        tls_upgrade,
        connector_config,
    })
}

pub fn build_tls_upgrade_plan(
    request: &ServiceRadarOpenRequest,
) -> Result<TlsUpgradePlan, &'static str> {
    let server_name = effective_tls_server_name(request)?;
    let trust_source = match request.target.tls.mode.as_str() {
        "system" => TlsTrustSource::SystemRoots,
        "verify" if request.target.tls.ca_bundle_id.trim().is_empty() => {
            TlsTrustSource::SystemRoots
        }
        "verify" => {
            TlsTrustSource::RegisteredCaBundle(request.target.tls.ca_bundle_id.trim().to_owned())
        }
        "pinned_ca" => {
            let ca_bundle_id = request.target.tls.ca_bundle_id.trim();
            if ca_bundle_id.is_empty() {
                return Err("tls ca bundle is required");
            }
            TlsTrustSource::RegisteredCaBundle(ca_bundle_id.to_owned())
        }
        _ => return Err("tls verification mode is unsupported"),
    };

    Ok(TlsUpgradePlan {
        server_name,
        trust_source,
    })
}

fn effective_tls_server_name(request: &ServiceRadarOpenRequest) -> Result<String, &'static str> {
    let explicit_server_name = request.target.tls.server_name.trim();
    if !explicit_server_name.is_empty() {
        return Ok(explicit_server_name.to_owned());
    }

    let upstream_host = request.target.upstream.host.trim();
    if upstream_host.is_empty() {
        return Err("tls server name is required");
    }

    Ok(upstream_host.to_owned())
}

fn validate_service_radar_open_request(
    request: &ServiceRadarOpenRequest,
) -> Result<(), &'static str> {
    if request.schema != OPEN_SCHEMA {
        return Err("open payload schema is unsupported");
    }
    if request.session_id.trim().is_empty() || request.start_unix <= 0 {
        return Err("session policy is invalid");
    }
    if request.local_agent_id.trim().is_empty() {
        return Err("local agent is required");
    }
    if request.target.protocol != "rdp" && request.target.protocol != "desktop" {
        return Err("target protocol is unsupported");
    }
    if request.target.route.selected_agent_id != request.local_agent_id
        || (!request.gateway_id.is_empty()
            && !request.target.route.selected_gateway_id.is_empty()
            && request.target.route.selected_gateway_id != request.gateway_id)
    {
        return Err("selected route is invalid");
    }
    if !request.target.route.allowed_agent_ids.is_empty()
        && !request
            .target
            .route
            .allowed_agent_ids
            .iter()
            .any(|agent_id| agent_id == &request.target.route.selected_agent_id)
    {
        return Err("selected route is not allowed");
    }
    if request.target.upstream.host.trim().is_empty() || request.target.upstream.port == 0 {
        return Err("upstream target is required");
    }
    if !matches!(
        request.target.tls.mode.as_str(),
        "verify" | "pinned_ca" | "system"
    ) || request.tls_nla_mode() != "required"
    {
        return Err("nla is required");
    }
    if request.target.credential.mode != "memory_user"
        || request.credential_grant.mode != "memory_user"
    {
        return Err("memory-user credential grant is required");
    }
    if request.credential_grant.username.trim().is_empty()
        || request.credential_grant.password.is_empty()
    {
        return Err("username and password are required");
    }
    if !request.target.credential.allowed_principals.is_empty()
        && !request
            .target
            .credential
            .allowed_principals
            .iter()
            .any(|principal| principal == &request.credential_grant.username)
    {
        return Err("credential principal is not allowed");
    }
    if !request.credential_grant.session_id.is_empty()
        && request.credential_grant.session_id != request.session_id
    {
        return Err("credential grant session is invalid");
    }
    if !request.credential_grant.target_id.is_empty()
        && request.credential_grant.target_id != request.target.target_id
    {
        return Err("credential grant target is invalid");
    }
    if request.target.screen.max_width == 0
        || request.target.screen.max_height == 0
        || request.target.screen.frame_rate == 0
        || request.target.screen.bitrate_bps == 0
        || request.target.screen.idle_seconds == 0
        || request.target.screen.ttl_seconds == 0
    {
        return Err("screen policy is invalid");
    }
    if request.target.redirection.clipboard_mode != "disabled"
        || request.target.redirection.drive
        || request.target.redirection.printer
        || request.target.redirection.audio
        || request.target.redirection.smart_card
        || request.target.redirection.file_copy
    {
        return Err("redirection policy is unsupported");
    }
    if !request.target.recording.metadata_enabled
        || request.target.recording.screen_enabled
        || request.target.recording.clipboard_enabled
        || request.target.recording.file_enabled
        || request.target.recording.audio_enabled
    {
        return Err("recording policy is unsupported");
    }

    Ok(())
}

fn split_domain_username(username: String) -> (Option<String>, String) {
    if let Some((domain, login)) = username.split_once('\\') {
        if !domain.is_empty() && !login.is_empty() {
            return (Some(domain.to_owned()), login.to_owned());
        }
    }

    (None, username)
}

pub fn build_initial_connector_pdu(
    request: ServiceRadarOpenRequest,
) -> Result<InitialConnectorPdu, &'static str> {
    let password = request.credential_grant.password.clone();
    let config = build_connector_config(request)?;
    let mut connector = ironrdp_connector::ClientConnector::new(config, CLIENT_ADDR);
    let before_state = connector_state_name(&connector);
    let mut buffer = ironrdp_core::WriteBuf::new();
    let written = ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| "initial connector step failed")?;
    let written_len = written
        .size()
        .ok_or("initial connector step wrote no bytes")?;

    Ok(InitialConnectorPdu {
        before_state,
        after_state: connector_state_name(&connector),
        advertises_credssp: initial_pdu_advertises_credssp(buffer.filled())?,
        advertises_tls_fallback: initial_pdu_advertises_tls_fallback(buffer.filled())?,
        mstshash_cookie: initial_pdu_mstshash_cookie(buffer.filled())?,
        contains_cleartext_password: bytes_contain_secret(buffer.filled(), password.as_bytes()),
        bytes: buffer.filled()[..written_len].to_vec(),
    })
}

pub fn drive_connector_to_credssp_boundary(
    request: ServiceRadarOpenRequest,
) -> Result<ConnectorUpgradeBoundary, &'static str> {
    drive_connector_with_server_protocol(request, ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
}

pub fn drive_blocking_connect_begin_to_tls_upgrade(
    request: ServiceRadarOpenRequest,
) -> Result<BlockingConnectBeginProbe, &'static str> {
    let password = request.credential_grant.password.clone();
    let config = build_connector_config(request)?;
    let server_confirm = encode_server_confirm(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let mut connector = ironrdp_connector::ClientConnector::new(config, CLIENT_ADDR);
    let before_state = connector_state_name(&connector);
    let mut framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![server_confirm]));

    ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| "blocking connect begin failed")?;

    let after_state = connector_state_name(&connector);
    let requires_security_upgrade = connector.should_perform_security_upgrade();
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err("blocking connect begin left unread bytes");
    }

    Ok(BlockingConnectBeginProbe {
        before_state,
        after_state,
        requires_security_upgrade,
        contains_cleartext_password: bytes_contain_secret(&stream.writes, password.as_bytes()),
        written_bytes: stream.writes,
    })
}

pub fn drive_blocking_connect_finalize_until_server_input(
    request: ServiceRadarOpenRequest,
    server_public_key: Vec<u8>,
) -> Result<BlockingConnectFinalizeProbe, &'static str> {
    if server_public_key.is_empty() {
        return Err("server public key is required");
    }

    let password = request.credential_grant.password.clone();
    let plan = build_connector_plan(request)?;
    let server_confirm = encode_server_confirm(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let mut connector = ironrdp_connector::ClientConnector::new(plan.connector_config, CLIENT_ADDR);
    let mut framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![server_confirm]));
    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| "blocking connect begin failed")?;
    let (_initial_stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err("blocking connect begin left unread bytes");
    }

    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let after_upgrade_state = connector_state_name(&connector);
    let mut upgraded_framed = ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new()));
    let mut network_client = RejectingNetworkClient;
    let finalize = ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut upgraded_framed,
        &mut network_client,
        plan.tls_server_name.into(),
        server_public_key,
        None,
    );
    if finalize.is_ok() {
        return Err("blocking connect finalize unexpectedly completed");
    }

    let (stream, leftover) = upgraded_framed.into_inner();
    if !leftover.is_empty() {
        return Err("blocking connect finalize left unread bytes");
    }

    Ok(BlockingConnectFinalizeProbe {
        after_upgrade_state,
        wrote_credssp_bytes: !stream.writes.is_empty(),
        contains_cleartext_password: bytes_contain_secret(&stream.writes, password.as_bytes()),
        written_bytes: stream.writes,
    })
}

pub fn extract_credssp_server_public_key(cert_der: &[u8]) -> Result<Vec<u8>, &'static str> {
    use x509_cert::der::Decode as _;

    let cert = x509_cert::Certificate::from_der(cert_der)
        .map_err(|_| "tls peer certificate decode failed")?;
    let public_key = cert
        .tbs_certificate
        .subject_public_key_info
        .subject_public_key
        .as_bytes()
        .ok_or("tls peer certificate public key is unaligned")?;

    if public_key.is_empty() {
        return Err("tls peer certificate public key is empty");
    }

    Ok(public_key.to_vec())
}

struct RejectingNetworkClient;

impl ironrdp_connector::sspi::network_client::NetworkClient for RejectingNetworkClient {
    fn send(
        &self,
        _request: &ironrdp_connector::sspi::generator::NetworkRequest,
    ) -> ironrdp_connector::sspi::Result<Vec<u8>> {
        Err(ironrdp_connector::sspi::Error::new(
            ironrdp_connector::sspi::ErrorKind::NoAuthenticatingAuthority,
            "network client is disabled in connector probe",
        ))
    }
}

struct ScriptedStream {
    reads: VecDeque<Vec<u8>>,
    read_offset: usize,
    writes: Vec<u8>,
}

impl ScriptedStream {
    fn new(reads: Vec<Vec<u8>>) -> Self {
        Self {
            reads: reads.into(),
            read_offset: 0,
            writes: Vec::new(),
        }
    }
}

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

impl Write for ScriptedStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.writes.extend_from_slice(buf);

        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn drive_connector_with_server_protocol(
    request: ServiceRadarOpenRequest,
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<ConnectorUpgradeBoundary, &'static str> {
    let config = build_connector_config(request)?;
    let mut connector = ironrdp_connector::ClientConnector::new(config, CLIENT_ADDR);
    let mut buffer = ironrdp_core::WriteBuf::new();

    ironrdp_connector::Sequence::step_no_input(&mut connector, &mut buffer)
        .map_err(|_| "initial connector step failed")?;

    let before_confirm_state = connector_state_name(&connector);
    let server_confirm = encode_server_confirm(selected_protocol)?;
    let mut output = ironrdp_core::WriteBuf::new();

    ironrdp_connector::Sequence::step(&mut connector, &server_confirm, &mut output)
        .map_err(|_| "server confirm step failed")?;

    let after_confirm_state = connector_state_name(&connector);
    let requires_security_upgrade = connector.should_perform_security_upgrade();
    connector.mark_security_upgrade_as_done();

    Ok(ConnectorUpgradeBoundary {
        before_confirm_state,
        after_confirm_state,
        requires_security_upgrade,
        after_upgrade_state: connector_state_name(&connector),
        requires_credssp: connector.should_perform_credssp(),
    })
}

fn encode_server_confirm(
    selected_protocol: ironrdp_pdu::nego::SecurityProtocol,
) -> Result<Vec<u8>, &'static str> {
    ironrdp_core::encode_vec(&ironrdp_pdu::x224::X224(
        ironrdp_pdu::nego::ConnectionConfirm::Response {
            flags: ironrdp_pdu::nego::ResponseFlags::empty(),
            protocol: selected_protocol,
        },
    ))
    .map_err(|_| "server confirm encode failed")
}

fn connector_state_name(connector: &ironrdp_connector::ClientConnector) -> &'static str {
    ironrdp_connector::Sequence::state(connector).name()
}

fn initial_pdu_advertises_credssp(bytes: &[u8]) -> Result<bool, &'static str> {
    let protocol = decode_initial_connection_request(bytes)?.protocol;

    Ok(protocol.intersects(
        ironrdp_pdu::nego::SecurityProtocol::HYBRID
            | ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX,
    ))
}

fn initial_pdu_advertises_tls_fallback(bytes: &[u8]) -> Result<bool, &'static str> {
    let protocol = decode_initial_connection_request(bytes)?.protocol;

    Ok(protocol.intersects(ironrdp_pdu::nego::SecurityProtocol::SSL))
}

fn initial_pdu_mstshash_cookie(bytes: &[u8]) -> Result<Option<String>, &'static str> {
    let request = decode_initial_connection_request(bytes)?;

    match request.nego_data {
        Some(ironrdp_pdu::nego::NegoRequestData::Cookie(cookie)) => Ok(Some(cookie.0)),
        _ => Ok(None),
    }
}

fn decode_initial_connection_request(
    bytes: &[u8],
) -> Result<ironrdp_pdu::nego::ConnectionRequest, &'static str> {
    let request = ironrdp_core::decode::<
        ironrdp_pdu::x224::X224<ironrdp_pdu::nego::ConnectionRequest>,
    >(bytes)
    .map_err(|_| "initial connector pdu decode failed")?
    .0;

    Ok(request)
}

fn bytes_contain_secret(bytes: &[u8], secret: &[u8]) -> bool {
    !secret.is_empty() && bytes.windows(secret.len()).any(|window| window == secret)
}

impl ServiceRadarOpenRequest {
    fn tls_nla_mode(&self) -> &str {
        self.target.tls.nla_mode.as_str()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use ironrdp_connector::Credentials;

    #[test]
    fn links_connector_without_root_workspace_lockfile() {
        assert!(crate::connector_dependency_is_linked());
    }

    #[test]
    fn links_active_stage_without_root_workspace_lockfile() {
        assert!(crate::active_stage_dependency_is_linked());
    }

    #[test]
    fn builds_nla_required_username_password_config() {
        let config = crate::build_connector_config(open_request("EXAMPLE\\alice", "required"))
            .expect("config");

        assert!(!config.enable_tls);
        assert!(config.enable_credssp);
        assert_eq!(config.domain.as_deref(), Some("EXAMPLE"));
        assert_eq!(config.desktop_size.width, 1920);
        assert_eq!(config.desktop_size.height, 1080);
        assert_eq!(
            config.keyboard_type,
            ironrdp_pdu::gcc::KeyboardType::IbmEnhanced
        );

        match config.credentials {
            Credentials::UsernamePassword { username, password } => {
                assert_eq!(username, "alice");
                assert_eq!(password, "secret");
            }
            Credentials::SmartCard { .. } => panic!("unexpected smart-card config"),
        }
    }

    #[test]
    fn connector_plan_uses_registered_endpoint_and_server_name() {
        let plan =
            crate::build_connector_plan(open_request("EXAMPLE\\alice", "required")).expect("plan");

        assert_eq!(plan.upstream_host, "win.example");
        assert_eq!(plan.upstream_port, 3389);
        assert_eq!(plan.tls_server_name, "win.example");
        assert!(plan.connector_config.enable_credssp);
    }

    #[test]
    fn connector_plan_falls_back_to_upstream_host_for_tls_server_name() {
        let mut request = open_request("EXAMPLE\\alice", "required");
        request.target.upstream.host = "rdp.internal.example".to_owned();
        request.target.tls.server_name.clear();

        let plan = crate::build_connector_plan(request).expect("plan");

        assert_eq!(plan.upstream_host, "rdp.internal.example");
        assert_eq!(plan.tls_server_name, "rdp.internal.example");
    }

    #[test]
    fn tls_upgrade_plan_uses_system_roots_by_default() {
        let request = open_request("EXAMPLE\\alice", "required");
        let plan = crate::build_tls_upgrade_plan(&request).expect("tls plan");

        assert_eq!(
            plan,
            TlsUpgradePlan {
                server_name: "win.example".to_owned(),
                trust_source: TlsTrustSource::SystemRoots,
            }
        );
    }

    #[test]
    fn tls_upgrade_plan_uses_registered_ca_bundle_for_verify_mode() {
        let mut request = open_request("EXAMPLE\\alice", "required");
        request.target.tls.ca_bundle_id = "ca-bundle-1".to_owned();
        let plan = crate::build_tls_upgrade_plan(&request).expect("tls plan");

        assert_eq!(
            plan,
            TlsUpgradePlan {
                server_name: "win.example".to_owned(),
                trust_source: TlsTrustSource::RegisteredCaBundle("ca-bundle-1".to_owned()),
            }
        );
    }

    #[test]
    fn tls_upgrade_plan_requires_registered_ca_for_pinned_ca_mode() {
        let mut request = open_request("EXAMPLE\\alice", "required");
        request.target.tls.mode = "pinned_ca".to_owned();

        let err = crate::build_tls_upgrade_plan(&request).unwrap_err();

        assert_eq!(err, "tls ca bundle is required");
    }

    #[test]
    fn tls_upgrade_plan_rejects_insecure_modes() {
        let mut request = open_request("EXAMPLE\\alice", "required");
        request.target.tls.mode = "insecure".to_owned();

        let err = crate::build_tls_upgrade_plan(&request).unwrap_err();

        assert_eq!(err, "tls verification mode is unsupported");
    }

    #[test]
    fn rejects_non_nla_connector_config() {
        let err = crate::build_connector_config(open_request("alice", "optional")).unwrap_err();

        assert_eq!(err, "nla is required");
    }

    #[test]
    fn builds_initial_x224_negotiation_pdu() {
        let pdu = crate::build_initial_connector_pdu(open_request("EXAMPLE\\alice", "required"))
            .expect("initial pdu");

        assert_eq!(pdu.before_state, "ConnectionInitiationSendRequest");
        assert_eq!(pdu.after_state, "ConnectionInitiationWaitResponse");
        assert!(pdu.advertises_credssp);
        assert!(!pdu.advertises_tls_fallback);
        assert_eq!(pdu.mstshash_cookie.as_deref(), Some("alice"));
        assert!(!pdu.contains_cleartext_password);
        assert!(pdu.bytes.len() > 10);
        assert_eq!(&pdu.bytes[..2], &[0x03, 0x00]);
    }

    #[test]
    fn initial_negotiation_includes_username_cookie_but_not_password() {
        let pdu = crate::build_initial_connector_pdu(open_request("EXAMPLE\\alice", "required"))
            .expect("initial pdu");

        assert_eq!(pdu.mstshash_cookie.as_deref(), Some("alice"));
        assert!(!pdu.contains_cleartext_password);
        assert!(!pdu
            .bytes
            .windows(b"secret".len())
            .any(|window| window == b"secret"));
    }

    #[test]
    fn parses_full_helper_open_payload_and_builds_initial_pdu() {
        let request =
            crate::parse_service_radar_open_request(valid_open_payload().as_bytes()).expect("open");
        let pdu = crate::build_initial_connector_pdu(request).expect("initial pdu");

        assert_eq!(pdu.after_state, "ConnectionInitiationWaitResponse");
        assert_eq!(&pdu.bytes[..2], &[0x03, 0x00]);
    }

    #[test]
    fn server_nla_confirm_reaches_tls_upgrade_boundary_then_credssp() {
        let boundary =
            crate::drive_connector_to_credssp_boundary(open_request("EXAMPLE\\alice", "required"))
                .expect("boundary");

        assert_eq!(
            boundary.before_confirm_state,
            "ConnectionInitiationWaitResponse"
        );
        assert_eq!(boundary.after_confirm_state, "EnhancedSecurityUpgrade");
        assert!(boundary.requires_security_upgrade);
        assert_eq!(boundary.after_upgrade_state, "Credssp");
        assert!(boundary.requires_credssp);
    }

    #[test]
    fn blocking_connect_begin_wrapper_reaches_tls_upgrade_boundary() {
        let boundary = crate::drive_blocking_connect_begin_to_tls_upgrade(open_request(
            "EXAMPLE\\alice",
            "required",
        ))
        .expect("boundary");

        assert_eq!(boundary.before_state, "ConnectionInitiationSendRequest");
        assert_eq!(boundary.after_state, "EnhancedSecurityUpgrade");
        assert!(boundary.requires_security_upgrade);
        assert!(!boundary.contains_cleartext_password);
        assert_eq!(&boundary.written_bytes[..2], &[0x03, 0x00]);
    }

    #[test]
    fn extracts_tls_server_public_key_for_credssp_binding() {
        let public_key = crate::extract_credssp_server_public_key(&fixture_server_cert_der())
            .expect("server public key");

        assert_eq!(public_key.len(), 270);
        assert_eq!(&public_key[..2], &[0x30, 0x82]);
    }

    #[test]
    fn rejects_invalid_tls_server_certificate_for_credssp_binding() {
        let err = crate::extract_credssp_server_public_key(b"not a certificate").unwrap_err();

        assert_eq!(err, "tls peer certificate decode failed");
    }

    #[test]
    fn blocking_connect_finalize_writes_credssp_without_cleartext_password() {
        let server_public_key =
            crate::extract_credssp_server_public_key(&fixture_server_cert_der())
                .expect("server public key");
        let finalize = crate::drive_blocking_connect_finalize_until_server_input(
            open_request("EXAMPLE\\alice", "required"),
            server_public_key,
        )
        .expect("finalize probe");

        assert_eq!(finalize.after_upgrade_state, "Credssp");
        assert!(finalize.wrote_credssp_bytes);
        assert!(!finalize.contains_cleartext_password);
        assert!(!finalize
            .written_bytes
            .windows(b"secret".len())
            .any(|window| window == b"secret"));
    }

    #[test]
    fn server_hybrid_confirm_reaches_tls_upgrade_boundary_then_credssp() {
        let boundary = crate::drive_connector_with_server_protocol(
            open_request("EXAMPLE\\alice", "required"),
            ironrdp_pdu::nego::SecurityProtocol::HYBRID,
        )
        .expect("boundary");

        assert_eq!(boundary.after_confirm_state, "EnhancedSecurityUpgrade");
        assert!(boundary.requires_security_upgrade);
        assert_eq!(boundary.after_upgrade_state, "Credssp");
        assert!(boundary.requires_credssp);
    }

    #[test]
    fn server_tls_only_confirm_is_rejected_as_downgrade() {
        let err = crate::drive_connector_with_server_protocol(
            open_request("EXAMPLE\\alice", "required"),
            ironrdp_pdu::nego::SecurityProtocol::SSL,
        )
        .unwrap_err();

        assert_eq!(err, "server confirm step failed");
    }

    #[test]
    fn server_standard_rdp_confirm_is_rejected() {
        let err = crate::drive_connector_with_server_protocol(
            open_request("EXAMPLE\\alice", "required"),
            ironrdp_pdu::nego::SecurityProtocol::empty(),
        )
        .unwrap_err();

        assert_eq!(err, "server confirm step failed");
    }

    #[test]
    fn rejects_unknown_open_payload_fields() {
        let raw = valid_open_payload().replace(
            r#""schema":"serviceradar.rdp.helper.open.v1","#,
            r#""schema":"serviceradar.rdp.helper.open.v1","unexpected":true,"#,
        );
        let err = crate::parse_service_radar_open_request(raw.as_bytes()).unwrap_err();

        assert_eq!(err, "open payload decode failed");
    }

    fn open_request(username: &str, nla_mode: &str) -> crate::ServiceRadarOpenRequest {
        crate::ServiceRadarOpenRequest {
            schema: OPEN_SCHEMA.to_owned(),
            session_id: "session-1".to_owned(),
            local_agent_id: "agent-1".to_owned(),
            gateway_id: "gateway-1".to_owned(),
            start_unix: 1_778_636_531,
            target: crate::ServiceRadarTarget {
                target_id: "target-1".to_owned(),
                display_name: "Windows VM".to_owned(),
                device_uid: "device-1".to_owned(),
                protocol: "rdp".to_owned(),
                route: crate::ServiceRadarRoute {
                    selected_agent_id: "agent-1".to_owned(),
                    selected_gateway_id: "gateway-1".to_owned(),
                    allowed_agent_ids: Vec::new(),
                },
                upstream: crate::ServiceRadarUpstream {
                    host: "win.example".to_owned(),
                    port: 3389,
                },
                screen: crate::ServiceRadarScreenPolicy {
                    max_width: 1920,
                    max_height: 1080,
                    color_depth: 32,
                    frame_rate: 30,
                    bitrate_bps: 8_000_000,
                    idle_seconds: 900,
                    ttl_seconds: 3600,
                },
                tls: crate::ServiceRadarTlsPolicy {
                    mode: "verify".to_owned(),
                    ca_bundle_id: String::new(),
                    nla_mode: nla_mode.to_owned(),
                    server_name: "win.example".to_owned(),
                },
                credential: crate::ServiceRadarCredentialPolicy {
                    mode: "memory_user".to_owned(),
                    allowed_principals: vec![username.to_owned()],
                    credential_secret_ref: String::new(),
                },
                redirection: crate::ServiceRadarRedirectionPolicy {
                    clipboard_mode: "disabled".to_owned(),
                    drive: false,
                    printer: false,
                    audio: false,
                    smart_card: false,
                    file_copy: false,
                },
                recording: crate::ServiceRadarRecordingPolicy {
                    metadata_enabled: true,
                    screen_enabled: false,
                    clipboard_enabled: false,
                    file_enabled: false,
                    audio_enabled: false,
                },
                approval_required: false,
                metadata: BTreeMap::new(),
            },
            credential_grant: crate::ServiceRadarCredentialGrant {
                mode: "memory_user".to_owned(),
                username: username.to_owned(),
                password: "secret".to_owned(),
                credential_secret_ref: String::new(),
                actor_id: "user-1".to_owned(),
                session_id: "session-1".to_owned(),
                target_id: "target-1".to_owned(),
                route_id: "agent-1".to_owned(),
                expires_unix: 1_778_640_000,
            },
        }
    }

    fn valid_open_payload() -> String {
        r#"{
            "schema":"serviceradar.rdp.helper.open.v1",
            "session_id":"session-1",
            "local_agent_id":"agent-1",
            "gateway_id":"gateway-1",
            "start_unix":1778636531,
            "target":{
                "target_id":"target-1",
                "display_name":"Windows VM",
                "device_uid":"device-1",
                "protocol":"rdp",
                "route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1"},
                "upstream":{"host":"win.example","port":3389},
                "tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"},
                "credential":{"mode":"memory_user","allowed_principals":["alice"]},
                "screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600},
                "redirection":{"clipboard_mode":"disabled"},
                "recording":{"metadata_enabled":true}
            },
            "credential_grant":{"mode":"memory_user","username":"alice","password":"secret","session_id":"session-1","target_id":"target-1","route_id":"agent-1"}
        }"#
        .to_owned()
    }

    fn fixture_server_cert_der() -> Vec<u8> {
        STANDARD
            .decode(
                "MIIDDTCCAfWgAwIBAgIUFaHwQBAFyvmfso6OPbcQ+2/fVSUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE2MTYzNzQ3WhcNMjYwNTE3MTYzNzQ3WjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALbcS3SPVJlbV5AwbziMjXX0Z5CXcOIMt67zeIzoh6hmiAou1IIVZ14FrWStQj4kJNcAwdYQWtZcjM0ya6Hx3fd/M4H3FIatWkrlZcwDtxPeMHxoLzJ0mP/yLdacyvjfKqQDn8f0JEd4KY5dN1eD/OFBGF+XuQyIBsAom6SFuo7uZA4+HmC01P5ac0zAyJKOVDpgdBWa9FYn+YszqAwjrRau1m4A8K5BgRPDBs1FQwjGhRGePEuRgOKsHdBGq/PJ1Iw4mES4pwStTgGvFHJnIPxxZHX0WHiDZnbNx+K+HJh0eaWEjYUazuQtvsyllNM6KmZIHb/bgcZ0VTRQZ87l9lUCAwEAAaNTMFEwHQYDVR0OBBYEFOEi76jfCExGDeYivuwXNMm6uGnAMB8GA1UdIwQYMBaAFOEi76jfCExGDeYivuwXNMm6uGnAMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAI6IdjMvys+AEAoeZ31Lo0IbMsM4EChsvXwpE9BZ5zuPEtRwxoxLwVKrhfjkQjuX6CWFcMlWPvUqKU4t8G3b6/5ym67vJqYkLXgF5UG5Aj7AuiLIY6j8zBcZ4dFsx7hheXZC4em5e6D16eDgATWEBKf/kfbmnX8EET5gkqolAjYI4D1M3gT5yJrulhNmfXThW5A2Vvn70AhsrhMylogKRejaMOelRi1XA0AAXkZ53JWNTCJLJtRg/6PAeyT6nJwpTZi1iKJs0gRTv2TAnUFKeVfDV1CE63YM8953dq+xwqmrTmyZabWJb6yAXEepIUPMscB2UcHKFAqgWZ+4herSzfY=",
            )
            .expect("fixture certificate")
    }
}
