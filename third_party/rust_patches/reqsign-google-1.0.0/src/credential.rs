use reqsign_core::{
    time::now, time::DateTime, utils::Redact, Result, SigningCredential as KeyTrait,
};
use std::fmt::{self, Debug};

/// ServiceAccount holds the client email and private key for service account authentication.
#[derive(Clone, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct ServiceAccount {
    /// Private key of credential
    pub private_key: String,
    /// The client email of credential
    pub client_email: String,
}

impl Debug for ServiceAccount {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ServiceAccount")
            .field("client_email", &self.client_email)
            .field("private_key", &Redact::from(&self.private_key))
            .finish()
    }
}

/// ImpersonatedServiceAccount holds the source credentials for impersonation.
#[derive(Clone, serde::Deserialize, Debug)]
#[serde(rename_all = "snake_case")]
pub struct ImpersonatedServiceAccount {
    /// The URL to obtain the access token for the impersonated service account.
    pub service_account_impersonation_url: String,
    /// The underlying OAuth2 credentials.
    pub source_credentials: OAuth2Credentials,
    /// Optional delegates for the impersonation.
    #[serde(default)]
    pub delegates: Vec<String>,
}

/// OAuth2 user credentials (for authorized users and impersonation sources).
#[derive(Clone, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct OAuth2Credentials {
    /// The client ID.
    pub client_id: String,
    /// The client secret.
    pub client_secret: String,
    /// The refresh token.
    pub refresh_token: String,
}

impl Debug for OAuth2Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OAuth2Credentials")
            .field("client_id", &self.client_id)
            .field("client_secret", &Redact::from(&self.client_secret))
            .field("refresh_token", &Redact::from(&self.refresh_token))
            .finish()
    }
}

/// External account for workload identity federation.
#[derive(Clone, serde::Deserialize, Debug)]
#[serde(rename_all = "snake_case")]
pub struct ExternalAccount {
    /// The audience for the external account.
    pub audience: String,
    /// The subject token type.
    pub subject_token_type: String,
    /// The token URL to exchange tokens.
    pub token_url: String,
    /// The credential source.
    pub credential_source: external_account::Source,
    /// Optional service account impersonation URL.
    pub service_account_impersonation_url: Option<String>,
    /// Optional service account impersonation options.
    pub service_account_impersonation: Option<external_account::ImpersonationOptions>,
}

/// External account specific types.
pub mod external_account {
    use reqsign_core::Result;
    use serde::Deserialize;

    /// Where to obtain the external account credentials from.
    #[derive(Clone, Deserialize, Debug)]
    #[serde(untagged)]
    pub enum Source {
        /// URL-based credential source.
        #[serde(rename_all = "snake_case")]
        Url(UrlSource),
        /// File-based credential source.
        #[serde(rename_all = "snake_case")]
        File(FileSource),
    }

    /// Configuration for fetching credentials from a URL.
    #[derive(Clone, Deserialize, Debug)]
    #[serde(rename_all = "snake_case")]
    pub struct UrlSource {
        /// The URL to fetch credentials from.
        pub url: String,
        /// The format of the response.
        pub format: Format,
        /// Optional headers to include in the request.
        pub headers: Option<std::collections::HashMap<String, String>>,
    }

    /// Configuration for reading credentials from a file.
    #[derive(Clone, Deserialize, Debug)]
    #[serde(rename_all = "snake_case")]
    pub struct FileSource {
        /// The file path to read credentials from.
        pub file: String,
        /// The format of the file.
        pub format: Format,
    }

    /// Format for parsing credentials.
    #[derive(Clone, Deserialize, Debug)]
    #[serde(tag = "type", rename_all = "snake_case")]
    pub enum Format {
        /// JSON format.
        Json {
            /// The JSON path to extract the subject token.
            subject_token_field_name: String,
        },
        /// Plain text format.
        Text,
    }

    impl Format {
        /// Parse a slice of bytes as the expected format.
        pub fn parse(&self, slice: &[u8]) -> Result<String> {
            match &self {
                Self::Text => Ok(String::from_utf8(slice.to_vec()).map_err(|e| {
                    reqsign_core::Error::unexpected("invalid UTF-8").with_source(e)
                })?),
                Self::Json {
                    subject_token_field_name,
                } => {
                    let value: serde_json::Value = serde_json::from_slice(slice).map_err(|e| {
                        reqsign_core::Error::unexpected("failed to parse JSON").with_source(e)
                    })?;
                    match value.get(subject_token_field_name) {
                        Some(serde_json::Value::String(access_token)) => Ok(access_token.clone()),
                        _ => Err(reqsign_core::Error::unexpected(format!(
                            "JSON missing token field {subject_token_field_name}"
                        ))),
                    }
                }
            }
        }
    }

    /// Service account impersonation options.
    #[derive(Clone, Deserialize, Debug)]
    #[serde(rename_all = "snake_case")]
    pub struct ImpersonationOptions {
        /// The lifetime in seconds for the impersonated token.
        pub token_lifetime_seconds: Option<usize>,
    }
}

/// Token represents an OAuth2 access token with expiration.
#[derive(Clone, Default)]
pub struct Token {
    /// The access token.
    pub access_token: String,
    /// The expiration time of the token.
    pub expires_at: Option<DateTime>,
}

impl Debug for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Token")
            .field("access_token", &Redact::from(&self.access_token))
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl KeyTrait for Token {
    fn is_valid(&self) -> bool {
        if self.access_token.is_empty() {
            return false;
        }

        match self.expires_at {
            Some(expires_at) => {
                // Consider token invalid if it expires within 2 minutes
                let buffer = chrono::TimeDelta::try_seconds(2 * 60).expect("in bounds");
                now() < expires_at - buffer
            }
            None => true, // No expiration means always valid
        }
    }
}

/// Credential represents Google credentials that may contain both service account and token.
///
/// **IMPORTANT**: This is a specially designed structure that can hold both ServiceAccount
/// and Token simultaneously. This design is intentional and critical for Google's authentication:
///
/// - Service account only: Used for signed URL generation and JWT-based authentication
/// - Token only: Used for Bearer authentication (e.g., from metadata server, OAuth2)  
/// - Both: The RequestSigner is responsible for exchanging service account for tokens when needed,
///   and can use cached tokens when available to avoid unnecessary exchanges
///
/// The RequestSigner implementation handles the logic of when to use which credential type
/// and when to perform token exchanges. Providers should return credentials as they receive them
/// without trying to perform exchanges themselves.
#[derive(Clone, Debug, Default)]
pub struct Credential {
    /// Service account information, if available.
    pub service_account: Option<ServiceAccount>,
    /// OAuth2 access token, if available.
    pub token: Option<Token>,
}

impl Credential {
    /// Create a credential with only a service account.
    pub fn with_service_account(service_account: ServiceAccount) -> Self {
        Self {
            service_account: Some(service_account),
            token: None,
        }
    }

    /// Create a credential with only a token.
    pub fn with_token(token: Token) -> Self {
        Self {
            service_account: None,
            token: Some(token),
        }
    }

    /// Check if the credential has a service account.
    pub fn has_service_account(&self) -> bool {
        self.service_account.is_some()
    }

    /// Check if the credential has a token.
    pub fn has_token(&self) -> bool {
        self.token.is_some()
    }

    /// Check if the credential has a valid token.
    pub fn has_valid_token(&self) -> bool {
        self.token.as_ref().is_some_and(|t| t.is_valid())
    }
}

impl KeyTrait for Credential {
    fn is_valid(&self) -> bool {
        // A credential is valid if it has a service account or a valid token
        self.service_account.is_some() || self.has_valid_token()
    }
}

/// CredentialFile represents the different types of Google credential files.
#[derive(Clone, Debug, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CredentialFile {
    /// Service account with private key.
    ServiceAccount(ServiceAccount),
    /// External account for workload identity federation.
    ExternalAccount(ExternalAccount),
    /// Impersonated service account.
    ImpersonatedServiceAccount(ImpersonatedServiceAccount),
    /// OAuth2 authorized user credentials.
    AuthorizedUser(OAuth2Credentials),
}

impl CredentialFile {
    /// Parse credential file from bytes.
    pub fn from_slice(v: &[u8]) -> Result<Self> {
        serde_json::from_slice(v).map_err(|e| {
            reqsign_core::Error::unexpected("failed to parse credential file").with_source(e)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_external_account_format_parse_text() {
        let format = external_account::Format::Text;
        let data = b"test-token";
        let result = format.parse(data).unwrap();
        assert_eq!("test-token", result);
    }

    #[test]
    fn test_external_account_format_parse_json() {
        let format = external_account::Format::Json {
            subject_token_field_name: "access_token".to_string(),
        };
        let data = br#"{"access_token": "test-token", "expires_in": 3600}"#;
        let result = format.parse(data).unwrap();
        assert_eq!("test-token", result);
    }

    #[test]
    fn test_external_account_format_parse_json_missing_field() {
        let format = external_account::Format::Json {
            subject_token_field_name: "access_token".to_string(),
        };
        let data = br#"{"wrong_field": "test-token"}"#;
        let result = format.parse(data);
        assert!(result.is_err());
    }

    #[test]
    fn test_token_is_valid() {
        let mut token = Token {
            access_token: "test".to_string(),
            expires_at: None,
        };
        assert!(token.is_valid());

        // Token with future expiration
        token.expires_at = Some(now() + chrono::TimeDelta::try_hours(1).unwrap());
        assert!(token.is_valid());

        // Token that expires within 2 minutes
        token.expires_at = Some(now() + chrono::TimeDelta::try_seconds(30).unwrap());
        assert!(!token.is_valid());

        // Expired token
        token.expires_at = Some(now() - chrono::TimeDelta::try_hours(1).unwrap());
        assert!(!token.is_valid());

        // Empty access token
        token.access_token = String::new();
        assert!(!token.is_valid());
    }

    #[test]
    fn test_credential_file_deserialize() {
        // Test service account
        let sa_json = r#"{
            "type": "service_account",
            "private_key": "test_key",
            "client_email": "test@example.com"
        }"#;
        let cred = CredentialFile::from_slice(sa_json.as_bytes()).unwrap();
        match cred {
            CredentialFile::ServiceAccount(sa) => {
                assert_eq!(sa.client_email, "test@example.com");
            }
            _ => panic!("Expected ServiceAccount"),
        }

        // Test external account
        let ea_json = r#"{
            "type": "external_account",
            "audience": "test_audience",
            "subject_token_type": "test_type",
            "token_url": "https://example.com/token",
            "credential_source": {
                "file": "/path/to/file",
                "format": {
                    "type": "text"
                }
            }
        }"#;
        let cred = CredentialFile::from_slice(ea_json.as_bytes()).unwrap();
        assert!(matches!(cred, CredentialFile::ExternalAccount(_)));

        // Test authorized user
        let au_json = r#"{
            "type": "authorized_user",
            "client_id": "test_id",
            "client_secret": "test_secret",
            "refresh_token": "test_token"
        }"#;
        let cred = CredentialFile::from_slice(au_json.as_bytes()).unwrap();
        match cred {
            CredentialFile::AuthorizedUser(oauth2) => {
                assert_eq!(oauth2.client_id, "test_id");
                assert_eq!(oauth2.client_secret, "test_secret");
                assert_eq!(oauth2.refresh_token, "test_token");
            }
            _ => panic!("Expected AuthorizedUser"),
        }
    }

    #[test]
    fn test_credential_is_valid() {
        // Service account only
        let cred = Credential::with_service_account(ServiceAccount {
            client_email: "test@example.com".to_string(),
            private_key: "key".to_string(),
        });
        assert!(cred.is_valid());
        assert!(cred.has_service_account());
        assert!(!cred.has_token());

        // Valid token only
        let cred = Credential::with_token(Token {
            access_token: "test".to_string(),
            expires_at: Some(now() + chrono::TimeDelta::try_hours(1).unwrap()),
        });
        assert!(cred.is_valid());
        assert!(!cred.has_service_account());
        assert!(cred.has_token());
        assert!(cred.has_valid_token());

        // Invalid token only
        let cred = Credential::with_token(Token {
            access_token: String::new(),
            expires_at: None,
        });
        assert!(!cred.is_valid());
        assert!(!cred.has_valid_token());

        // Both service account and valid token
        let mut cred = Credential::with_service_account(ServiceAccount {
            client_email: "test@example.com".to_string(),
            private_key: "key".to_string(),
        });
        cred.token = Some(Token {
            access_token: "test".to_string(),
            expires_at: Some(now() + chrono::TimeDelta::try_hours(1).unwrap()),
        });
        assert!(cred.is_valid());
        assert!(cred.has_service_account());
        assert!(cred.has_valid_token());

        // Service account with expired token
        let mut cred = Credential::with_service_account(ServiceAccount {
            client_email: "test@example.com".to_string(),
            private_key: "key".to_string(),
        });
        cred.token = Some(Token {
            access_token: "test".to_string(),
            expires_at: Some(now() - chrono::TimeDelta::try_hours(1).unwrap()),
        });
        assert!(cred.is_valid()); // Still valid because of service account
        assert!(!cred.has_valid_token());
    }
}
