// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use http::{Uri, header};
use log::debug;
use percent_encoding::{percent_decode_str, utf8_percent_encode};
use rsa::pkcs1v15::SigningKey;
use rsa::pkcs8::DecodePrivateKey;
use rsa::rand_core::OsRng;
use rsa::signature::RandomizedSigner;
use serde::{Deserialize, Serialize};
use std::time::Duration;

use reqsign_core::{
    Context, Result, SignRequest, SigningCredential, SigningRequest, hash::hex_sha256, time::*,
};

use crate::constants::{DEFAULT_SCOPE, GOOG_QUERY_ENCODE_SET, GOOG_URI_ENCODE_SET, GOOGLE_SCOPE};
use crate::credential::{Credential, ServiceAccount, Token};

const TOKEN_OPERATION_HEADROOM: Duration = Duration::from_secs(10);

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
        let current = Timestamp::now().as_second() as u64;

        Claims {
            iss: client_email.to_string(),
            scope: scope.to_string(),
            aud: "https://oauth2.googleapis.com/token".to_string(),
            exp: current + 3600,
            iat: current,
        }
    }
}

/// Header is used to build RS256 JWT for Google Cloud OAuth2.
#[derive(Debug, Serialize)]
struct JwtHeader {
    alg: &'static str,
    typ: &'static str,
}

impl JwtHeader {
    fn rs256() -> Self {
        Self {
            alg: "RS256",
            typ: "JWT",
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
    signer_email: Option<String>,
}

impl Default for RequestSigner {
    fn default() -> Self {
        Self {
            service: String::new(),
            region: "auto".to_string(),
            scope: None,
            signer_email: None,
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
            signer_email: None,
        }
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }

    /// Set the signer service account email used for query signing via IAMCredentials `signBlob`.
    ///
    /// This is required when generating signed URLs without an embedded service account private key
    /// (e.g. ADC / WIF / impersonation tokens).
    pub fn with_signer_email(mut self, signer_email: impl Into<String>) -> Self {
        self.signer_email = Some(signer_email.into());
        self
    }

    /// Set the region for the builder.
    pub fn with_region(mut self, region: impl Into<String>) -> Self {
        self.region = region.into();
        self
    }

    fn token_required_until(&self) -> Timestamp {
        Timestamp::now() + TOKEN_OPERATION_HEADROOM
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

        let jwt = reqsign_core::jwt::encode_rs256_pem(
            &JwtHeader::rs256(),
            &Claims::new(&sa.client_email, &scope),
            sa.private_key.as_bytes(),
        )?;

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

        let expires_at = token_resp
            .expires_in
            .map(|expires_in| Timestamp::now() + Duration::from_secs(expires_in));

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
            let mut value: http::HeaderValue = format!("Bearer {}", token.access_token)
                .parse()
                .map_err(|e| {
                    reqsign_core::Error::unexpected("failed to parse header value").with_source(e)
                })?;
            value.set_sensitive(true);
            value
        });

        Ok(req)
    }

    fn build_string_to_sign(
        &self,
        req: &mut SigningRequest,
        client_email: &str,
        now: Timestamp,
        expires_in: Duration,
    ) -> Result<(String, Vec<(String, String)>)> {
        canonicalize_header(req)?;

        let authentication_query = authentication_query(
            req,
            client_email,
            now,
            expires_in,
            &self.service,
            &self.region,
        );
        let canonical_query = canonicalize_query(req, &authentication_query);

        let creq = canonical_request_string(req, &canonical_query)?;
        let encoded_req = hex_sha256(creq.as_bytes());

        let scope = format!(
            "{}/{}/{}/goog4_request",
            now.format_date(),
            self.region,
            self.service
        );
        debug!("calculated scope: {scope}");

        let string_to_sign = {
            let mut f = String::new();
            f.push_str("GOOG4-RSA-SHA256");
            f.push('\n');
            f.push_str(&now.format_iso8601());
            f.push('\n');
            f.push_str(&scope);
            f.push('\n');
            f.push_str(&encoded_req);
            f
        };
        debug!("calculated string to sign: {string_to_sign}");

        Ok((string_to_sign, authentication_query))
    }

    fn sign_with_service_account(private_key_pem: &str, string_to_sign: &str) -> Result<String> {
        let mut rng = OsRng;
        let private_key = rsa::RsaPrivateKey::from_pkcs8_pem(private_key_pem).map_err(|e| {
            reqsign_core::Error::unexpected("failed to parse private key").with_source(e)
        })?;
        let signing_key = SigningKey::<rsa::sha2::Sha256>::new(private_key);
        let signature = signing_key.sign_with_rng(&mut rng, string_to_sign.as_bytes());

        Ok(signature.to_string())
    }

    fn build_signed_query_with_service_account(
        &self,
        parts: &mut http::request::Parts,
        service_account: &ServiceAccount,
        expires_in: Duration,
    ) -> Result<(SigningRequest, Uri)> {
        let original_uri = parts.uri.clone();
        let mut req = SigningRequest::build(parts)?;
        let now = Timestamp::now();

        let (string_to_sign, authentication_query) =
            self.build_string_to_sign(&mut req, &service_account.client_email, now, expires_in)?;
        let signature =
            Self::sign_with_service_account(&service_account.private_key, &string_to_sign)?;

        let unsigned_uri = append_query_pairs(&original_uri, &authentication_query)?;
        let final_uri =
            append_query_fragment(&unsigned_uri, &format!("X-Goog-Signature={signature}"))?;

        Ok((req, final_uri))
    }

    async fn sign_via_iamcredentials(
        &self,
        ctx: &Context,
        token: &Token,
        signer_email: &str,
        payload: &[u8],
    ) -> Result<String> {
        #[derive(Serialize)]
        struct SignBlobRequest<'a> {
            payload: &'a str,
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct SignBlobResponse {
            signed_blob: String,
        }

        let payload_b64 = reqsign_core::hash::base64_encode(payload);
        let body = serde_json::to_vec(&SignBlobRequest {
            payload: &payload_b64,
        })
        .map_err(|e| {
            reqsign_core::Error::unexpected("failed to encode signBlob request").with_source(e)
        })?;

        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(format!(
                "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{signer_email}:signBlob"
            ))
            .header(header::CONTENT_TYPE, "application/json")
            .header(header::AUTHORIZATION, {
                let mut value: http::HeaderValue = format!("Bearer {}", token.access_token)
                    .parse()
                    .map_err(|e| {
                        reqsign_core::Error::unexpected("failed to parse header value")
                            .with_source(e)
                    })?;
                value.set_sensitive(true);
                value
            })
            .body(body.into())
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "iamcredentials signBlob failed: {body}"
            )));
        }

        let sign_resp: SignBlobResponse = serde_json::from_slice(resp.body()).map_err(|e| {
            reqsign_core::Error::unexpected("failed to parse signBlob response").with_source(e)
        })?;

        let signed = reqsign_core::hash::base64_decode(&sign_resp.signed_blob)?;

        Ok(hex_encode_upper(&signed))
    }

    async fn build_signed_query_via_iamcredentials(
        &self,
        ctx: &Context,
        parts: &mut http::request::Parts,
        token: &Token,
        signer_email: &str,
        expires_in: Duration,
    ) -> Result<(SigningRequest, Uri)> {
        let original_uri = parts.uri.clone();
        let mut req = SigningRequest::build(parts)?;
        let now = Timestamp::now();

        let (string_to_sign, authentication_query) =
            self.build_string_to_sign(&mut req, signer_email, now, expires_in)?;
        let signature = self
            .sign_via_iamcredentials(ctx, token, signer_email, string_to_sign.as_bytes())
            .await?;

        let unsigned_uri = append_query_pairs(&original_uri, &authentication_query)?;
        let final_uri =
            append_query_fragment(&unsigned_uri, &format!("X-Goog-Signature={signature}"))?;

        Ok((req, final_uri))
    }
}
impl SignRequest for RequestSigner {
    type Credential = Credential;

    fn required_valid_until(
        &self,
        credential: &Self::Credential,
        _expires_in: Option<Duration>,
    ) -> Timestamp {
        if credential
            .service_account
            .as_ref()
            .is_some_and(ServiceAccount::is_valid)
        {
            Timestamp::now()
        } else {
            self.token_required_until()
        }
    }

    async fn sign_request(
        &self,
        ctx: &Context,
        req: &mut http::request::Parts,
        credential: Option<&Self::Credential>,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        let Some(cred) = credential else {
            return Ok(());
        };

        let required_until = self.required_valid_until(cred, expires_in);
        if !cred.is_valid_at(required_until) {
            return Err(reqsign_core::Error::credential_invalid(
                "credential expires before the requested signing operation deadline",
            ));
        }

        let (signing_req, final_uri) = match expires_in {
            // Query signing - prefer ServiceAccount, otherwise use IAMCredentials signBlob if possible.
            Some(expires) => {
                if let Some(sa) = cred
                    .service_account
                    .as_ref()
                    .filter(|service_account| service_account.is_valid())
                {
                    let (signing_req, uri) =
                        self.build_signed_query_with_service_account(req, sa, expires)?;
                    (signing_req, Some(uri))
                } else if let (Some(token), Some(signer_email)) =
                    (cred.token.as_ref(), self.signer_email.as_deref())
                {
                    if !token.is_valid_at(required_until) {
                        return Err(reqsign_core::Error::credential_invalid(
                            "token required for iamcredentials signBlob query signing",
                        ));
                    }

                    let (signing_req, uri) = self
                        .build_signed_query_via_iamcredentials(
                            ctx,
                            req,
                            token,
                            signer_email,
                            expires,
                        )
                        .await?;
                    (signing_req, Some(uri))
                } else {
                    return Err(reqsign_core::Error::credential_invalid(
                        "service account or token + signer_email required for query signing",
                    ));
                }
            }
            // Header authentication - prefer valid token, otherwise exchange from SA
            None => {
                let token_required_until = self.token_required_until();
                if let Some(token) = &cred.token {
                    if token.is_valid_at(token_required_until) {
                        (self.build_token_auth(req, token)?, None)
                    } else if let Some(sa) = cred
                        .service_account
                        .as_ref()
                        .filter(|service_account| service_account.is_valid())
                    {
                        // Token expired, but we have SA, exchange for new token
                        debug!("token expired, exchanging service account for new token");
                        let new_token = self.exchange_token(ctx, sa).await?;
                        if !new_token.is_valid_at(self.token_required_until()) {
                            return Err(reqsign_core::Error::credential_invalid(
                                "exchanged token is not valid long enough for header authentication",
                            ));
                        }
                        (self.build_token_auth(req, &new_token)?, None)
                    } else {
                        return Err(reqsign_core::Error::credential_invalid(
                            "token expired and no service account available",
                        ));
                    }
                } else if let Some(sa) = cred
                    .service_account
                    .as_ref()
                    .filter(|service_account| service_account.is_valid())
                {
                    // No token but have SA, exchange for token
                    debug!("no token available, exchanging service account for token");
                    let token = self.exchange_token(ctx, sa).await?;
                    if !token.is_valid_at(self.token_required_until()) {
                        return Err(reqsign_core::Error::credential_invalid(
                            "exchanged token is not valid long enough for header authentication",
                        ));
                    }
                    (self.build_token_auth(req, &token)?, None)
                } else {
                    return Err(reqsign_core::Error::credential_invalid(
                        "no valid credential available",
                    ));
                }
            }
        };

        signing_req.apply(req).map_err(|e| {
            reqsign_core::Error::unexpected("failed to apply signing request").with_source(e)
        })?;
        if let Some(uri) = final_uri {
            req.uri = uri;
        }
        Ok(())
    }
}

fn hex_encode_upper(bytes: &[u8]) -> String {
    use std::fmt::Write;

    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        write!(&mut out, "{:02X}", b).expect("writing to string must succeed");
    }
    out
}

fn canonical_request_string(
    req: &SigningRequest,
    canonical_query: &[(String, String)],
) -> Result<String> {
    // 256 is specially chosen to avoid reallocation for most requests.
    let mut f = String::with_capacity(256);

    // Insert method
    f.push_str(req.method.as_str());
    f.push('\n');

    // Insert encoded path
    f.push_str(&canonical_uri(&req.path)?);
    f.push('\n');

    // Insert query
    f.push_str(
        &canonical_query
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>()
            .join("&"),
    );
    f.push('\n');

    // Insert signed headers
    let signed_headers = req.header_name_to_vec_sorted();
    for header in signed_headers.iter() {
        let mut value = req.headers[*header].clone();
        SigningRequest::header_value_normalize(&mut value);
        f.push_str(header);
        f.push(':');
        f.push_str(value.to_str().map_err(|e| {
            reqsign_core::Error::request_invalid("invalid signed header value").with_source(e)
        })?);
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

fn authentication_query(
    req: &SigningRequest,
    client_email: &str,
    now: Timestamp,
    expires_in: Duration,
    service: &str,
    region: &str,
) -> Vec<(String, String)> {
    vec![
        ("X-Goog-Algorithm".into(), "GOOG4-RSA-SHA256".into()),
        (
            "X-Goog-Credential".into(),
            format!(
                "{}/{}/{}/{}/goog4_request",
                client_email,
                now.format_date(),
                region,
                service
            ),
        ),
        ("X-Goog-Date".into(), now.format_iso8601()),
        ("X-Goog-Expires".into(), expires_in.as_secs().to_string()),
        (
            "X-Goog-SignedHeaders".into(),
            req.header_name_to_vec_sorted().join(";"),
        ),
    ]
}

fn canonicalize_query(
    req: &SigningRequest,
    authentication_query: &[(String, String)],
) -> Vec<(String, String)> {
    let mut query = req
        .query
        .iter()
        .chain(authentication_query)
        .map(|(k, v)| {
            (
                utf8_percent_encode(k, &GOOG_QUERY_ENCODE_SET).to_string(),
                utf8_percent_encode(v, &GOOG_QUERY_ENCODE_SET).to_string(),
            )
        })
        .collect::<Vec<_>>();
    query.sort();
    query
}

fn canonical_uri(path: &str) -> Result<String> {
    path.split('/')
        .map(|segment| {
            let decoded = percent_decode_str(segment).decode_utf8().map_err(|e| {
                reqsign_core::Error::request_invalid("failed to decode URI path segment")
                    .with_source(e)
            })?;
            Ok(utf8_percent_encode(&decoded, &GOOG_URI_ENCODE_SET).to_string())
        })
        .collect::<Result<Vec<_>>>()
        .map(|segments| segments.join("/"))
}

fn append_query_pairs(uri: &Uri, pairs: &[(String, String)]) -> Result<Uri> {
    let mut pairs = pairs
        .iter()
        .map(|(key, value)| {
            (
                utf8_percent_encode(key, &GOOG_QUERY_ENCODE_SET).to_string(),
                utf8_percent_encode(value, &GOOG_QUERY_ENCODE_SET).to_string(),
            )
        })
        .collect::<Vec<_>>();
    pairs.sort();
    let fragment = pairs
        .into_iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("&");
    append_query_fragment(uri, &fragment)
}

fn append_query_fragment(uri: &Uri, fragment: &str) -> Result<Uri> {
    if fragment.is_empty() {
        return Ok(uri.clone());
    }

    let mut value = uri.to_string();
    if uri.query().is_none() {
        value.push('?');
    } else if !value.ends_with('?') && !value.ends_with('&') {
        value.push('&');
    }
    value.push_str(fragment);

    value.parse().map_err(|e| {
        reqsign_core::Error::request_invalid("failed to append signing query").with_source(e)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use http::header;
    use reqsign_core::{ErrorKind, HttpSend, ProvideCredential, Signer};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    const RAW_QUERY: &str = "slash=%2F&hash=%23&amp=%26&equals=%3D&space=%20&encoded-plus=%2B&literal-plus=+&double=%252F&dup=first&dup=second&=empty-key&empty=&flag&flag=&";

    #[derive(Debug, Default)]
    struct Recorded {
        payload_b64: Option<String>,
    }

    #[derive(Clone, Debug, Default)]
    struct MockHttpSend {
        recorded: Arc<Mutex<Recorded>>,
    }
    impl HttpSend for MockHttpSend {
        async fn http_send(&self, req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
            assert_eq!(req.method(), http::Method::POST);
            assert_eq!(
                req.uri().to_string(),
                "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/test-signer@example.com:signBlob"
            );
            assert_eq!(
                req.headers()
                    .get(header::CONTENT_TYPE)
                    .expect("content-type must exist")
                    .to_str()
                    .expect("content-type must be valid string"),
                "application/json"
            );
            assert_eq!(
                req.headers()
                    .get(header::AUTHORIZATION)
                    .expect("authorization must exist")
                    .to_str()
                    .expect("authorization must be valid string"),
                "Bearer test-access-token"
            );

            let value: serde_json::Value =
                serde_json::from_slice(req.body()).expect("body must be valid json");
            let payload_b64 = value
                .get("payload")
                .and_then(|v| v.as_str())
                .expect("payload must exist")
                .to_string();

            self.recorded.lock().unwrap().payload_b64 = Some(payload_b64);

            // base64([0x01, 0x02, 0x03]) -> hex signature "010203"
            let body = br#"{"signedBlob":"AQID"}"#;
            Ok(http::Response::builder()
                .status(http::StatusCode::OK)
                .body(body.as_slice().into())
                .expect("response must build"))
        }
    }

    #[derive(Debug)]
    struct RepeatingProvider {
        credential: Credential,
        calls: Arc<AtomicUsize>,
    }

    impl ProvideCredential for RepeatingProvider {
        type Credential = Credential;

        async fn provide_credential(&self, _ctx: &Context) -> Result<Option<Self::Credential>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(Some(self.credential.clone()))
        }
    }

    fn query_get<'a>(query: &'a str, key: &str) -> Option<&'a str> {
        query.split('&').find_map(|kv| {
            let (k, v) = kv.split_once('=')?;
            if k == key { Some(v) } else { None }
        })
    }

    fn parse_goog_date_to_timestamp(v: &str) -> Timestamp {
        let year = &v[0..4];
        let month = &v[4..6];
        let day = &v[6..8];
        let hour = &v[9..11];
        let minute = &v[11..13];
        let second = &v[13..15];
        let rfc3339 = format!("{year}-{month}-{day}T{hour}:{minute}:{second}Z");
        rfc3339.parse().expect("date must parse")
    }

    #[tokio::test]
    async fn test_signed_url_via_iamcredentials_sign_blob() -> Result<()> {
        let mock_http = MockHttpSend::default();
        let ctx = Context::new().with_http_send(mock_http.clone());

        let signer = RequestSigner::new("storage").with_signer_email("test-signer@example.com");

        let cred = Credential::with_token(Token {
            access_token: "test-access-token".to_string(),
            expires_at: Some(Timestamp::now() + Duration::from_secs(60)),
        });
        assert!(!cred.is_valid());

        let expires_in = Duration::from_secs(3600);
        let original_uri =
            format!("https://storage.googleapis.com/test-bucket/test%2Fobject?{RAW_QUERY}");

        let mut builder = http::Request::builder();
        builder = builder.method(http::Method::GET);
        builder = builder.uri(&original_uri);
        let req = builder.body(Bytes::new()).expect("request must build");
        let (mut parts, _body) = req.into_parts();

        signer
            .sign_request(&ctx, &mut parts, Some(&cred), Some(expires_in))
            .await?;

        let query = parts.uri.query().expect("signed url must have query");
        assert!(
            parts
                .uri
                .to_string()
                .starts_with(&format!("{original_uri}X-Goog-Algorithm="))
        );
        assert_eq!(
            query_get(query, "X-Goog-Signature").expect("signature must exist"),
            "010203"
        );

        let goog_date = query_get(query, "X-Goog-Date").expect("date must exist");
        let now = parse_goog_date_to_timestamp(goog_date);

        let mut builder = http::Request::builder();
        builder = builder.method(http::Method::GET);
        builder = builder.uri(&original_uri);
        let req = builder.body(Bytes::new()).expect("request must build");
        let (mut parts_for_rebuild, _body) = req.into_parts();

        let mut signing_req = SigningRequest::build(&mut parts_for_rebuild)?;
        let (string_to_sign, authentication_query) = signer.build_string_to_sign(
            &mut signing_req,
            "test-signer@example.com",
            now,
            expires_in,
        )?;
        let canonical_query = canonicalize_query(&signing_req, &authentication_query);
        assert_eq!(
            canonical_uri(&signing_req.path)?,
            "/test-bucket/test%2Fobject"
        );
        assert!(canonical_query.contains(&("literal-plus".to_string(), "%2B".to_string())));
        assert!(canonical_query.contains(&("double".to_string(), "%252F".to_string())));
        let expected_payload_b64 = reqsign_core::hash::base64_encode(string_to_sign.as_bytes());

        let recorded_payload_b64 = mock_http
            .recorded
            .lock()
            .unwrap()
            .payload_b64
            .clone()
            .expect("payload must be recorded");

        assert_eq!(recorded_payload_b64, expected_payload_b64);

        Ok(())
    }

    #[tokio::test]
    async fn signer_refreshes_near_expiry_token_without_binding_it_to_signed_url_lifetime()
    -> Result<()> {
        let mock_http = MockHttpSend::default();
        let ctx = Context::new().with_http_send(mock_http);
        let credential = Credential::with_token(Token {
            access_token: "test-access-token".to_string(),
            expires_at: Some(Timestamp::now() + Duration::from_secs(60)),
        });
        assert!(!credential.is_valid());

        let calls = Arc::new(AtomicUsize::new(0));
        let provider = RepeatingProvider {
            credential,
            calls: calls.clone(),
        };
        let signer = Signer::new(
            ctx,
            provider,
            RequestSigner::new("storage").with_signer_email("test-signer@example.com"),
        );

        for _ in 0..2 {
            let mut parts = http::Request::get("https://storage.googleapis.com/test-bucket/object")
                .body(())?
                .into_parts()
                .0;

            signer
                .sign(&mut parts, Some(Duration::from_secs(3600)))
                .await?;
            assert!(
                parts
                    .uri
                    .query()
                    .expect("signed URL query must exist")
                    .contains("X-Goog-Signature=010203")
            );
        }

        assert_eq!(calls.load(Ordering::SeqCst), 2);
        Ok(())
    }

    #[tokio::test]
    async fn bearer_authentication_preserves_uri_and_header_values() -> Result<()> {
        let signer = RequestSigner::new("storage");
        let credential = Credential::with_token(Token {
            access_token: "test-access-token".to_string(),
            expires_at: None,
        });
        let original_uri = format!("https://storage.googleapis.com/bucket/object?{RAW_QUERY}");
        let mut parts = http::Request::get(&original_uri)
            .header("x-custom", " value ")
            .body(())?
            .into_parts()
            .0;

        signer
            .sign_request(&Context::new(), &mut parts, Some(&credential), None)
            .await?;

        assert_eq!(parts.uri.to_string(), original_uri);
        assert_eq!(parts.headers["x-custom"], " value ");
        assert_eq!(
            parts.headers[header::AUTHORIZATION],
            "Bearer test-access-token"
        );
        Ok(())
    }

    #[tokio::test]
    async fn bearer_authentication_uses_token_inside_refresh_window() -> Result<()> {
        let signer = RequestSigner::new("storage");
        let credential = Credential::with_token(Token {
            access_token: "test-access-token".to_string(),
            expires_at: Some(Timestamp::now() + Duration::from_secs(30)),
        });
        assert!(!credential.is_valid());

        let mut parts = http::Request::get("https://storage.googleapis.com/bucket/object")
            .body(())?
            .into_parts()
            .0;

        signer
            .sign_request(&Context::new(), &mut parts, Some(&credential), None)
            .await?;

        assert_eq!(
            parts.headers[header::AUTHORIZATION],
            "Bearer test-access-token"
        );
        Ok(())
    }

    #[tokio::test]
    async fn signer_reuses_refreshed_token_for_operation_but_refreshes_next_time() -> Result<()> {
        let credential = Credential::with_token(Token {
            access_token: "test-access-token".to_string(),
            expires_at: Some(Timestamp::now() + Duration::from_secs(30)),
        });
        assert!(!credential.is_valid());

        let calls = Arc::new(AtomicUsize::new(0));
        let provider = RepeatingProvider {
            credential,
            calls: calls.clone(),
        };
        let signer = Signer::new(Context::new(), provider, RequestSigner::new("storage"));

        for _ in 0..2 {
            let mut parts = http::Request::get("https://storage.googleapis.com/bucket/object")
                .body(())?
                .into_parts()
                .0;

            signer.sign(&mut parts, None).await?;
            assert_eq!(
                parts.headers[header::AUTHORIZATION],
                "Bearer test-access-token"
            );
        }

        assert_eq!(calls.load(Ordering::SeqCst), 2);
        Ok(())
    }

    #[tokio::test]
    async fn bearer_authentication_rejects_token_shorter_than_operation_headroom() -> Result<()> {
        let signer = RequestSigner::new("storage");
        let credential = Credential::with_token(Token {
            access_token: "test-access-token".to_string(),
            expires_at: Some(Timestamp::now() + Duration::from_secs(5)),
        });
        let mut parts = http::Request::get("https://storage.googleapis.com/bucket/object")
            .body(())?
            .into_parts()
            .0;
        let original = parts.clone();

        let err = signer
            .sign_request(&Context::new(), &mut parts, Some(&credential), None)
            .await
            .expect_err("token must cover the operation headroom");

        assert_eq!(err.kind(), ErrorKind::CredentialInvalid);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.headers, original.headers);
        Ok(())
    }
}
