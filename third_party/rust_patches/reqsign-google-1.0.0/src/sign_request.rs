use http::header;
use jsonwebtoken::{Algorithm, EncodingKey, Header as JwtHeader};
use log::debug;
use percent_encoding::{percent_decode_str, utf8_percent_encode};
use rand::thread_rng;
use rsa::pkcs1v15::SigningKey;
use rsa::pkcs8::DecodePrivateKey;
use rsa::signature::RandomizedSigner;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::time::Duration;

use reqsign_core::{
    hash::hex_sha256, time::*, Context, Result, SignRequest, SigningCredential, SigningMethod,
    SigningRequest,
};

use crate::constants::{DEFAULT_SCOPE, GOOGLE_SCOPE, GOOG_QUERY_ENCODE_SET, GOOG_URI_ENCODE_SET};
use crate::credential::{Credential, ServiceAccount, Token};

/// Claims is used to build JWT for Google Cloud.
#[derive(Debug, Serialize)]
struct Claims {
    iss: String,
    scope: String,
    aud: String,
    exp: u64,
    iat: u64,
}

impl Claims {
    fn new(client_email: &str, scope: &str) -> Self {
        let current = now().timestamp() as u64;

        Claims {
            iss: client_email.to_string(),
            scope: scope.to_string(),
            aud: "https://oauth2.googleapis.com/token".to_string(),
            exp: current + 3600,
            iat: current,
        }
    }
}

/// OAuth2 token response.
#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    expires_in: Option<u64>,
}

/// RequestSigner for Google service requests.
#[derive(Debug)]
pub struct RequestSigner {
    service: String,
    region: String,
    scope: Option<String>,
}

impl Default for RequestSigner {
    fn default() -> Self {
        Self {
            service: String::new(),
            region: "auto".to_string(),
            scope: None,
        }
    }
}

impl RequestSigner {
    /// Create a new builder with the specified service.
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            region: "auto".to_string(),
            scope: None,
        }
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }

    /// Set the region for the builder.
    pub fn with_region(mut self, region: impl Into<String>) -> Self {
        self.region = region.into();
        self
    }

    /// Exchange a service account for an access token.
    ///
    /// This method is used internally when a token is needed but only a service account
    /// is available. It creates a JWT and exchanges it for an OAuth2 access token.
    async fn exchange_token(&self, ctx: &Context, sa: &ServiceAccount) -> Result<Token> {
        let scope = self
            .scope
            .clone()
            .or_else(|| ctx.env_var(GOOGLE_SCOPE))
            .unwrap_or_else(|| DEFAULT_SCOPE.to_string());

        debug!("exchanging service account for token with scope: {scope}");

        // Create JWT
        let jwt = jsonwebtoken::encode(
            &JwtHeader::new(Algorithm::RS256),
            &Claims::new(&sa.client_email, &scope),
            &EncodingKey::from_rsa_pem(sa.private_key.as_bytes()).map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse RSA private key").with_source(e)
            })?,
        )
        .map_err(|e| reqsign_core::Error::unexpected("failed to encode JWT").with_source(e))?;

        // Exchange JWT for access token
        let body =
            format!("grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion={jwt}");
        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri("https://oauth2.googleapis.com/token")
            .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(body.into_bytes().into())
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "exchange token failed: {body}"
            )));
        }

        let token_resp: TokenResponse = serde_json::from_slice(resp.body()).map_err(|e| {
            reqsign_core::Error::unexpected("failed to parse token response").with_source(e)
        })?;

        let expires_at = token_resp.expires_in.map(|expires_in| {
            now() + chrono::TimeDelta::try_seconds(expires_in as i64).expect("in bounds")
        });

        Ok(Token {
            access_token: token_resp.access_token,
            expires_at,
        })
    }

    fn build_token_auth(
        &self,
        parts: &mut http::request::Parts,
        token: &Token,
    ) -> Result<SigningRequest> {
        let mut req = SigningRequest::build(parts)?;

        req.headers.insert(header::AUTHORIZATION, {
            let mut value: http::HeaderValue = format!("Bearer {}", &token.access_token)
                .parse()
                .map_err(|e| {
                    reqsign_core::Error::unexpected("failed to parse header value").with_source(e)
                })?;
            value.set_sensitive(true);
            value
        });

        Ok(req)
    }

    fn build_signed_query(
        &self,
        _ctx: &Context,
        parts: &mut http::request::Parts,
        service_account: &ServiceAccount,
        expires_in: Duration,
    ) -> Result<SigningRequest> {
        let mut req = SigningRequest::build(parts)?;
        let now = now();

        // Canonicalize headers
        canonicalize_header(&mut req)?;

        // Canonicalize query
        canonicalize_query(
            &mut req,
            SigningMethod::Query(expires_in),
            service_account,
            now,
            &self.service,
            &self.region,
        )?;

        // Build canonical request string
        let creq = canonical_request_string(&mut req)?;
        let encoded_req = hex_sha256(creq.as_bytes());

        // Build scope
        let scope = format!(
            "{}/{}/{}/goog4_request",
            format_date(now),
            self.region,
            self.service
        );
        debug!("calculated scope: {scope}");

        // Build string to sign
        let string_to_sign = {
            let mut f = String::new();
            f.push_str("GOOG4-RSA-SHA256");
            f.push('\n');
            f.push_str(&format_iso8601(now));
            f.push('\n');
            f.push_str(&scope);
            f.push('\n');
            f.push_str(&encoded_req);
            f
        };
        debug!("calculated string to sign: {string_to_sign}");

        // Sign the string
        let mut rng = thread_rng();
        let private_key = rsa::RsaPrivateKey::from_pkcs8_pem(&service_account.private_key)
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse private key").with_source(e)
            })?;
        let signing_key = SigningKey::<sha2::Sha256>::new(private_key);
        let signature = signing_key.sign_with_rng(&mut rng, string_to_sign.as_bytes());

        req.query
            .push(("X-Goog-Signature".to_string(), signature.to_string()));

        Ok(req)
    }
}

#[async_trait::async_trait]
impl SignRequest for RequestSigner {
    type Credential = Credential;

    async fn sign_request(
        &self,
        ctx: &Context,
        req: &mut http::request::Parts,
        credential: Option<&Self::Credential>,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        let cred = credential
            .ok_or_else(|| reqsign_core::Error::credential_invalid("missing credential"))?;

        let signing_req = match expires_in {
            // Query signing - must use ServiceAccount
            Some(expires) => {
                let sa = cred.service_account.as_ref().ok_or_else(|| {
                    reqsign_core::Error::credential_invalid(
                        "service account required for query signing",
                    )
                })?;
                self.build_signed_query(ctx, req, sa, expires)?
            }
            // Header authentication - prefer valid token, otherwise exchange from SA
            None => {
                // Check if we have a valid token
                if let Some(token) = &cred.token {
                    if token.is_valid() {
                        self.build_token_auth(req, token)?
                    } else if let Some(sa) = &cred.service_account {
                        // Token expired but we have SA, exchange for new token
                        debug!("token expired, exchanging service account for new token");
                        let new_token = self.exchange_token(ctx, sa).await?;
                        self.build_token_auth(req, &new_token)?
                    } else {
                        return Err(reqsign_core::Error::credential_invalid(
                            "token expired and no service account available",
                        ));
                    }
                } else if let Some(sa) = &cred.service_account {
                    // No token but have SA, exchange for token
                    debug!("no token available, exchanging service account for token");
                    let token = self.exchange_token(ctx, sa).await?;
                    self.build_token_auth(req, &token)?
                } else {
                    return Err(reqsign_core::Error::credential_invalid(
                        "no valid credential available",
                    ));
                }
            }
        };

        signing_req.apply(req).map_err(|e| {
            reqsign_core::Error::unexpected("failed to apply signing request").with_source(e)
        })
    }
}

fn canonical_request_string(req: &mut SigningRequest) -> Result<String> {
    // 256 is specially chosen to avoid reallocation for most requests.
    let mut f = String::with_capacity(256);

    // Insert method
    f.push_str(req.method.as_str());
    f.push('\n');

    // Insert encoded path
    let path = percent_decode_str(&req.path)
        .decode_utf8()
        .map_err(|e| reqsign_core::Error::unexpected("failed to decode path").with_source(e))?;
    f.push_str(&Cow::from(utf8_percent_encode(&path, &GOOG_URI_ENCODE_SET)));
    f.push('\n');

    // Insert query
    f.push_str(&SigningRequest::query_to_string(
        req.query.clone(),
        "=",
        "&",
    ));
    f.push('\n');

    // Insert signed headers
    let signed_headers = req.header_name_to_vec_sorted();
    for header in signed_headers.iter() {
        let value = &req.headers[*header];
        f.push_str(header);
        f.push(':');
        f.push_str(value.to_str().expect("header value must be valid"));
        f.push('\n');
    }
    f.push('\n');
    f.push_str(&signed_headers.join(";"));
    f.push('\n');
    f.push_str("UNSIGNED-PAYLOAD");

    debug!("canonical request string: {f}");
    Ok(f)
}

fn canonicalize_header(req: &mut SigningRequest) -> Result<()> {
    for (_, value) in req.headers.iter_mut() {
        SigningRequest::header_value_normalize(value)
    }

    // Insert HOST header if not present.
    if req.headers.get(header::HOST).is_none() {
        req.headers.insert(
            header::HOST,
            req.authority.as_str().parse().map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse host header").with_source(e)
            })?,
        );
    }

    Ok(())
}

fn canonicalize_query(
    req: &mut SigningRequest,
    method: SigningMethod,
    cred: &ServiceAccount,
    now: DateTime,
    service: &str,
    region: &str,
) -> Result<()> {
    if let SigningMethod::Query(expire) = method {
        req.query
            .push(("X-Goog-Algorithm".into(), "GOOG4-RSA-SHA256".into()));
        req.query.push((
            "X-Goog-Credential".into(),
            format!(
                "{}/{}/{}/{}/goog4_request",
                &cred.client_email,
                format_date(now),
                region,
                service
            ),
        ));
        req.query.push(("X-Goog-Date".into(), format_iso8601(now)));
        req.query
            .push(("X-Goog-Expires".into(), expire.as_secs().to_string()));
        req.query.push((
            "X-Goog-SignedHeaders".into(),
            req.header_name_to_vec_sorted().join(";"),
        ));
    }

    // Return if query is empty.
    if req.query.is_empty() {
        return Ok(());
    }

    // Sort by param name
    req.query.sort();

    req.query = req
        .query
        .iter()
        .map(|(k, v)| {
            (
                utf8_percent_encode(k, &GOOG_QUERY_ENCODE_SET).to_string(),
                utf8_percent_encode(v, &GOOG_QUERY_ENCODE_SET).to_string(),
            )
        })
        .collect();

    Ok(())
}
