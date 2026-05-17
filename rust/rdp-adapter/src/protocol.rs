use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use serde::Deserialize;
use zeroize::Zeroize;

const OPEN_SCHEMA: &str = "serviceradar.rdp.helper.open.v1";
const PROTOCOL_RDP: &str = "rdp";
const PROTOCOL_DESKTOP: &str = "desktop";
const CREDENTIAL_MODE_MEMORY_USER: &str = "memory_user";
const CREDENTIAL_MODE_BROKERED_SECRET: &str = "brokered_secret";
const TLS_MODE_VERIFY: &str = "verify";
const TLS_MODE_PINNED_CA: &str = "pinned_ca";
const TLS_MODE_SYSTEM: &str = "system";
const NLA_MODE_REQUIRED: &str = "required";
const CLIPBOARD_MODE_DISABLED: &str = "disabled";
const ACK_TYPE: &str = "desktop_media_ack";
const FRAME_TYPE_INPUT: &str = "desktop.input";
const FRAME_TYPE_RESIZE: &str = "desktop.resize";
const FRAME_TYPE_QUALITY: &str = "desktop.quality";
const FRAME_TYPE_DISCONNECT: &str = "desktop.disconnect";
const INPUT_KIND_KEY: &str = "key";
const INPUT_KIND_POINTER: &str = "pointer";
const INPUT_KIND_FOCUS: &str = "focus";
const MEDIA_QUALITY_AUTO: &str = "auto";
const MEDIA_QUALITY_LOW: &str = "low";
const MAX_TCP_PORT: u32 = u16::MAX as u32;
const MAX_SCREEN_WIDTH: u32 = 7680;
const MAX_SCREEN_HEIGHT: u32 = 4320;
const MAX_FRAME_RATE: u32 = 60;
const MAX_BITRATE_BPS: u32 = 100_000_000;
const MAX_ACK_CREDIT_BYTES: u64 = 4 * 1024 * 1024;
const MAX_ACK_CLOSE_REASON_BYTES: usize = 256;
const MAX_INPUT_TOKEN_BYTES: usize = 128;
const MAX_CLOSE_REASON_BYTES: usize = 256;
const MAX_TLS_CA_BUNDLE_PEM_BYTES: usize = 256 * 1024;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpenPayload {
    pub schema: String,
    pub session_id: String,
    pub local_agent_id: String,
    #[serde(default)]
    pub gateway_id: String,
    pub start_unix: i64,
    pub target: DesktopTarget,
    #[serde(default)]
    pub credential_grant: Option<DesktopCredentialGrant>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopTarget {
    pub target_id: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub device_uid: String,
    pub protocol: String,
    pub route: DesktopRoute,
    pub upstream: DesktopUpstream,
    pub tls: DesktopTlsPolicy,
    pub credential: DesktopCredentialPolicy,
    pub screen: DesktopScreenPolicy,
    pub redirection: DesktopRedirectionPolicy,
    #[serde(default)]
    pub approval_required: bool,
    pub recording: DesktopRecordingPolicy,
    #[serde(default)]
    pub metadata: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopRoute {
    pub selected_agent_id: String,
    #[serde(default)]
    pub selected_gateway_id: String,
    #[serde(default)]
    pub allowed_agent_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopUpstream {
    pub host: String,
    pub port: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopTlsPolicy {
    pub mode: String,
    #[serde(default)]
    pub ca_bundle_id: String,
    #[serde(default)]
    pub ca_bundle_pem: String,
    #[serde(default)]
    pub nla_mode: String,
    #[serde(default)]
    pub server_name: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopCredentialPolicy {
    pub mode: String,
    #[serde(default)]
    pub allowed_principals: Vec<String>,
    #[serde(default)]
    pub credential_secret_ref: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopCredentialGrant {
    pub mode: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: SensitiveString,
    #[serde(default)]
    pub credential_secret_ref: SensitiveString,
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

impl DesktopCredentialGrant {
    fn clear_sensitive(&mut self) {
        self.username.clear();
        self.password.clear();
        self.credential_secret_ref.clear();
    }
}

impl Drop for DesktopCredentialGrant {
    fn drop(&mut self) {
        self.clear_sensitive();
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopScreenPolicy {
    pub max_width: u32,
    pub max_height: u32,
    #[serde(default)]
    pub color_depth: u32,
    pub frame_rate: u32,
    pub bitrate_bps: u32,
    pub idle_seconds: u32,
    pub ttl_seconds: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DesktopRedirectionPolicy {
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
pub struct DesktopRecordingPolicy {
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopFrame {
    pub session_id: String,
    pub protocol: String,
    pub frame_type: String,
    #[serde(default)]
    pub width: u32,
    #[serde(default)]
    pub height: u32,
    #[serde(default)]
    pub input: Option<DesktopInputEvent>,
    #[serde(default)]
    pub quality: Option<DesktopQuality>,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub timestamp: i64,
    #[serde(default)]
    pub metadata: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopInputEvent {
    pub kind: String,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub down: bool,
    #[serde(default)]
    pub button: String,
    #[serde(default)]
    pub x: u32,
    #[serde(default)]
    pub y: u32,
    #[serde(default)]
    pub focused: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopQuality {
    #[serde(default)]
    pub max_frame_rate: u32,
    #[serde(default)]
    pub max_bitrate_bps: u32,
    #[serde(default)]
    pub width: u32,
    #[serde(default)]
    pub height: u32,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopClosePayload {
    #[serde(default)]
    pub reason: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopMediaAckMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    #[serde(flatten)]
    pub ack: DesktopMediaAck,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopMediaAck {
    pub session_binding_id: String,
    pub media_session_id: String,
    pub last_accepted_seq: u64,
    pub credit_bytes: u64,
    #[serde(default)]
    pub quality_level: String,
    #[serde(default)]
    pub pause: bool,
    #[serde(default)]
    pub resume: bool,
    #[serde(default)]
    pub close_reason: String,
}

#[derive(Default, Eq, PartialEq)]
pub struct SensitiveString {
    value: Vec<u8>,
}

impl SensitiveString {
    fn is_empty(&self) -> bool {
        self.value.is_empty()
    }

    pub(crate) fn expose(&self) -> &str {
        std::str::from_utf8(&self.value).unwrap_or("")
    }

    fn clear(&mut self) {
        self.value.zeroize();
    }
}

impl fmt::Debug for SensitiveString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

impl Drop for SensitiveString {
    fn drop(&mut self) {
        self.clear();
    }
}

impl From<String> for SensitiveString {
    fn from(value: String) -> Self {
        Self {
            value: value.into_bytes(),
        }
    }
}

impl<'de> Deserialize<'de> for SensitiveString {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        String::deserialize(deserializer).map(Self::from)
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum OpenPayloadError {
    Decode,
    InvalidSchema,
    MissingSession,
    InvalidSessionPolicy,
    MissingAgent,
    UnsupportedProtocol,
    MissingRoute,
    MissingTarget,
    MissingUpstream,
    UnsupportedTlsPolicy,
    UnsupportedCredentialMode,
    InvalidScreenPolicy,
    UnsupportedRedirection,
    UnsupportedRecordingPolicy,
    InvalidCredentialGrant,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DesktopMediaAckError {
    Decode,
    InvalidType,
    MissingSession,
    SessionMismatch,
    MissingMediaSession,
    AmbiguousFlowControl,
    UnsupportedQuality,
    CreditTooLarge,
    CloseReasonTooLarge,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DesktopFrameError {
    Decode,
    MissingSession,
    SessionMismatch,
    UnsupportedProtocol,
    UnsupportedFrameType,
    InvalidDimensions,
    InvalidInputEvent,
    InputTokenTooLarge,
    PointerOutOfBounds,
    MissingQualityRequest,
    QualityExceedsPolicy,
    ReasonTooLarge,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DesktopClosePayloadError {
    Decode,
    ReasonTooLarge,
}

impl fmt::Display for DesktopMediaAckError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::InvalidType => f.write_str("ack type is unsupported"),
            Self::MissingSession => f.write_str("session binding id is required"),
            Self::SessionMismatch => f.write_str("session binding mismatch"),
            Self::MissingMediaSession => f.write_str("media session id is required"),
            Self::AmbiguousFlowControl => f.write_str("pause and resume cannot both be set"),
            Self::UnsupportedQuality => f.write_str("quality level is unsupported"),
            Self::CreditTooLarge => f.write_str("ack credit is too large"),
            Self::CloseReasonTooLarge => f.write_str("close reason is too large"),
        }
    }
}

impl Error for DesktopMediaAckError {}

impl fmt::Display for DesktopFrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::MissingSession => f.write_str("session id is required"),
            Self::SessionMismatch => f.write_str("session binding mismatch"),
            Self::UnsupportedProtocol => f.write_str("desktop protocol is unsupported"),
            Self::UnsupportedFrameType => f.write_str("desktop frame type is unsupported"),
            Self::InvalidDimensions => f.write_str("desktop dimensions are invalid"),
            Self::InvalidInputEvent => f.write_str("desktop input event is invalid"),
            Self::InputTokenTooLarge => f.write_str("desktop input token is too large"),
            Self::PointerOutOfBounds => f.write_str("desktop pointer coordinates exceed policy"),
            Self::MissingQualityRequest => f.write_str("desktop quality request is required"),
            Self::QualityExceedsPolicy => f.write_str("desktop quality request exceeds policy"),
            Self::ReasonTooLarge => f.write_str("desktop reason is too large"),
        }
    }
}

impl Error for DesktopFrameError {}

impl fmt::Display for DesktopClosePayloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::ReasonTooLarge => f.write_str("close reason is too large"),
        }
    }
}

impl Error for DesktopClosePayloadError {}

impl fmt::Display for OpenPayloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::InvalidSchema => f.write_str("schema is unsupported"),
            Self::MissingSession => f.write_str("session id is required"),
            Self::InvalidSessionPolicy => f.write_str("session policy is invalid"),
            Self::MissingAgent => f.write_str("local agent id is required"),
            Self::UnsupportedProtocol => f.write_str("target protocol is unsupported"),
            Self::MissingRoute => f.write_str("selected agent route is required"),
            Self::MissingTarget => f.write_str("target id is required"),
            Self::MissingUpstream => f.write_str("upstream host and port are required"),
            Self::UnsupportedTlsPolicy => f.write_str("target TLS/NLA policy is unsupported"),
            Self::UnsupportedCredentialMode => f.write_str("credential mode is unsupported"),
            Self::InvalidScreenPolicy => f.write_str("desktop screen policy is invalid"),
            Self::UnsupportedRedirection => {
                f.write_str("desktop redirection policy is unsupported")
            }
            Self::UnsupportedRecordingPolicy => {
                f.write_str("desktop content recording policy is unsupported")
            }
            Self::InvalidCredentialGrant => f.write_str("credential grant is invalid"),
        }
    }
}

impl Error for OpenPayloadError {}

pub fn parse_open_payload(payload: &[u8]) -> Result<OpenPayload, OpenPayloadError> {
    let parsed: OpenPayload =
        serde_json::from_slice(payload).map_err(|_| OpenPayloadError::Decode)?;
    validate_open_payload(&parsed)?;

    Ok(parsed)
}

pub fn parse_desktop_media_ack(
    payload: &[u8],
    session_id: &str,
) -> Result<DesktopMediaAck, DesktopMediaAckError> {
    let mut parsed: DesktopMediaAckMessage =
        serde_json::from_slice(payload).map_err(|_| DesktopMediaAckError::Decode)?;
    validate_desktop_media_ack_message(&parsed, session_id)?;
    parsed.ack.close_reason =
        normalize_terminal_reason(&parsed.ack.close_reason, MAX_ACK_CLOSE_REASON_BYTES);

    Ok(parsed.ack)
}

pub fn parse_desktop_frame(
    payload: &[u8],
    session_id: &str,
    policy: &DesktopScreenPolicy,
) -> Result<DesktopFrame, DesktopFrameError> {
    let mut parsed: DesktopFrame =
        serde_json::from_slice(payload).map_err(|_| DesktopFrameError::Decode)?;
    validate_desktop_frame(&parsed, session_id, policy)?;
    if parsed.frame_type == FRAME_TYPE_DISCONNECT {
        parsed.reason = normalize_terminal_reason(&parsed.reason, MAX_CLOSE_REASON_BYTES);
    }

    Ok(parsed)
}

pub fn parse_desktop_close_payload(
    payload: &[u8],
) -> Result<DesktopClosePayload, DesktopClosePayloadError> {
    if payload.is_empty() {
        return Ok(DesktopClosePayload::default());
    }

    let mut parsed: DesktopClosePayload =
        serde_json::from_slice(payload).map_err(|_| DesktopClosePayloadError::Decode)?;
    if parsed.reason.trim().len() > MAX_CLOSE_REASON_BYTES {
        return Err(DesktopClosePayloadError::ReasonTooLarge);
    }
    parsed.reason = normalize_terminal_reason(&parsed.reason, MAX_CLOSE_REASON_BYTES);

    Ok(parsed)
}

fn normalize_terminal_reason(reason: &str, max_bytes: usize) -> String {
    let reason = reason.trim();
    if reason.is_empty() {
        return String::new();
    }

    let mut normalized = String::with_capacity(reason.len().min(max_bytes));
    for ch in reason.chars() {
        let ch = if ch.is_control() { ' ' } else { ch };
        let mut encoded = [0; 4];
        let rendered = ch.encode_utf8(&mut encoded);
        if normalized.len() + rendered.len() > max_bytes {
            break;
        }
        normalized.push(ch);
    }

    normalized.trim().to_owned()
}

fn validate_open_payload(payload: &OpenPayload) -> Result<(), OpenPayloadError> {
    if payload.schema != OPEN_SCHEMA {
        return Err(OpenPayloadError::InvalidSchema);
    }
    if payload.session_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingSession);
    }
    if payload.start_unix <= 0 {
        return Err(OpenPayloadError::InvalidSessionPolicy);
    }
    if payload.local_agent_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingAgent);
    }

    let target = &payload.target;
    if target.target_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingTarget);
    }
    if target.protocol != PROTOCOL_RDP && target.protocol != PROTOCOL_DESKTOP {
        return Err(OpenPayloadError::UnsupportedProtocol);
    }
    if target.route.selected_agent_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingRoute);
    }
    if target.route.selected_agent_id != payload.local_agent_id {
        return Err(OpenPayloadError::MissingRoute);
    }
    if !helper_route_policy_supported(&target.route) {
        return Err(OpenPayloadError::MissingRoute);
    }
    if !payload.gateway_id.is_empty()
        && !target.route.selected_gateway_id.is_empty()
        && target.route.selected_gateway_id != payload.gateway_id
    {
        return Err(OpenPayloadError::MissingRoute);
    }
    if target.upstream.host.trim().is_empty()
        || target.upstream.port == 0
        || target.upstream.port > MAX_TCP_PORT
    {
        return Err(OpenPayloadError::MissingUpstream);
    }
    if !helper_tls_policy_supported(&target.tls) {
        return Err(OpenPayloadError::UnsupportedTlsPolicy);
    }
    if !helper_credential_policy_supported(&target.credential) {
        return Err(OpenPayloadError::UnsupportedCredentialMode);
    }
    if !helper_screen_policy_supported(&target.screen) {
        return Err(OpenPayloadError::InvalidScreenPolicy);
    }
    if !helper_redirection_policy_supported(&target.redirection) {
        return Err(OpenPayloadError::UnsupportedRedirection);
    }
    if !helper_recording_policy_supported(&target.recording) {
        return Err(OpenPayloadError::UnsupportedRecordingPolicy);
    }

    validate_credential_grant(payload)
}

fn validate_desktop_frame(
    frame: &DesktopFrame,
    session_id: &str,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    if frame.session_id.trim().is_empty() {
        return Err(DesktopFrameError::MissingSession);
    }
    if !session_id.is_empty() && frame.session_id != session_id {
        return Err(DesktopFrameError::SessionMismatch);
    }
    if frame.protocol != PROTOCOL_RDP && frame.protocol != PROTOCOL_DESKTOP {
        return Err(DesktopFrameError::UnsupportedProtocol);
    }

    match frame.frame_type.as_str() {
        FRAME_TYPE_INPUT => validate_desktop_input_frame(frame, policy),
        FRAME_TYPE_RESIZE => validate_desktop_dimensions(frame.width, frame.height, policy),
        FRAME_TYPE_QUALITY => validate_desktop_quality_frame(frame, policy),
        FRAME_TYPE_DISCONNECT => {
            if frame.reason.trim().len() > MAX_CLOSE_REASON_BYTES {
                return Err(DesktopFrameError::ReasonTooLarge);
            }

            Ok(())
        }
        _ => Err(DesktopFrameError::UnsupportedFrameType),
    }
}

fn validate_desktop_input_frame(
    frame: &DesktopFrame,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    let Some(input) = frame.input.as_ref() else {
        return Err(DesktopFrameError::InvalidInputEvent);
    };
    if !matches!(
        input.kind.as_str(),
        INPUT_KIND_KEY | INPUT_KIND_POINTER | INPUT_KIND_FOCUS
    ) {
        return Err(DesktopFrameError::InvalidInputEvent);
    }
    if input.key.len() > MAX_INPUT_TOKEN_BYTES || input.button.len() > MAX_INPUT_TOKEN_BYTES {
        return Err(DesktopFrameError::InputTokenTooLarge);
    }
    if input.kind == INPUT_KIND_POINTER
        && (input.x > policy.max_width || input.y > policy.max_height)
    {
        return Err(DesktopFrameError::PointerOutOfBounds);
    }

    Ok(())
}

fn validate_desktop_dimensions(
    width: u32,
    height: u32,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    if width == 0 || height == 0 || width > policy.max_width || height > policy.max_height {
        return Err(DesktopFrameError::InvalidDimensions);
    }

    Ok(())
}

fn validate_desktop_quality_frame(
    frame: &DesktopFrame,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopFrameError> {
    let Some(quality) = frame.quality.as_ref() else {
        return Err(DesktopFrameError::MissingQualityRequest);
    };
    if quality.max_frame_rate > policy.frame_rate
        || quality.max_bitrate_bps > policy.bitrate_bps
        || quality.width > policy.max_width
        || quality.height > policy.max_height
    {
        return Err(DesktopFrameError::QualityExceedsPolicy);
    }

    Ok(())
}

fn validate_desktop_media_ack_message(
    message: &DesktopMediaAckMessage,
    session_id: &str,
) -> Result<(), DesktopMediaAckError> {
    if message.message_type != ACK_TYPE {
        return Err(DesktopMediaAckError::InvalidType);
    }

    let ack = &message.ack;
    if ack.session_binding_id.trim().is_empty() {
        return Err(DesktopMediaAckError::MissingSession);
    }
    if !session_id.is_empty() && ack.session_binding_id != session_id {
        return Err(DesktopMediaAckError::SessionMismatch);
    }
    if ack.media_session_id.trim().is_empty() {
        return Err(DesktopMediaAckError::MissingMediaSession);
    }
    if ack.pause && ack.resume {
        return Err(DesktopMediaAckError::AmbiguousFlowControl);
    }
    if !matches!(
        ack.quality_level.as_str(),
        "" | MEDIA_QUALITY_AUTO | MEDIA_QUALITY_LOW
    ) {
        return Err(DesktopMediaAckError::UnsupportedQuality);
    }
    if ack.credit_bytes > MAX_ACK_CREDIT_BYTES {
        return Err(DesktopMediaAckError::CreditTooLarge);
    }
    if ack.close_reason.trim().len() > MAX_ACK_CLOSE_REASON_BYTES {
        return Err(DesktopMediaAckError::CloseReasonTooLarge);
    }

    Ok(())
}

fn helper_route_policy_supported(route: &DesktopRoute) -> bool {
    route.allowed_agent_ids.is_empty()
        || route
            .allowed_agent_ids
            .iter()
            .any(|agent_id| agent_id == &route.selected_agent_id)
}

fn helper_tls_policy_supported(policy: &DesktopTlsPolicy) -> bool {
    if policy.nla_mode != NLA_MODE_REQUIRED
        || policy.ca_bundle_pem.len() > MAX_TLS_CA_BUNDLE_PEM_BYTES
    {
        return false;
    }

    let has_bundle_id = !policy.ca_bundle_id.trim().is_empty();
    let has_bundle_pem = !policy.ca_bundle_pem.trim().is_empty();
    let bundle_pair_valid = has_bundle_id == has_bundle_pem;

    match policy.mode.as_str() {
        TLS_MODE_VERIFY => bundle_pair_valid,
        TLS_MODE_PINNED_CA => has_bundle_id && has_bundle_pem,
        TLS_MODE_SYSTEM => !has_bundle_id && !has_bundle_pem,
        _ => false,
    }
}

fn helper_credential_policy_supported(policy: &DesktopCredentialPolicy) -> bool {
    matches!(
        policy.mode.as_str(),
        CREDENTIAL_MODE_MEMORY_USER | CREDENTIAL_MODE_BROKERED_SECRET
    )
}

fn helper_screen_policy_supported(policy: &DesktopScreenPolicy) -> bool {
    policy.max_width > 0
        && policy.max_width <= MAX_SCREEN_WIDTH
        && policy.max_height > 0
        && policy.max_height <= MAX_SCREEN_HEIGHT
        && policy.frame_rate > 0
        && policy.frame_rate <= MAX_FRAME_RATE
        && policy.bitrate_bps > 0
        && policy.bitrate_bps <= MAX_BITRATE_BPS
        && policy.idle_seconds > 0
        && policy.ttl_seconds > 0
}

fn helper_redirection_policy_supported(policy: &DesktopRedirectionPolicy) -> bool {
    policy.clipboard_mode == CLIPBOARD_MODE_DISABLED
        && !policy.drive
        && !policy.printer
        && !policy.audio
        && !policy.smart_card
        && !policy.file_copy
}

fn helper_recording_policy_supported(policy: &DesktopRecordingPolicy) -> bool {
    policy.metadata_enabled
        && !policy.screen_enabled
        && !policy.clipboard_enabled
        && !policy.file_enabled
        && !policy.audio_enabled
}

fn validate_credential_grant(payload: &OpenPayload) -> Result<(), OpenPayloadError> {
    let Some(grant) = &payload.credential_grant else {
        return Ok(());
    };
    let target = &payload.target;

    if grant.mode != target.credential.mode {
        return Err(OpenPayloadError::InvalidCredentialGrant);
    }
    if !grant.target_id.is_empty() && grant.target_id != target.target_id {
        return Err(OpenPayloadError::InvalidCredentialGrant);
    }
    if !grant.session_id.is_empty() && grant.session_id != payload.session_id {
        return Err(OpenPayloadError::InvalidCredentialGrant);
    }

    match grant.mode.as_str() {
        CREDENTIAL_MODE_MEMORY_USER => {
            if grant.username.trim().is_empty() || grant.password.is_empty() {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
            if grant.session_id.trim().is_empty()
                || grant.target_id.trim().is_empty()
                || grant.session_id != payload.session_id
                || grant.target_id != target.target_id
            {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
            if !target.credential.allowed_principals.is_empty()
                && !target
                    .credential
                    .allowed_principals
                    .iter()
                    .any(|principal| principal == &grant.username)
            {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
        }
        CREDENTIAL_MODE_BROKERED_SECRET => {
            if grant.credential_secret_ref.is_empty()
                || grant.credential_secret_ref.expose() != target.credential.credential_secret_ref
                || !grant.password.is_empty()
                || grant.actor_id.trim().is_empty()
                || grant.session_id.trim().is_empty()
                || grant.route_id.trim().is_empty()
                || grant.session_id != payload.session_id
                || grant.route_id != target.route.selected_agent_id
                || grant.expires_unix <= 0
            {
                return Err(OpenPayloadError::InvalidCredentialGrant);
            }
        }
        _ => {}
    }

    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn valid_open_payload() -> String {
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
            "credential_grant":{"mode":"memory_user","username":"alice","password":"secret","session_id":"session-1","target_id":"target-1"}
        }"#
        .to_string()
    }

    #[test]
    fn parse_open_payload_accepts_valid_memory_user_payload() {
        let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");

        assert_eq!(payload.session_id, "session-1");
        assert_eq!(payload.target.upstream.host, "win.example");
        assert_eq!(
            payload
                .credential_grant
                .as_ref()
                .map(|grant| grant.username.as_str()),
            Some("alice")
        );
    }

    #[test]
    fn parse_open_payload_accepts_verify_ca_bundle_material() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"corp-rdp-ca","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");

        assert_eq!(payload.target.tls.ca_bundle_id, "corp-rdp-ca");
        assert!(payload
            .target
            .tls
            .ca_bundle_pem
            .starts_with("-----BEGIN CERTIFICATE-----"));
    }

    #[test]
    fn parse_desktop_media_ack_accepts_valid_ack_payload() {
        let ack = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"quality_level":"low","pause":true}"#,
            "session-1",
        )
        .expect("valid ack");

        assert_eq!(ack.session_binding_id, "session-1");
        assert_eq!(ack.media_session_id, "media-1");
        assert_eq!(ack.last_accepted_seq, 7);
        assert_eq!(ack.credit_bytes, 8192);
        assert_eq!(ack.quality_level, "low");
        assert!(ack.pause);
    }

    #[test]
    fn parse_desktop_media_ack_normalizes_close_reason() {
        let ack = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"close_reason":" browser\nclosed\t"}"#,
            "session-1",
        )
        .expect("valid ack");

        assert_eq!(ack.close_reason, "browser closed");
    }

    #[test]
    fn parse_desktop_media_ack_rejects_session_mismatch() {
        let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"other-session","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192}"#,
            "session-1",
        )
        .expect_err("ack rejected");

        assert_eq!(err, DesktopMediaAckError::SessionMismatch);
    }

    #[test]
    fn parse_desktop_media_ack_rejects_unsupported_quality() {
        let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"quality_level":"ultra"}"#,
            "session-1",
        )
        .expect_err("ack rejected");

        assert_eq!(err, DesktopMediaAckError::UnsupportedQuality);
    }

    #[test]
    fn parse_desktop_media_ack_rejects_oversized_credit() {
        let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":4194305}"#,
            "session-1",
        )
        .expect_err("ack rejected");

        assert_eq!(err, DesktopMediaAckError::CreditTooLarge);
    }

    #[test]
    fn parse_desktop_media_ack_rejects_ambiguous_pause_resume() {
        let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"pause":true,"resume":true}"#,
            "session-1",
        )
        .expect_err("ack rejected");

        assert_eq!(err, DesktopMediaAckError::AmbiguousFlowControl);
    }

    #[test]
    fn parse_desktop_frame_accepts_valid_input_payload() {
        let policy = test_screen_policy();
        let frame = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"pointer","x":640,"y":360}}"#,
            "session-1",
            &policy,
        )
        .expect("valid frame");

        assert_eq!(frame.session_id, "session-1");
        assert_eq!(frame.frame_type, FRAME_TYPE_INPUT);
        assert_eq!(
            frame.input.as_ref().map(|input| input.kind.as_str()),
            Some(INPUT_KIND_POINTER)
        );
    }

    #[test]
    fn parse_desktop_frame_rejects_session_mismatch() {
        let policy = test_screen_policy();
        let err = parse_desktop_frame(
            br#"{"session_id":"other-session","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"key","key":"Enter"}}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

        assert_eq!(err, DesktopFrameError::SessionMismatch);
    }

    #[test]
    fn parse_desktop_frame_rejects_pointer_out_of_bounds() {
        let policy = test_screen_policy();
        let err = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"pointer","x":1921,"y":360}}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

        assert_eq!(err, DesktopFrameError::PointerOutOfBounds);
    }

    #[test]
    fn parse_desktop_frame_rejects_quality_above_policy() {
        let policy = test_screen_policy();
        let err = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.quality","quality":{"max_frame_rate":61}}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

        assert_eq!(err, DesktopFrameError::QualityExceedsPolicy);
    }

    #[test]
    fn parse_desktop_frame_rejects_screen_update_on_input_channel() {
        let policy = test_screen_policy();
        let err = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.update","width":640,"height":360}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

        assert_eq!(err, DesktopFrameError::UnsupportedFrameType);
    }

    #[test]
    fn parse_desktop_frame_normalizes_disconnect_reason() {
        let policy = test_screen_policy();
        let frame = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.disconnect","reason":" browser\ndisconnect\t"}"#,
            "session-1",
            &policy,
        )
        .expect("valid disconnect frame");

        assert_eq!(frame.reason, "browser disconnect");
    }

    #[test]
    fn parse_desktop_close_payload_accepts_empty_or_reason_payload() {
        let empty = parse_desktop_close_payload(b"").expect("empty close payload");
        let reason =
            parse_desktop_close_payload(br#"{"reason":"operator"}"#).expect("reason close payload");

        assert_eq!(empty, DesktopClosePayload::default());
        assert_eq!(
            reason,
            DesktopClosePayload {
                reason: "operator".to_owned()
            }
        );
    }

    #[test]
    fn parse_desktop_close_payload_normalizes_reason() {
        let close = parse_desktop_close_payload(br#"{"reason":" operator\nclosed\t"}"#)
            .expect("valid close payload");

        assert_eq!(
            close,
            DesktopClosePayload {
                reason: "operator closed".to_owned()
            }
        );
    }

    #[test]
    fn parse_desktop_close_payload_rejects_oversized_reason() {
        let reason = "x".repeat(MAX_CLOSE_REASON_BYTES + 1);
        let err = parse_desktop_close_payload(format!(r#"{{"reason":"{reason}"}}"#).as_bytes())
            .expect_err("close payload rejected");

        assert_eq!(err, DesktopClosePayloadError::ReasonTooLarge);
    }

    #[test]
    fn parse_open_payload_rejects_unsupported_schema() {
        let raw = valid_open_payload().replace(
            r#""schema":"serviceradar.rdp.helper.open.v1""#,
            r#""schema":"wrong""#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("schema rejected");

        assert_eq!(err, OpenPayloadError::InvalidSchema);
    }

    #[test]
    fn parse_open_payload_rejects_memory_user_missing_password() {
        let raw = valid_open_payload().replace(r#""password":"secret","#, "");
        let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

        assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
    }

    #[test]
    fn parse_open_payload_rejects_brokered_secret_with_password() {
        let raw = r#"{
            "schema":"serviceradar.rdp.helper.open.v1",
            "session_id":"session-1",
            "local_agent_id":"agent-1",
            "start_unix":1778636531,
            "target":{
                "target_id":"target-1",
                "protocol":"rdp",
                "route":{"selected_agent_id":"agent-1"},
                "upstream":{"host":"win.example","port":3389},
                "tls":{"mode":"verify","nla_mode":"required"},
                "credential":{"mode":"brokered_secret","credential_secret_ref":"secret/ref"},
                "screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600},
                "redirection":{"clipboard_mode":"disabled"},
                "recording":{"metadata_enabled":true}
            },
            "credential_grant":{
                "mode":"brokered_secret",
                "credential_secret_ref":"secret/ref",
                "password":"not-allowed",
                "actor_id":"user-1",
                "session_id":"session-1",
                "target_id":"target-1",
                "route_id":"route-1",
                "expires_unix":1778640000
            }
        }"#;
        let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

        assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
    }

    #[test]
    fn parse_open_payload_rejects_grant_session_mismatch() {
        let raw = valid_open_payload().replace(
            r#""session_id":"session-1","target_id":"target-1""#,
            r#""session_id":"other-session","target_id":"target-1""#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

        assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
    }

    #[test]
    fn parse_open_payload_rejects_memory_user_missing_binding() {
        let raw =
            valid_open_payload().replace(r#","session_id":"session-1","target_id":"target-1""#, "");
        let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

        assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
    }

    #[test]
    fn parse_open_payload_rejects_memory_user_target_mismatch() {
        let raw = valid_open_payload().replace(
            r#""session_id":"session-1","target_id":"target-1""#,
            r#""session_id":"session-1","target_id":"other-target""#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

        assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
    }

    #[test]
    fn parse_open_payload_rejects_route_mismatch() {
        let raw = valid_open_payload().replace(
            r#""local_agent_id":"agent-1""#,
            r#""local_agent_id":"agent-2""#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("route rejected");

        assert_eq!(err, OpenPayloadError::MissingRoute);
    }

    #[test]
    fn parse_open_payload_rejects_invalid_start_timestamp() {
        let raw = valid_open_payload().replace(r#""start_unix":1778636531"#, r#""start_unix":0"#);
        let err = parse_open_payload(raw.as_bytes()).expect_err("session policy rejected");

        assert_eq!(err, OpenPayloadError::InvalidSessionPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_selected_agent_outside_allowed_route_set() {
        let raw = valid_open_payload().replace(
            r#""route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1"}"#,
            r#""route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1","allowed_agent_ids":["agent-2"]}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("route allowlist rejected");

        assert_eq!(err, OpenPayloadError::MissingRoute);
    }

    #[test]
    fn parse_open_payload_rejects_unsupported_tls_policy() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"insecure","nla_mode":"disabled","server_name":"win.example"}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_pinned_ca_without_bundle_id() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","nla_mode":"required","server_name":"win.example"}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_ca_bundle_id_without_material() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"corp-rdp-ca","nla_mode":"required","server_name":"win.example"}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_ca_bundle_material_without_id() {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_oversized_ca_bundle_material() {
        let oversized = "a".repeat(MAX_TLS_CA_BUNDLE_PEM_BYTES + 1);
        let replacement = format!(
            r#""tls":{{"mode":"verify","ca_bundle_id":"corp-rdp-ca","ca_bundle_pem":"{}","nla_mode":"required","server_name":"win.example"}}"#,
            oversized
        );
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            &replacement,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_unsupported_credential_policy() {
        let raw = valid_open_payload().replace(
            r#""credential":{"mode":"memory_user","allowed_principals":["alice"]}"#,
            r#""credential":{"mode":"domain_delegation","allowed_principals":["alice"]}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("credential policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedCredentialMode);
    }

    #[test]
    fn parse_open_payload_rejects_invalid_screen_policy() {
        let raw = valid_open_payload().replace(
            r#""screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600}"#,
            r#""screen":{"max_width":7681,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("screen policy rejected");

        assert_eq!(err, OpenPayloadError::InvalidScreenPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_unsupported_redirection_policy() {
        let raw = valid_open_payload().replace(
            r#""redirection":{"clipboard_mode":"disabled"}"#,
            r#""redirection":{"clipboard_mode":"text_bidirectional","drive":true}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("redirection policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedRedirection);
    }

    #[test]
    fn parse_open_payload_rejects_content_recording_policy() {
        let raw = valid_open_payload().replace(
            r#""recording":{"metadata_enabled":true}"#,
            r#""recording":{"metadata_enabled":true,"screen_enabled":true}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("recording policy rejected");

        assert_eq!(err, OpenPayloadError::UnsupportedRecordingPolicy);
    }

    #[test]
    fn parse_open_payload_rejects_out_of_range_upstream_port() {
        let raw = valid_open_payload().replace(
            r#""upstream":{"host":"win.example","port":3389}"#,
            r#""upstream":{"host":"win.example","port":70000}"#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("upstream port rejected");

        assert_eq!(err, OpenPayloadError::MissingUpstream);
    }

    #[test]
    fn credential_grant_clear_sensitive_drops_user_material() {
        let mut payload =
            parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
        let grant = payload.credential_grant.as_mut().expect("credential grant");

        grant.clear_sensitive();

        assert!(grant.username.is_empty());
        assert!(grant.password.is_empty());
        assert!(grant.credential_secret_ref.is_empty());
    }

    #[test]
    fn sensitive_string_debug_is_redacted() {
        let secret = SensitiveString::from("secret".to_string());

        assert_eq!(format!("{secret:?}"), "<redacted>");
    }

    fn test_screen_policy() -> DesktopScreenPolicy {
        DesktopScreenPolicy {
            max_width: 1920,
            max_height: 1080,
            color_depth: 0,
            frame_rate: 30,
            bitrate_bps: 8_000_000,
            idle_seconds: 900,
            ttl_seconds: 3600,
        }
    }
}
