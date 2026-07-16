use std::collections::BTreeMap;
use std::fmt;
use std::str::Utf8Error;

use serde::{Deserialize, de};
use zeroize::Zeroize;

use super::constants::MAX_TLS_CA_BUNDLE_PEM_BYTES;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpenPayload {
    pub schema: String,
    pub session_id: String,
    #[serde(default)]
    pub actor_id: String,
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
    #[serde(default, deserialize_with = "deserialize_ca_bundle_pem")]
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
    pub(super) fn clear_sensitive(&mut self) {
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
    pub(super) value: Vec<u8>,
}

impl SensitiveString {
    pub(super) fn is_empty(&self) -> bool {
        self.value.is_empty()
    }

    pub(crate) fn expose(&self) -> Result<&str, Utf8Error> {
        std::str::from_utf8(&self.value)
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

fn deserialize_ca_bundle_pem<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    struct BoundedCaBundleVisitor;

    impl de::Visitor<'_> for BoundedCaBundleVisitor {
        type Value = String;

        fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("a bounded PEM CA bundle string")
        }

        fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            if value.len() > MAX_TLS_CA_BUNDLE_PEM_BYTES {
                return Err(E::custom("CA bundle exceeds maximum length"));
            }

            Ok(value.to_owned())
        }

        fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            if value.len() > MAX_TLS_CA_BUNDLE_PEM_BYTES {
                return Err(E::custom("CA bundle exceeds maximum length"));
            }

            Ok(value)
        }
    }

    deserializer.deserialize_string(BoundedCaBundleVisitor)
}
