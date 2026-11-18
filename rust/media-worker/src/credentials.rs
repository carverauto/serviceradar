//! Redacted, zeroized short-lived credential and pre-signed URL wrappers (`2.3`).
//!
//! Ensures control-plane workload tokens, short-lived AWS SigV4 pre-signed `GET`
//! URLs, and optional test/fallback reader credentials are zeroed out of process
//! memory on drop and never appear in `Debug` or `Serialize` output.

use core::fmt::{self, Debug, Formatter};
use serde::de::Deserializer;
use serde::ser::{SerializeStruct, Serializer};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

/// Short-lived AWS SigV4 query-string pre-signed `GET` URL (`Zeroizing<String>`)
/// whose query signature (`X-Amz-Signature`, `X-Amz-Security-Token`, `X-Amz-Credential`)
/// is zeroed from worker RAM on drop and redacted on `Debug` and `Serialize`.
#[derive(Clone, PartialEq, Eq)]
pub struct RedactedPresignedUrl(Zeroizing<String>);

impl RedactedPresignedUrl {
    pub fn new(url: impl Into<String>) -> Self {
        Self(Zeroizing::new(url.into()))
    }

    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    /// Returns `<scheme>://<authority><path>?[REDACTED]` with query parameters stripped.
    pub fn redacted_target(&self) -> String {
        match self.0.split_once('?') {
            Some((base, _)) => format!("{base}?[REDACTED]"),
            None => "[REDACTED]".to_string(),
        }
    }
}

impl Debug for RedactedPresignedUrl {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.write_str("\"[REDACTED]\"")
    }
}

impl Serialize for RedactedPresignedUrl {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str("[REDACTED]")
    }
}

impl<'de> Deserialize<'de> for RedactedPresignedUrl {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        Ok(Self::new(raw))
    }
}

/// Domain-separated `media_worker` workload authentication credentials for
/// `POST /v1/media/workers/read-grants`.
#[derive(Clone, PartialEq, Eq)]
pub struct WorkerAuthCredentials {
    token: Zeroizing<String>,
    deployment_ref: String,
    generation: String,
}

impl WorkerAuthCredentials {
    pub fn new(
        token: impl Into<String>,
        deployment_ref: impl Into<String>,
        generation: impl Into<String>,
    ) -> Self {
        Self {
            token: Zeroizing::new(token.into()),
            deployment_ref: deployment_ref.into(),
            generation: generation.into(),
        }
    }

    pub fn token(&self) -> &str {
        self.token.as_str()
    }

    pub fn deployment_ref(&self) -> &str {
        &self.deployment_ref
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }
}

impl Debug for WorkerAuthCredentials {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.debug_struct("WorkerAuthCredentials")
            .field("token", &"[REDACTED]")
            .field("deployment_ref", &self.deployment_ref)
            .field("generation", &self.generation)
            .finish()
    }
}

/// Short-lived `:reader`-only S3 credentials held exclusively in worker RAM for
/// the duration of a single archive-backed `VisualIndexJob`.
#[derive(Clone, PartialEq, Eq)]
pub struct EphemeralS3Credentials {
    reference: Option<String>,
    generation: Option<u64>,
    role: Option<String>,
    secret_id: Option<String>,
    access_key_id: Option<Zeroizing<String>>,
    secret_access_key: Option<Zeroizing<String>>,
    session_token: Option<Zeroizing<String>>,
}

#[derive(Deserialize)]
struct RawEphemeralS3Credentials {
    #[serde(default)]
    reference: Option<String>,
    #[serde(default)]
    generation: Option<u64>,
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    secret_id: Option<String>,
    #[serde(default)]
    access_key_id: Option<String>,
    #[serde(default)]
    secret_access_key: Option<String>,
    #[serde(default)]
    session_token: Option<String>,
}

impl EphemeralS3Credentials {
    pub fn new(
        access_key_id: impl Into<String>,
        secret_access_key: impl Into<String>,
        session_token: Option<String>,
    ) -> Self {
        Self {
            reference: None,
            generation: None,
            role: Some("reader".to_string()),
            secret_id: None,
            access_key_id: Some(Zeroizing::new(access_key_id.into())),
            secret_access_key: Some(Zeroizing::new(secret_access_key.into())),
            session_token: session_token.map(Zeroizing::new),
        }
    }

    pub fn with_metadata(
        mut self,
        reference: Option<String>,
        generation: Option<u64>,
        secret_id: Option<String>,
    ) -> Self {
        self.reference = reference;
        self.generation = generation;
        self.secret_id = secret_id;
        self
    }

    pub fn reference(&self) -> Option<&str> {
        self.reference.as_deref()
    }

    pub fn generation(&self) -> Option<u64> {
        self.generation
    }

    pub fn role(&self) -> Option<&str> {
        self.role.as_deref()
    }

    pub fn secret_id(&self) -> Option<&str> {
        self.secret_id.as_deref()
    }

    pub fn access_key_id(&self) -> Option<&str> {
        self.access_key_id.as_deref().map(String::as_str)
    }

    pub fn secret_access_key(&self) -> Option<&str> {
        self.secret_access_key.as_deref().map(String::as_str)
    }

    pub fn session_token(&self) -> Option<&str> {
        self.session_token.as_deref().map(String::as_str)
    }

    pub fn has_key_material(&self) -> bool {
        self.access_key_id
            .as_ref()
            .is_some_and(|v| !v.trim().is_empty())
            && self
                .secret_access_key
                .as_ref()
                .is_some_and(|v| !v.trim().is_empty())
    }
}

impl Debug for EphemeralS3Credentials {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        f.debug_struct("EphemeralS3Credentials")
            .field("reference", &self.reference)
            .field("generation", &self.generation)
            .field("role", &self.role)
            .field("secret_id", &self.secret_id)
            .field(
                "access_key_id",
                &self.access_key_id.as_ref().map(|_| "[REDACTED]"),
            )
            .field(
                "secret_access_key",
                &self.secret_access_key.as_ref().map(|_| "[REDACTED]"),
            )
            .field(
                "session_token",
                &self.session_token.as_ref().map(|_| "[REDACTED]"),
            )
            .finish()
    }
}

impl Serialize for EphemeralS3Credentials {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut st = serializer.serialize_struct("EphemeralS3Credentials", 4)?;
        st.serialize_field("reference", &self.reference)?;
        st.serialize_field("generation", &self.generation)?;
        st.serialize_field("role", &self.role)?;
        st.serialize_field("secret_id", &self.secret_id)?;
        st.end()
    }
}

impl<'de> Deserialize<'de> for EphemeralS3Credentials {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawEphemeralS3Credentials::deserialize(deserializer)?;
        Ok(Self {
            reference: raw.reference,
            generation: raw.generation,
            role: raw.role,
            secret_id: raw.secret_id,
            access_key_id: raw.access_key_id.map(Zeroizing::new),
            secret_access_key: raw.secret_access_key.map(Zeroizing::new),
            session_token: raw.session_token.map(Zeroizing::new),
        })
    }
}
