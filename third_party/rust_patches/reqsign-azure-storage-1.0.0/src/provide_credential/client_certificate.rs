use std::collections::HashMap;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use reqsign_core::{Context, ProvideCredential};
use rsa::pkcs8::DecodePrivateKey;
use rsa::RsaPrivateKey;
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};

use crate::credential::Credential;

/// Generate a unique JWT ID using timestamp and a pseudo-random component
fn generate_jti(now: u64) -> String {
    // Use timestamp in nanoseconds + a hash of the timestamp for uniqueness
    let nano_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();

    // Create a pseudo-random component by hashing the nano time
    let random_part = (nano_time.wrapping_mul(6364136223846793005).wrapping_add(1)) % 1_000_000;

    format!("{}-{}-{}", now, nano_time % 1_000_000_000, random_part)
}

/// ClientCertificateCredentialProvider provides credentials using a client certificate
#[derive(Clone, Debug)]
pub struct ClientCertificateCredentialProvider {
    tenant_id: Option<String>,
    client_id: Option<String>,
    certificate_path: Option<String>,
    certificate_password: Option<String>,
}

impl Default for ClientCertificateCredentialProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl ClientCertificateCredentialProvider {
    pub fn new() -> Self {
        Self {
            tenant_id: None,
            client_id: None,
            certificate_path: None,
            certificate_password: None,
        }
    }

    /// Set the tenant ID
    pub fn with_tenant_id(mut self, tenant_id: &str) -> Self {
        self.tenant_id = Some(tenant_id.to_string());
        self
    }

    /// Set the client ID
    pub fn with_client_id(mut self, client_id: &str) -> Self {
        self.client_id = Some(client_id.to_string());
        self
    }

    /// Set the certificate path
    pub fn with_certificate_path(mut self, path: &str) -> Self {
        self.certificate_path = Some(path.to_string());
        self
    }

    /// Set the certificate password (for PFX files)
    pub fn with_certificate_password(mut self, password: &str) -> Self {
        self.certificate_password = Some(password.to_string());
        self
    }

    /// Load certificate and private key from file
    async fn load_certificate(
        &self,
        ctx: &Context,
        path: &str,
    ) -> Result<(Vec<u8>, RsaPrivateKey), reqsign_core::Error> {
        let cert_data = ctx.file_read(path).await.map_err(|e| {
            reqsign_core::Error::credential_invalid(format!("Failed to read certificate file: {e}"))
        })?;

        // For now, we'll support PEM format. PFX support can be added later
        let pem_str = String::from_utf8(cert_data.clone()).map_err(|e| {
            reqsign_core::Error::credential_invalid(format!(
                "Certificate file is not valid UTF-8: {e}"
            ))
        })?;

        // Parse all PEM blocks
        let pems = pem::parse_many(&pem_str).map_err(|e| {
            reqsign_core::Error::credential_invalid(format!("Failed to parse PEM: {e}"))
        })?;

        // Find certificate and private key
        let mut cert_der = None;
        let mut private_key_pem = None;

        for pem_block in &pems {
            match pem_block.tag() {
                "CERTIFICATE" => {
                    cert_der = Some(pem_block.contents().to_vec());
                }
                "PRIVATE KEY" | "RSA PRIVATE KEY" => {
                    private_key_pem = Some(pem::encode(pem_block));
                }
                _ => {}
            }
        }

        let cert_der = cert_der.ok_or_else(|| {
            reqsign_core::Error::credential_invalid("PEM does not contain a certificate")
        })?;

        let private_key_pem = private_key_pem.ok_or_else(|| {
            reqsign_core::Error::credential_invalid("PEM does not contain a private key")
        })?;

        // Parse private key
        let private_key = RsaPrivateKey::from_pkcs8_pem(&private_key_pem).map_err(|e| {
            reqsign_core::Error::credential_invalid(format!(
                "Failed to parse private key from PEM: {e}"
            ))
        })?;

        Ok((cert_der, private_key))
    }

    /// Calculate certificate thumbprint (x5t)
    /// Azure AD expects SHA1 thumbprint for x5t field
    fn calculate_thumbprint(&self, cert_der: &[u8]) -> String {
        let hash = Sha1::digest(cert_der);
        URL_SAFE_NO_PAD.encode(hash)
    }

    /// Create JWT client assertion
    fn create_client_assertion(
        &self,
        tenant_id: &str,
        client_id: &str,
        cert_der: &[u8],
        private_key: &RsaPrivateKey,
    ) -> Result<String, reqsign_core::Error> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| {
                reqsign_core::Error::unexpected(format!("Failed to get current time: {e}"))
            })?
            .as_secs();

        let claims = ClientAssertionClaims {
            aud: format!("https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"),
            exp: now + 600, // 10 minutes
            iss: client_id.to_string(),
            jti: generate_jti(now),
            nbf: now,
            sub: client_id.to_string(),
        };

        let mut header = Header::new(Algorithm::RS256);
        header.x5t = Some(self.calculate_thumbprint(cert_der));

        let pem_private_key =
            rsa::pkcs8::EncodePrivateKey::to_pkcs8_pem(private_key, Default::default()).map_err(
                |e| reqsign_core::Error::unexpected(format!("Failed to encode private key: {e}")),
            )?;

        let encoding_key = EncodingKey::from_rsa_pem(pem_private_key.as_bytes()).map_err(|e| {
            reqsign_core::Error::unexpected(format!("Failed to create encoding key: {e}"))
        })?;

        jsonwebtoken::encode(&header, &claims, &encoding_key)
            .map_err(|e| reqsign_core::Error::unexpected(format!("Failed to create JWT: {e}")))
    }

    /// Exchange client assertion for access token
    async fn exchange_token(
        &self,
        ctx: &Context,
        tenant_id: &str,
        client_id: &str,
        client_assertion: &str,
    ) -> Result<TokenResponse, reqsign_core::Error> {
        let url = format!("https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token");

        let mut params = HashMap::new();
        params.insert("scope", "https://storage.azure.com/.default");
        params.insert("client_id", client_id);
        params.insert(
            "client_assertion_type",
            "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        );
        params.insert("client_assertion", client_assertion);
        params.insert("grant_type", "client_credentials");

        let body = form_urlencoded::Serializer::new(String::new())
            .extend_pairs(params)
            .finish();

        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(bytes::Bytes::from(body))
            .map_err(|e| {
                reqsign_core::Error::unexpected(format!("Failed to build request: {e}"))
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            let body = resp.into_body();
            return Err(reqsign_core::Error::credential_invalid(format!(
                "Failed to get token: {}",
                String::from_utf8_lossy(&body)
            )));
        }

        let body = resp.into_body();
        let token_response: TokenResponse = serde_json::from_slice(&body).map_err(|e| {
            reqsign_core::Error::unexpected(format!("Failed to parse token response: {e}"))
        })?;

        Ok(token_response)
    }
}

#[derive(Debug, Serialize)]
struct ClientAssertionClaims {
    aud: String,
    exp: u64,
    iss: String,
    jti: String,
    nbf: u64,
    sub: String,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
    #[allow(dead_code)]
    token_type: String,
}

#[async_trait]
impl ProvideCredential for ClientCertificateCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(
        &self,
        ctx: &Context,
    ) -> Result<Option<Self::Credential>, reqsign_core::Error> {
        let envs = ctx.env_vars();

        // Try to get credentials from environment variables or configured values
        let tenant_id = self
            .tenant_id
            .as_ref()
            .or_else(|| envs.get("AZURE_TENANT_ID"))
            .cloned();

        let client_id = self
            .client_id
            .as_ref()
            .or_else(|| envs.get("AZURE_CLIENT_ID"))
            .cloned();

        let certificate_path = self
            .certificate_path
            .as_ref()
            .or_else(|| envs.get("AZURE_CLIENT_CERTIFICATE_PATH"))
            .cloned();

        // Check if all required parameters are present
        let (tenant_id, client_id, certificate_path) =
            match (tenant_id, client_id, certificate_path) {
                (Some(t), Some(c), Some(p)) => (t, c, p),
                _ => return Ok(None),
            };

        // Load certificate and private key
        let (cert_der, private_key) = self.load_certificate(ctx, &certificate_path).await?;

        // Create client assertion
        let client_assertion =
            self.create_client_assertion(&tenant_id, &client_id, &cert_der, &private_key)?;

        // Exchange for access token
        let token_response = self
            .exchange_token(ctx, &tenant_id, &client_id, &client_assertion)
            .await?;

        // Calculate expiration time
        let expires_on = SystemTime::now()
            .checked_add(Duration::from_secs(token_response.expires_in))
            .and_then(|t| {
                t.duration_since(UNIX_EPOCH)
                    .ok()
                    .map(|d| chrono::DateTime::from_timestamp(d.as_secs() as i64, 0).unwrap())
            });

        Ok(Some(Credential::with_bearer_token(
            &token_response.access_token,
            expires_on,
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_thumbprint() {
        // Test certificate DER (simplified example)
        let cert_der = b"test certificate";
        let provider = ClientCertificateCredentialProvider::new();
        let thumbprint = provider.calculate_thumbprint(cert_der);

        // Should produce a valid base64url encoded hash
        assert!(!thumbprint.is_empty());
        assert!(!thumbprint.contains('+'));
        assert!(!thumbprint.contains('/'));
        assert!(!thumbprint.contains('='));
    }

    #[test]
    fn test_provider_configuration() {
        let provider = ClientCertificateCredentialProvider::new()
            .with_tenant_id("test-tenant")
            .with_client_id("test-client")
            .with_certificate_path("/path/to/cert.pem");

        assert_eq!(provider.tenant_id, Some("test-tenant".to_string()));
        assert_eq!(provider.client_id, Some("test-client".to_string()));
        assert_eq!(
            provider.certificate_path,
            Some("/path/to/cert.pem".to_string())
        );
    }
}
