use crate::backend::{BackendError, RdpBackend, RdpBackendSession};
#[cfg(serviceradar_rdp_connector_link_probe)]
use crate::media_frame::{
    encode_desktop_media_frame, DesktopMediaFrame, DesktopMediaPayloadFamily,
};
use crate::protocol::{DesktopCredentialGrant, OpenPayload};
#[cfg(serviceradar_rdp_connector_link_probe)]
use crate::protocol::{DesktopFrame, DesktopScreenPolicy};
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::collections::VecDeque;
#[cfg(serviceradar_rdp_connector_link_probe)]
use std::io::{self, Read, Write};
use zeroize::Zeroizing;

const CONNECTOR_NOT_IMPLEMENTED: &str =
    "IronRDP backend is linked, but the connector loop is not implemented";
const MEMORY_USER_REQUIRED: &str =
    "IronRDP backend currently requires a memory-user credential grant";
const INVALID_CONNECTION_PLAN: &str = "IronRDP connection plan is invalid";
const TLS_MODE_PINNED_CA: &str = "pinned_ca";
const TLS_MODE_VERIFY: &str = "verify";
const TLS_MODE_SYSTEM: &str = "system";
#[cfg(serviceradar_rdp_connector_link_probe)]
const UNSUPPORTED_INPUT_EVENT: &str = "IronRDP input event is unsupported";
#[cfg(serviceradar_rdp_connector_link_probe)]
const INVALID_GRAPHICS_UPDATE: &str = "IronRDP graphics update is invalid";

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
    RegisteredCaBundle(String),
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
        let (active_stage, desktop_size) = build_active_stage_for_probe(plan, credential);
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

    fn drain_media_frames(&mut self) -> Vec<Vec<u8>> {
        self.media_queue.drain(..).collect()
    }

    fn upstream_ref(&self) -> &W {
        &self.upstream
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[derive(Debug, Eq, PartialEq)]
struct VerifiedTlsPeerPublicKeyForProbe {
    bytes: Vec<u8>,
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
        let _plan = build_nonsecret_connection_plan(&request)?;
        let credential = build_memory_user_credential(grant)?;
        if !credential.has_material() {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let _connector_identity = credential.connector_identity();

        // Keep connector readiness false until the real IronRDP loop consumes
        // only zeroizing credential wrappers and proves cleanup ordering.
        Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
    }
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
        ironrdp_connector::ClientConnector::new(config, "127.0.0.1:0".parse().expect("loopback"));
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
        ironrdp_connector::ClientConnector::new(config, "127.0.0.1:0".parse().expect("loopback"));
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
    let config = build_connector_config_for_probe(plan, credential);
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, "127.0.0.1:0".parse().expect("loopback"));
    let mut framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![server_confirm]));

    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    Ok(BlockingConnectBeginProbe {
        requires_security_upgrade: should_upgrade,
        contains_cleartext_password: bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ),
        written_bytes: stream.writes,
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn drive_blocking_connect_finalize_for_probe(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
    server_public_key: VerifiedTlsPeerPublicKeyForProbe,
) -> Result<BlockingConnectFinalizeProbe, BackendError> {
    let server_public_key = server_public_key.into_bytes();
    if server_public_key.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let config = build_connector_config_for_probe(plan, credential);
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)?;
    let mut connector =
        ironrdp_connector::ClientConnector::new(config, "127.0.0.1:0".parse().expect("loopback"));
    let mut framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![server_confirm]));
    let should_upgrade = ironrdp_blocking::connect_begin(&mut framed, &mut connector)
        .map_err(|_| BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))?;
    let (_stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let upgraded = ironrdp_blocking::mark_as_upgraded(should_upgrade, &mut connector);
    let mut upgraded_framed = ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new()));
    let mut network_client = RejectingNetworkClient;
    let finalize = ironrdp_blocking::connect_finalize(
        upgraded,
        connector,
        &mut upgraded_framed,
        &mut network_client,
        plan.tls_server_name.clone().into(),
        server_public_key,
        None,
    );
    if finalize.is_ok() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    let (stream, leftover) = upgraded_framed.into_inner();
    if !leftover.is_empty() {
        return Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    }

    Ok(BlockingConnectFinalizeProbe {
        wrote_credssp_bytes: !stream.writes.is_empty(),
        contains_cleartext_password: bytes_contain_secret(
            &stream.writes,
            credential.password.value.as_str().as_bytes(),
        ),
        written_bytes: stream.writes,
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
    let config = build_connector_config_for_probe(plan, credential);
    let desktop_size = config.desktop_size;
    let connector = ironrdp_connector::ClientConnector::new(
        config.clone(),
        "127.0.0.1:0".parse().expect("loopback"),
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

    (
        ironrdp_session::ActiveStage::new(connection_result),
        desktop_size,
    )
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

    match request.target.tls.mode.as_str() {
        TLS_MODE_SYSTEM => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY if ca_bundle_id.is_empty() => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY => Ok(TlsTrustSource::RegisteredCaBundle(ca_bundle_id.to_owned())),
        TLS_MODE_PINNED_CA if ca_bundle_id.is_empty() => {
            Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN))
        }
        TLS_MODE_PINNED_CA => Ok(TlsTrustSource::RegisteredCaBundle(ca_bundle_id.to_owned())),
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
            r#""tls":{"mode":"verify","ca_bundle_id":"ca-rdp-prod","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan.tls_trust_source,
            TlsTrustSource::RegisteredCaBundle("ca-rdp-prod".to_owned())
        );
    }

    #[test]
    fn nonsecret_connection_plan_requires_registered_ca_bundle_for_pinned_ca() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let err = build_nonsecret_connection_plan(&payload).expect_err("pinned CA rejected");

        assert_eq!(err, BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    #[test]
    fn nonsecret_connection_plan_uses_registered_ca_bundle_for_pinned_ca() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","ca_bundle_id":"ca-rdp-prod","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
        let plan = build_nonsecret_connection_plan(&payload).expect("plan");

        assert_eq!(
            plan.tls_trust_source,
            TlsTrustSource::RegisteredCaBundle("ca-rdp-prod".to_owned())
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
}
