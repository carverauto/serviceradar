use serde::Deserialize;
use std::collections::{BTreeMap, VecDeque};
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::time::Duration;
use zeroize::Zeroizing;

const OPEN_SCHEMA: &str = "serviceradar.rdp.helper.open.v1";
const CLIENT_BUILD: u32 = 1;
const CLIENT_NAME: &str = "serviceradar";
const CLIENT_DIR: &str = "C:\\Windows\\System32\\mstscax.dll";
const CLIENT_ADDR: SocketAddr = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0);
const MAX_DIAL_HOST_LEN: usize = 253;

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

#[derive(Debug, Eq, PartialEq)]
pub struct LiveTlsUpgradeProbe {
    pub before_state: &'static str,
    pub after_begin_state: &'static str,
    pub after_upgrade_state: &'static str,
    pub peer_certificate_count: usize,
    pub server_public_key_len: usize,
    pub contains_cleartext_password: bool,
    pub wrote_tls_bytes: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub struct VerifiedTlsClientConfigProbe {
    pub trusted_root_count: usize,
    pub resumption_disabled_for_credssp: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ActiveStageSmokeProbe {
    pub desktop_width: u16,
    pub desktop_height: u16,
    pub accepts_mouse_position_update: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ActiveStageInputProbe {
    pub response_frames: usize,
    pub response_bytes: usize,
    pub graphics_updates: usize,
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

pub fn build_active_stage_smoke(
    request: ServiceRadarOpenRequest,
) -> Result<ActiveStageSmokeProbe, &'static str> {
    let (mut active_stage, desktop_size) = build_active_stage_for_probe(request)?;
    active_stage.update_mouse_pos(10, 20);

    Ok(ActiveStageSmokeProbe {
        desktop_width: desktop_size.width,
        desktop_height: desktop_size.height,
        accepts_mouse_position_update: true,
    })
}

pub fn encode_active_stage_keyboard_input_smoke(
    request: ServiceRadarOpenRequest,
) -> Result<ActiveStageInputProbe, &'static str> {
    let (mut active_stage, desktop_size) = build_active_stage_for_probe(request)?;
    let mut image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        desktop_size.width,
        desktop_size.height,
    );
    let outputs = active_stage
        .process_fastpath_input(
            &mut image,
            &[
                ironrdp_pdu::input::fast_path::FastPathInputEvent::KeyboardEvent(
                    ironrdp_pdu::input::fast_path::KeyboardFlags::empty(),
                    0x1e,
                ),
            ],
        )
        .map_err(|_| "active stage input encode failed")?;

    Ok(summarize_active_stage_outputs(outputs))
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
        alternate_shell: String::new(),
        work_dir: String::new(),
        platform: ironrdp_pdu::rdp::capability_sets::MajorPlatformType::UNIX,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        performance_flags: ironrdp_pdu::rdp::client_info::PerformanceFlags::default(),
        license_cache: None,
        timezone_info: ironrdp_pdu::rdp::client_info::TimezoneInfo::default(),
        compression_type: None,
        enable_server_pointer: false,
        pointer_software_rendering: false,
        multitransport_flags: None,
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
        if !tls_server_name_is_valid_dns_name(explicit_server_name) {
            return Err("tls server name is invalid");
        }

        return Ok(explicit_server_name.to_owned());
    }

    let upstream_host = request.target.upstream.host.trim();
    if upstream_host.is_empty() || !tls_server_name_is_valid_dns_name(upstream_host) {
        return Err("tls server name is required");
    }

    Ok(upstream_host.to_owned())
}

fn tls_server_name_is_valid_dns_name(name: &str) -> bool {
    if name.parse::<IpAddr>().is_ok()
        || name.is_empty()
        || name.len() > MAX_DIAL_HOST_LEN
        || name.starts_with('.')
        || name.ends_with('.')
    {
        return false;
    }

    name.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    })
}

fn build_active_stage_for_probe(
    request: ServiceRadarOpenRequest,
) -> Result<(ironrdp_session::ActiveStage, ironrdp_connector::DesktopSize), &'static str> {
    let plan = build_connector_plan(request)?;
    let config = plan.connector_config;
    let desktop_size = config.desktop_size;
    let connector = ironrdp_connector::ClientConnector::new(config.clone(), CLIENT_ADDR);
    let active_stage = ironrdp_session::ActiveStageBuilder {
        static_channels: connector.static_channels,
        user_channel_id: 1004,
        io_channel_id: 1003,
        message_channel_id: None,
        // This synthetic probe only encodes fast-path client input; no server
        // share-control frames are processed, so no negotiated share ID exists.
        share_id: 0,
        compression_type: None,
        enable_server_pointer: false,
        pointer_software_rendering: false,
    }
    .build();

    Ok((active_stage, desktop_size))
}

fn summarize_active_stage_outputs(
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
            | ironrdp_session::ActiveStageOutput::DeactivateAll
            | ironrdp_session::ActiveStageOutput::MultitransportRequest(_)
            | ironrdp_session::ActiveStageOutput::AutoDetect(_) => {}
        }
    }

    ActiveStageInputProbe {
        response_frames,
        response_bytes,
        graphics_updates,
    }
}
