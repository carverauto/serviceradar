use reqsign_core::time::{now, DateTime};
use reqsign_core::utils::Redact;
use reqsign_core::SigningCredential;
use std::fmt::{Debug, Formatter};

/// Credential enum for different Azure Storage authentication methods.
#[derive(Clone)]
pub enum Credential {
    /// Shared Key authentication with account name and key
    SharedKey {
        /// Azure storage account name.
        account_name: String,
        /// Azure storage account key.
        account_key: String,
    },
    /// SAS (Shared Access Signature) token authentication
    SasToken {
        /// SAS token.
        token: String,
    },
    /// Bearer token for OAuth authentication
    BearerToken {
        /// Bearer token.
        token: String,
        /// Expiration time for this credential.
        expires_in: Option<DateTime>,
    },
}

impl Debug for Credential {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Credential::SharedKey {
                account_name,
                account_key,
            } => f
                .debug_struct("Credential::SharedKey")
                .field("account_name", &Redact::from(account_name))
                .field("account_key", &Redact::from(account_key))
                .finish(),
            Credential::SasToken { token } => f
                .debug_struct("Credential::SasToken")
                .field("token", &Redact::from(token))
                .finish(),
            Credential::BearerToken { token, expires_in } => f
                .debug_struct("Credential::BearerToken")
                .field("token", &Redact::from(token))
                .field("expires_in", expires_in)
                .finish(),
        }
    }
}

impl SigningCredential for Credential {
    fn is_valid(&self) -> bool {
        match self {
            Credential::SharedKey {
                account_name,
                account_key,
            } => !account_name.is_empty() && !account_key.is_empty(),
            Credential::SasToken { token } => !token.is_empty(),
            Credential::BearerToken { token, expires_in } => {
                if token.is_empty() {
                    return false;
                }
                // Check expiration for bearer tokens (take 20s as buffer to avoid edge cases)
                if let Some(expires) = expires_in {
                    *expires > now() + chrono::TimeDelta::try_seconds(20).expect("in bounds")
                } else {
                    true
                }
            }
        }
    }
}

impl Credential {
    /// Create a new credential with shared key authentication.
    pub fn with_shared_key(account_name: &str, account_key: &str) -> Self {
        Self::SharedKey {
            account_name: account_name.to_string(),
            account_key: account_key.to_string(),
        }
    }

    /// Create a new credential with SAS token authentication.
    pub fn with_sas_token(sas_token: &str) -> Self {
        Self::SasToken {
            token: sas_token.to_string(),
        }
    }

    /// Create a new credential with bearer token authentication.
    pub fn with_bearer_token(bearer_token: &str, expires_in: Option<DateTime>) -> Self {
        Self::BearerToken {
            token: bearer_token.to_string(),
            expires_in,
        }
    }
}
