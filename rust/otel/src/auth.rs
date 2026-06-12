//! Token-based ingestion authentication for the OTLP listeners.
//!
//! When the OTLP listener is exposed beyond the cluster, operators can
//! require an ingestion token on every export (SigNoz-style ingestion-key
//! flow). Tokens are configured in `[auth]` as a list of `{ token | token_file,
//! identity }` entries; the matched entry's identity is threaded through the
//! collector ([`crate::output::IngestContext`]) and stamped on every published
//! NATS message as the `Sr-Ingest-Identity` header for downstream attribution.
//!
//! Enforcement is OFF by default (trusted networks). Both listeners share the
//! same credential surface:
//! - `x-serviceradar-ingestion-key: <token>` (header / gRPC metadata key)
//! - `authorization: Bearer <token>` (alias)
//!
//! CORS preflight (`OPTIONS`) requests stay unauthenticated so browser SDKs
//! can negotiate before sending credentialed exports.

use std::sync::Arc;

use anyhow::{Context, Result, bail};

use crate::config::AuthConfig;

/// Primary credential header / gRPC metadata key.
pub const INGESTION_KEY_HEADER: &str = "x-serviceradar-ingestion-key";

/// Alias credential header (`authorization: Bearer <token>`).
pub const AUTHORIZATION_HEADER: &str = "authorization";

/// Authentication failure, mapped to gRPC `UNAUTHENTICATED` / HTTP 401 by the
/// listeners.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthError {
    MissingToken,
    InvalidToken,
}

impl AuthError {
    pub fn message(&self) -> &'static str {
        match self {
            AuthError::MissingToken => {
                "ingestion authentication is enabled but no token was presented; supply \
                 'x-serviceradar-ingestion-key: <token>' or 'authorization: Bearer <token>'"
            }
            AuthError::InvalidToken => "invalid ingestion token",
        }
    }
}

#[derive(Clone)]
struct TokenEntry {
    token: Vec<u8>,
    identity: String,
}

/// Resolved ingestion-auth state: tokens are loaded once at startup (inline
/// or from `token_file`, matching the crate's file-based secret idiom used
/// for NATS creds and TLS keys).
pub struct IngestAuth {
    enabled: bool,
    tokens: Vec<TokenEntry>,
}

impl IngestAuth {
    /// No enforcement and no identities — the default for trusted networks.
    pub fn disabled() -> Self {
        Self {
            enabled: false,
            tokens: Vec::new(),
        }
    }

    /// Resolves the `[auth]` config: validates entries and reads
    /// `token_file` contents (trimmed). Fails fast on unreadable files,
    /// empty tokens, or `enabled = true` without any tokens.
    pub fn from_config(config: &AuthConfig) -> Result<Self> {
        let mut tokens = Vec::with_capacity(config.tokens.len());
        for (index, entry) in config.tokens.iter().enumerate() {
            let identity = entry.identity.trim();
            if identity.is_empty() {
                bail!("[auth] tokens[{index}]: identity must not be empty");
            }
            let raw = match (&entry.token, &entry.token_file) {
                (Some(token), None) => token.trim().to_string(),
                (None, Some(path)) => std::fs::read_to_string(path)
                    .with_context(|| {
                        format!(
                            "[auth] tokens[{index}] ('{identity}'): failed to read token_file \
                             '{path}'"
                        )
                    })?
                    .trim()
                    .to_string(),
                (Some(_), Some(_)) => {
                    bail!(
                        "[auth] tokens[{index}] ('{identity}'): set either 'token' or \
                         'token_file', not both"
                    );
                }
                (None, None) => {
                    bail!(
                        "[auth] tokens[{index}] ('{identity}'): one of 'token' or 'token_file' \
                         is required"
                    );
                }
            };
            if raw.is_empty() {
                bail!("[auth] tokens[{index}] ('{identity}'): token must not be empty");
            }
            tokens.push(TokenEntry {
                token: raw.into_bytes(),
                identity: identity.to_string(),
            });
        }

        if config.enabled && tokens.is_empty() {
            bail!("[auth] enabled = true requires at least one [[auth.tokens]] entry");
        }

        Ok(Self {
            enabled: config.enabled,
            tokens,
        })
    }

    /// Whether token enforcement is on.
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// Authenticates a presented credential.
    ///
    /// - Matching token → `Ok(Some(identity))`, even when enforcement is off
    ///   (identity attribution works on trusted networks too).
    /// - No/invalid credential with enforcement off → `Ok(None)` (anonymous).
    /// - No/invalid credential with enforcement on → `Err`.
    pub fn authenticate(&self, credential: Option<&str>) -> Result<Option<String>, AuthError> {
        match credential {
            Some(presented) => {
                if let Some(identity) = self.match_token(presented.as_bytes()) {
                    Ok(Some(identity))
                } else if self.enabled {
                    Err(AuthError::InvalidToken)
                } else {
                    Ok(None)
                }
            }
            None if self.enabled => Err(AuthError::MissingToken),
            None => Ok(None),
        }
    }

    /// Scans every configured token (no early exit) using a constant-time
    /// comparison per entry.
    fn match_token(&self, presented: &[u8]) -> Option<String> {
        let mut matched: Option<&str> = None;
        for entry in &self.tokens {
            if constant_time_eq(&entry.token, presented) {
                matched = Some(&entry.identity);
            }
        }
        matched.map(str::to_string)
    }
}

/// Constant-time byte comparison: examines every byte without data-dependent
/// branching so token comparison time does not leak the matching prefix
/// length. (Token *length* is not treated as secret.) Used instead of the
/// `subtle` crate, which is only a transitive dependency of this workspace.
fn constant_time_eq(expected: &[u8], presented: &[u8]) -> bool {
    if expected.len() != presented.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in expected.iter().zip(presented.iter()) {
        diff |= a ^ b;
    }
    // black_box keeps the optimizer from rewriting the fold into an
    // early-exit comparison.
    std::hint::black_box(diff) == 0
}

/// Extracts the presented credential from the two accepted carriers:
/// `x-serviceradar-ingestion-key` (preferred) or `authorization: Bearer`.
/// Returns `None` when neither carries a non-empty token.
pub fn extract_credential<'a>(
    ingestion_key: Option<&'a str>,
    authorization: Option<&'a str>,
) -> Option<&'a str> {
    if let Some(value) = ingestion_key {
        let value = value.trim();
        if !value.is_empty() {
            return Some(value);
        }
    }

    let authorization = authorization?.trim();
    let (scheme, token) = authorization.split_once(char::is_whitespace)?;
    if scheme.eq_ignore_ascii_case("bearer") {
        let token = token.trim();
        if !token.is_empty() {
            return Some(token);
        }
    }
    None
}

/// Credential lookup over HTTP request headers.
pub fn credential_from_http_headers(headers: &hyper::header::HeaderMap) -> Option<String> {
    let get = |name: &str| headers.get(name).and_then(|v| v.to_str().ok());
    extract_credential(get(INGESTION_KEY_HEADER), get(AUTHORIZATION_HEADER)).map(str::to_string)
}

/// Credential lookup over gRPC request metadata.
pub fn credential_from_grpc_metadata(metadata: &tonic::metadata::MetadataMap) -> Option<String> {
    let get = |name: &str| metadata.get(name).and_then(|v| v.to_str().ok());
    extract_credential(get(INGESTION_KEY_HEADER), get(AUTHORIZATION_HEADER)).map(str::to_string)
}

/// Identity established by [`grpc_auth_interceptor`], read back from request
/// extensions by the gRPC export handlers (`None` = anonymous/trusted).
#[derive(Debug, Clone)]
pub struct AuthenticatedIdentity(pub Option<String>);

#[derive(Clone)]
pub struct GrpcAuthInterceptor {
    auth: Arc<IngestAuth>,
}

impl tonic::service::Interceptor for GrpcAuthInterceptor {
    fn call(
        &mut self,
        mut request: tonic::Request<()>,
    ) -> Result<tonic::Request<()>, tonic::Status> {
        let credential = credential_from_grpc_metadata(request.metadata());
        match self.auth.authenticate(credential.as_deref()) {
            Ok(identity) => {
                request
                    .extensions_mut()
                    .insert(AuthenticatedIdentity(identity));
                Ok(request)
            }
            Err(e) => Err(tonic::Status::unauthenticated(e.message())),
        }
    }
}

/// Builds the tonic interceptor enforcing ingestion auth on the OTLP/gRPC
/// services. Invalid or missing tokens (with enforcement on) are rejected
/// with `UNAUTHENTICATED`; otherwise the resolved identity is attached to
/// the request extensions for the export handlers.
pub fn grpc_auth_interceptor(auth: Arc<IngestAuth>) -> GrpcAuthInterceptor {
    GrpcAuthInterceptor { auth }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{AuthConfig, AuthTokenEntry};
    use std::io::Write;
    use tonic::service::Interceptor;

    fn auth_config(enabled: bool, entries: Vec<AuthTokenEntry>) -> AuthConfig {
        AuthConfig {
            enabled,
            tokens: entries,
        }
    }

    fn inline_entry(identity: &str, token: &str) -> AuthTokenEntry {
        AuthTokenEntry {
            identity: identity.to_string(),
            token: Some(token.to_string()),
            token_file: None,
        }
    }

    fn enforced_auth() -> IngestAuth {
        IngestAuth::from_config(&auth_config(
            true,
            vec![
                inline_entry("tenant-a", "secret-a"),
                inline_entry("tenant-b", "secret-b"),
            ],
        ))
        .unwrap()
    }

    #[test]
    fn valid_token_resolves_identity() {
        let auth = enforced_auth();
        assert_eq!(
            auth.authenticate(Some("secret-b")).unwrap(),
            Some("tenant-b".to_string())
        );
    }

    #[test]
    fn invalid_token_rejected_when_enforced() {
        let auth = enforced_auth();
        assert_eq!(
            auth.authenticate(Some("wrong")).unwrap_err(),
            AuthError::InvalidToken
        );
    }

    #[test]
    fn missing_token_rejected_when_enforced() {
        let auth = enforced_auth();
        assert_eq!(
            auth.authenticate(None).unwrap_err(),
            AuthError::MissingToken
        );
    }

    #[test]
    fn disabled_mode_allows_anonymous_and_still_attributes_matches() {
        let auth = IngestAuth::from_config(&auth_config(
            false,
            vec![inline_entry("tenant-a", "secret-a")],
        ))
        .unwrap();

        assert_eq!(auth.authenticate(None).unwrap(), None);
        assert_eq!(auth.authenticate(Some("wrong")).unwrap(), None);
        assert_eq!(
            auth.authenticate(Some("secret-a")).unwrap(),
            Some("tenant-a".to_string())
        );

        let bare = IngestAuth::disabled();
        assert_eq!(bare.authenticate(None).unwrap(), None);
        assert_eq!(bare.authenticate(Some("anything")).unwrap(), None);
    }

    #[test]
    fn token_file_entries_are_read_and_trimmed() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(b"  file-secret\n").unwrap();

        let auth = IngestAuth::from_config(&auth_config(
            true,
            vec![AuthTokenEntry {
                identity: "tenant-file".to_string(),
                token: None,
                token_file: Some(file.path().to_str().unwrap().to_string()),
            }],
        ))
        .unwrap();

        assert_eq!(
            auth.authenticate(Some("file-secret")).unwrap(),
            Some("tenant-file".to_string())
        );
    }

    #[test]
    fn config_validation_failures() {
        // enabled without tokens
        assert!(IngestAuth::from_config(&auth_config(true, vec![])).is_err());
        // empty identity
        assert!(IngestAuth::from_config(&auth_config(true, vec![inline_entry(" ", "t")])).is_err());
        // empty token
        assert!(
            IngestAuth::from_config(&auth_config(true, vec![inline_entry("id", "  ")])).is_err()
        );
        // neither token nor token_file
        assert!(
            IngestAuth::from_config(&auth_config(
                true,
                vec![AuthTokenEntry {
                    identity: "id".to_string(),
                    token: None,
                    token_file: None,
                }]
            ))
            .is_err()
        );
        // both token and token_file
        assert!(
            IngestAuth::from_config(&auth_config(
                true,
                vec![AuthTokenEntry {
                    identity: "id".to_string(),
                    token: Some("t".to_string()),
                    token_file: Some("/tmp/t".to_string()),
                }]
            ))
            .is_err()
        );
        // unreadable token_file
        assert!(
            IngestAuth::from_config(&auth_config(
                true,
                vec![AuthTokenEntry {
                    identity: "id".to_string(),
                    token: None,
                    token_file: Some("/nonexistent/ingestion-key".to_string()),
                }]
            ))
            .is_err()
        );
        // disabled mode tolerates an empty token list
        assert!(IngestAuth::from_config(&auth_config(false, vec![])).is_ok());
    }

    #[test]
    fn extract_credential_prefers_ingestion_key_and_accepts_bearer_alias() {
        assert_eq!(extract_credential(Some("abc"), None), Some("abc"));
        assert_eq!(
            extract_credential(Some("abc"), Some("Bearer other")),
            Some("abc")
        );
        assert_eq!(extract_credential(None, Some("Bearer abc")), Some("abc"));
        assert_eq!(extract_credential(None, Some("bearer abc")), Some("abc"));
        assert_eq!(extract_credential(None, Some("Basic abc")), None);
        assert_eq!(extract_credential(None, Some("Bearer   ")), None);
        assert_eq!(extract_credential(Some("  "), None), None);
        assert_eq!(extract_credential(None, None), None);
    }

    #[test]
    fn constant_time_eq_basics() {
        assert!(constant_time_eq(b"secret", b"secret"));
        assert!(!constant_time_eq(b"secret", b"secreT"));
        assert!(!constant_time_eq(b"secret", b"secre"));
        assert!(!constant_time_eq(b"", b"x"));
        assert!(constant_time_eq(b"", b""));
    }

    fn grpc_request_with(key: Option<&str>, bearer: Option<&str>) -> tonic::Request<()> {
        let mut request = tonic::Request::new(());
        if let Some(key) = key {
            request
                .metadata_mut()
                .insert(INGESTION_KEY_HEADER, key.parse().unwrap());
        }
        if let Some(token) = bearer {
            request.metadata_mut().insert(
                AUTHORIZATION_HEADER,
                format!("Bearer {token}").parse().unwrap(),
            );
        }
        request
    }

    #[test]
    fn grpc_interceptor_rejects_missing_and_invalid_tokens() {
        let mut interceptor = grpc_auth_interceptor(Arc::new(enforced_auth()));

        let missing = interceptor.call(grpc_request_with(None, None)).unwrap_err();
        assert_eq!(missing.code(), tonic::Code::Unauthenticated);
        assert!(missing.message().contains("x-serviceradar-ingestion-key"));

        let invalid = interceptor
            .call(grpc_request_with(Some("wrong"), None))
            .unwrap_err();
        assert_eq!(invalid.code(), tonic::Code::Unauthenticated);
        assert!(invalid.message().contains("invalid ingestion token"));
    }

    #[test]
    fn grpc_interceptor_attaches_identity_for_valid_tokens() {
        let mut interceptor = grpc_auth_interceptor(Arc::new(enforced_auth()));

        let via_key = interceptor
            .call(grpc_request_with(Some("secret-a"), None))
            .unwrap();
        assert_eq!(
            via_key
                .extensions()
                .get::<AuthenticatedIdentity>()
                .unwrap()
                .0,
            Some("tenant-a".to_string())
        );

        let via_bearer = interceptor
            .call(grpc_request_with(None, Some("secret-b")))
            .unwrap();
        assert_eq!(
            via_bearer
                .extensions()
                .get::<AuthenticatedIdentity>()
                .unwrap()
                .0,
            Some("tenant-b".to_string())
        );
    }

    #[test]
    fn grpc_interceptor_passes_anonymous_when_disabled() {
        let mut interceptor = grpc_auth_interceptor(Arc::new(IngestAuth::disabled()));
        let request = interceptor.call(grpc_request_with(None, None)).unwrap();
        assert_eq!(
            request
                .extensions()
                .get::<AuthenticatedIdentity>()
                .unwrap()
                .0,
            None
        );
    }
}
