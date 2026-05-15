use serde::Deserialize;
use std::collections::BTreeMap;
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

#[derive(Debug)]
pub struct ConnectorPlan {
    pub upstream_host: String,
    pub upstream_port: u16,
    pub tls_server_name: String,
    pub connector_config: ironrdp_connector::Config,
}

pub fn connector_dependency_is_linked() -> bool {
    let desktop_size = ironrdp_connector::DesktopSize {
        width: 1024,
        height: 768,
    };

    desktop_size.width == 1024 && desktop_size.height == 768
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
    let tls_server_name = effective_tls_server_name(&request)?;
    let connector_config = build_connector_config(request)?;

    Ok(ConnectorPlan {
        upstream_host,
        upstream_port,
        tls_server_name,
        connector_config,
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
    use ironrdp_connector::Credentials;

    #[test]
    fn links_connector_without_root_workspace_lockfile() {
        assert!(crate::connector_dependency_is_linked());
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
}
