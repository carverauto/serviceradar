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
    MissingAgent,
    UnsupportedProtocol,
    MissingRoute,
    MissingTarget,
    MissingUpstream,
    InvalidCredentialGrant,
}

impl fmt::Display for OpenPayloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::InvalidSchema => f.write_str("schema is unsupported"),
            Self::MissingSession => f.write_str("session id is required"),
            Self::MissingAgent => f.write_str("local agent id is required"),
            Self::UnsupportedProtocol => f.write_str("target protocol is unsupported"),
            Self::MissingRoute => f.write_str("selected agent route is required"),
            Self::MissingTarget => f.write_str("target id is required"),
            Self::MissingUpstream => f.write_str("upstream host and port are required"),
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

fn validate_open_payload(payload: &OpenPayload) -> Result<(), OpenPayloadError> {
    if payload.schema != OPEN_SCHEMA {
        return Err(OpenPayloadError::InvalidSchema);
    }
    if payload.session_id.trim().is_empty() {
        return Err(OpenPayloadError::MissingSession);
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
    if !payload.gateway_id.is_empty()
        && !target.route.selected_gateway_id.is_empty()
        && target.route.selected_gateway_id != payload.gateway_id
    {
        return Err(OpenPayloadError::MissingRoute);
    }
    if target.upstream.host.trim().is_empty() || target.upstream.port == 0 {
        return Err(OpenPayloadError::MissingUpstream);
    }

    validate_credential_grant(payload)
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
                "tls":{"mode":"verify"},
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
    fn parse_open_payload_rejects_route_mismatch() {
        let raw = valid_open_payload().replace(
            r#""local_agent_id":"agent-1""#,
            r#""local_agent_id":"agent-2""#,
        );
        let err = parse_open_payload(raw.as_bytes()).expect_err("route rejected");

        assert_eq!(err, OpenPayloadError::MissingRoute);
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
}
