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

use crate::Credential;
use crate::constants::{
    AWS_QUERY_ENCODE_SET, X_AMZ_CONTENT_SHA_256, X_AMZ_DATE, X_AMZ_S3_SESSION_TOKEN,
    X_AMZ_SECURITY_TOKEN,
};
use http::request::Parts;
use http::{HeaderValue, Uri, header};
use log::debug;
use percent_encoding::{percent_decode_str, utf8_percent_encode};
use reqsign_core::hash::{hex_hmac_sha256, hex_sha256, hmac_sha256};
use reqsign_core::time::Timestamp;
use reqsign_core::{Context, Result, SignRequest, SigningCredential, SigningRequest};
use std::fmt::Write;
use std::time::Duration;

const CREDENTIAL_OPERATION_HEADROOM: Duration = Duration::from_secs(10);

/// RequestSigner that implement AWS SigV4.
///
/// - [Signature Version 4 signing process](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html)
#[derive(Debug)]
pub struct RequestSigner {
    service: String,
    region: String,

    time: Option<Timestamp>,
}

impl RequestSigner {
    /// Create a new builder for AWS V4 signer.
    pub fn new(service: &str, region: &str) -> Self {
        Self {
            service: service.into(),
            region: region.into(),

            time: None,
        }
    }

    /// Specify the signing time.
    ///
    /// # Note
    ///
    /// We should always take current time to sign requests.
    /// Only use this function for testing.
    #[cfg(test)]
    pub fn with_time(mut self, time: Timestamp) -> Self {
        self.time = Some(time);
        self
    }

    fn get_time(&self) -> Timestamp {
        self.time.unwrap_or_else(Timestamp::now)
    }

    fn required_valid_until_at(
        &self,
        signing_time: Timestamp,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        signing_time + expires_in.unwrap_or(CREDENTIAL_OPERATION_HEADROOM)
    }
}
impl SignRequest for RequestSigner {
    type Credential = Credential;

    fn required_valid_until(
        &self,
        _credential: &Self::Credential,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        self.required_valid_until_at(self.get_time(), expires_in)
    }

    async fn sign_request(
        &self,
        _: &Context,
        req: &mut Parts,
        credential: Option<&Self::Credential>,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        let Some(cred) = credential else {
            return Ok(());
        };

        let now = self.get_time();
        let required_until = self.required_valid_until_at(now, expires_in);
        if !cred.is_valid_at(required_until) {
            return Err(reqsign_core::Error::credential_invalid(
                "credential expires before the requested signing operation deadline",
            ));
        }

        let original_uri = req.uri.clone();
        let mut signed_req = SigningRequest::build(req)?;

        // canonicalize context
        canonicalize_header(&mut signed_req, cred, expires_in, now)?;
        let authentication_query = authentication_query(
            &signed_req,
            cred,
            expires_in,
            now,
            &self.service,
            &self.region,
        );
        let canonical_query = canonicalize_query(&signed_req, &authentication_query);

        // build canonical request and string to sign.
        let creq = canonical_request_string(&signed_req, &canonical_query)?;
        let encoded_req = hex_sha256(creq.as_bytes());

        // Scope: "20220313/<region>/<service>/aws4_request"
        let scope = format!(
            "{}/{}/{}/aws4_request",
            now.format_date(),
            self.region,
            self.service
        );
        debug!("calculated scope: {scope}");

        // StringToSign:
        //
        // AWS4-HMAC-SHA256
        // 20220313T072004Z
        // 20220313/<region>/<service>/aws4_request
        // <hashed_canonical_request>
        let string_to_sign = {
            let mut f = String::new();
            writeln!(f, "AWS4-HMAC-SHA256").map_err(|e| {
                reqsign_core::Error::unexpected(format!("failed to write algorithm: {e}"))
            })?;
            writeln!(f, "{}", now.format_iso8601()).map_err(|e| {
                reqsign_core::Error::unexpected(format!("failed to write timestamp: {e}"))
            })?;
            writeln!(f, "{}", scope).map_err(|e| {
                reqsign_core::Error::unexpected(format!("failed to write scope: {e}"))
            })?;
            write!(f, "{}", encoded_req).map_err(|e| {
                reqsign_core::Error::unexpected(format!("failed to write encoded request: {e}"))
            })?;
            f
        };
        debug!("calculated string to sign: {string_to_sign}");

        let signing_key =
            generate_signing_key(&cred.secret_access_key, now, &self.region, &self.service);
        let signature = hex_hmac_sha256(&signing_key, string_to_sign.as_bytes());

        let final_uri = if expires_in.is_some() {
            let unsigned_uri = append_query_pairs(&original_uri, &authentication_query)?;
            Some(append_query_fragment(
                &unsigned_uri,
                &format!("X-Amz-Signature={signature}"),
            )?)
        } else {
            let mut authorization = HeaderValue::from_str(&format!(
                "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}",
                cred.access_key_id,
                scope,
                signed_req.header_name_to_vec_sorted().join(";"),
                signature
            ))
            .map_err(|e| {
                reqsign_core::Error::unexpected(format!(
                    "failed to create authorization header: {e}"
                ))
            })?;
            authorization.set_sensitive(true);

            signed_req
                .headers
                .insert(header::AUTHORIZATION, authorization);
            None
        };

        // Apply to the request.
        signed_req.apply(req)?;
        if let Some(uri) = final_uri {
            req.uri = uri;
        }
        Ok(())
    }
}

fn canonical_request_string(
    ctx: &SigningRequest,
    canonical_query: &[(String, String)],
) -> Result<String> {
    // 256 is specially chosen to avoid reallocation for most requests.
    let mut f = String::with_capacity(256);

    // Insert method
    writeln!(f, "{}", ctx.method)
        .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write method: {e}")))?;
    // Insert encoded path
    writeln!(f, "{}", canonical_uri(&ctx.path)?).map_err(|e| {
        reqsign_core::Error::unexpected(format!("failed to write encoded path: {e}"))
    })?;
    // Insert query
    writeln!(
        f,
        "{}",
        canonical_query
            .iter()
            .map(|(k, v)| { format!("{k}={v}") })
            .collect::<Vec<_>>()
            .join("&")
    )
    .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write query: {e}")))?;
    // Insert signed headers
    let signed_headers = ctx.header_name_to_vec_sorted();
    for header in signed_headers.iter() {
        let mut value = ctx.headers[*header].clone();
        SigningRequest::header_value_normalize(&mut value);
        writeln!(
            f,
            "{}:{}",
            header,
            value.to_str().map_err(|e| {
                reqsign_core::Error::request_invalid("invalid signed header value").with_source(e)
            })?
        )
        .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write header: {e}")))?;
    }
    writeln!(f)
        .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write newline: {e}")))?;
    writeln!(f, "{}", signed_headers.join(";")).map_err(|e| {
        reqsign_core::Error::unexpected(format!("failed to write signed headers: {e}"))
    })?;

    if ctx.headers.get(X_AMZ_CONTENT_SHA_256).is_none() {
        write!(f, "UNSIGNED-PAYLOAD").map_err(|e| {
            reqsign_core::Error::unexpected(format!("failed to write unsigned payload: {e}"))
        })?;
    } else {
        write!(
            f,
            "{}",
            ctx.headers[X_AMZ_CONTENT_SHA_256].to_str().map_err(|e| {
                reqsign_core::Error::unexpected(format!("invalid header value: {e}"))
            })?
        )
        .map_err(|e| {
            reqsign_core::Error::unexpected(format!("failed to write content sha256: {e}"))
        })?;
    }

    Ok(f)
}

fn canonicalize_header(
    ctx: &mut SigningRequest,
    cred: &Credential,
    expires_in: Option<Duration>,
    now: Timestamp,
) -> Result<()> {
    // Insert HOST header if not present.
    if ctx.headers.get(header::HOST).is_none() {
        ctx.headers.insert(
            header::HOST,
            ctx.authority.as_str().parse().map_err(|e| {
                reqsign_core::Error::unexpected(format!(
                    "failed to parse authority as header value: {e}"
                ))
            })?,
        );
    }

    if expires_in.is_none() {
        // Insert DATE header if not present.
        if ctx.headers.get(X_AMZ_DATE).is_none() {
            let date_header = HeaderValue::try_from(now.format_iso8601()).map_err(|e| {
                reqsign_core::Error::unexpected(format!("failed to create date header: {e}"))
            })?;
            ctx.headers.insert(X_AMZ_DATE, date_header);
        }

        // Insert X_AMZ_CONTENT_SHA_256 header if not present.
        if ctx.headers.get(X_AMZ_CONTENT_SHA_256).is_none() {
            ctx.headers.insert(
                X_AMZ_CONTENT_SHA_256,
                HeaderValue::from_static("UNSIGNED-PAYLOAD"),
            );
        }

        // Insert session token header if exists
        if let Some(token) = &cred.session_token {
            let mut value = HeaderValue::from_str(token).map_err(|e| {
                reqsign_core::Error::unexpected(format!(
                    "failed to create security token header: {e}"
                ))
            })?;
            // Set token value sensitive to valid leaking.
            value.set_sensitive(true);

            // Check if this is an S3 Express request by examining the URI
            let is_s3_express = ctx.authority.as_str().contains("s3express")
                || ctx.authority.as_str().contains("--x-s3");

            if is_s3_express {
                ctx.headers.insert(X_AMZ_S3_SESSION_TOKEN, value);
            } else {
                ctx.headers.insert(X_AMZ_SECURITY_TOKEN, value);
            }
        }
    }

    Ok(())
}

fn authentication_query(
    ctx: &SigningRequest,
    cred: &Credential,
    expires_in: Option<Duration>,
    now: Timestamp,
    service: &str,
    region: &str,
) -> Vec<(String, String)> {
    let mut query = Vec::new();
    if let Some(expire) = expires_in {
        query.push(("X-Amz-Algorithm".into(), "AWS4-HMAC-SHA256".into()));
        query.push((
            "X-Amz-Credential".into(),
            format!(
                "{}/{}/{}/{}/aws4_request",
                cred.access_key_id,
                now.format_date(),
                region,
                service
            ),
        ));
        query.push(("X-Amz-Date".into(), now.format_iso8601()));
        query.push(("X-Amz-Expires".into(), expire.as_secs().to_string()));
        query.push((
            "X-Amz-SignedHeaders".into(),
            ctx.header_name_to_vec_sorted().join(";"),
        ));

        if let Some(token) = &cred.session_token {
            query.push(("X-Amz-Security-Token".into(), token.into()));
        }
    }
    query
}

fn canonicalize_query(
    ctx: &SigningRequest,
    authentication_query: &[(String, String)],
) -> Vec<(String, String)> {
    let mut query = ctx
        .query
        .iter()
        .chain(authentication_query)
        .map(|(k, v)| {
            (
                utf8_percent_encode(k, &AWS_QUERY_ENCODE_SET).to_string(),
                utf8_percent_encode(v, &AWS_QUERY_ENCODE_SET).to_string(),
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
            Ok(utf8_percent_encode(&decoded, &super::constants::AWS_URI_ENCODE_SET).to_string())
        })
        .collect::<Result<Vec<_>>>()
        .map(|segments| segments.join("/"))
}

fn append_query_pairs(uri: &Uri, pairs: &[(String, String)]) -> Result<Uri> {
    let mut pairs = pairs
        .iter()
        .map(|(key, value)| {
            (
                utf8_percent_encode(key, &AWS_QUERY_ENCODE_SET).to_string(),
                utf8_percent_encode(value, &AWS_QUERY_ENCODE_SET).to_string(),
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

fn generate_signing_key(secret: &str, time: Timestamp, region: &str, service: &str) -> Vec<u8> {
    // Sign secret
    let secret = format!("AWS4{secret}");
    // Sign date
    let sign_date = hmac_sha256(secret.as_bytes(), time.format_date().as_bytes());
    // Sign region
    let sign_region = hmac_sha256(sign_date.as_slice(), region.as_bytes());
    // Sign service
    let sign_service = hmac_sha256(sign_region.as_slice(), service.as_bytes());
    // Sign request
    hmac_sha256(sign_service.as_slice(), "aws4_request".as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provide_credential::StaticCredentialProvider;
    use anyhow::Result;
    use aws_credential_types::Credentials;
    use aws_sigv4::http_request::PayloadChecksumKind;
    use aws_sigv4::http_request::PercentEncodingMode;
    use aws_sigv4::http_request::SignableBody;
    use aws_sigv4::http_request::SignableRequest;
    use aws_sigv4::http_request::SignatureLocation;
    use aws_sigv4::http_request::SigningSettings;
    use aws_sigv4::sign::v4;
    use http::Request;
    use http::header;
    use reqsign_core::{ErrorKind, ProvideCredential, Signer};
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    const RAW_QUERY: &str = "slash=%2F&hash=%23&amp=%26&equals=%3D&space=%20&encoded-plus=%2B&literal-plus=+&double=%252F&dup=first&dup=second&=empty-key&empty=&flag&flag=&";

    #[derive(Debug)]
    struct SequenceProvider {
        credentials: Mutex<VecDeque<Credential>>,
        calls: Arc<AtomicUsize>,
    }

    impl ProvideCredential for SequenceProvider {
        type Credential = Credential;

        async fn provide_credential(
            &self,
            _ctx: &Context,
        ) -> reqsign_core::Result<Option<Self::Credential>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(self.credentials.lock().unwrap().pop_front())
        }
    }

    #[test]
    fn presign_deadline_uses_signing_time_and_requested_expiry() {
        let now: Timestamp = "2026-07-22T00:00:00Z"
            .parse()
            .expect("timestamp must parse");
        let signer = RequestSigner::new("s3", "test").with_time(now);
        let credential = Credential::default();

        assert_eq!(
            signer.required_valid_until(&credential, Some(Duration::from_secs(3600))),
            now + Duration::from_secs(3600)
        );
        assert_eq!(
            signer.required_valid_until(&credential, None),
            now + CREDENTIAL_OPERATION_HEADROOM
        );
    }

    #[tokio::test]
    async fn presign_refreshes_credential_that_cannot_cover_url_lifetime() -> Result<()> {
        let now = Timestamp::now();
        let short_lived = Credential {
            access_key_id: "short-lived-ak".to_string(),
            secret_access_key: "short-lived-sk".to_string(),
            session_token: Some("short-lived-token".to_string()),
            expires_in: Some(now + Duration::from_secs(600)),
        };
        let long_lived = Credential {
            access_key_id: "long-lived-ak".to_string(),
            secret_access_key: "long-lived-sk".to_string(),
            session_token: Some("long-lived-token".to_string()),
            expires_in: Some(now + Duration::from_secs(7200)),
        };
        let calls = Arc::new(AtomicUsize::new(0));
        let provider = SequenceProvider {
            credentials: Mutex::new(VecDeque::from([short_lived, long_lived])),
            calls: calls.clone(),
        };
        let signer = Signer::new(
            Context::new(),
            provider,
            RequestSigner::new("s3", "test").with_time(now),
        );

        let mut header_parts = Request::get("https://example.com/object")
            .body(())?
            .into_parts()
            .0;
        signer.sign(&mut header_parts, None).await?;

        let mut query_parts = Request::get("https://example.com/object")
            .body(())?
            .into_parts()
            .0;
        signer
            .sign(&mut query_parts, Some(Duration::from_secs(3600)))
            .await?;

        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(
            query_parts
                .uri
                .query()
                .expect("presigned query must exist")
                .contains("X-Amz-Credential=long-lived-ak%2F")
        );
        Ok(())
    }

    #[tokio::test]
    async fn presign_rejects_refreshed_credential_that_cannot_cover_url_lifetime() -> Result<()> {
        let now = Timestamp::now();
        let short_lived = Credential {
            access_key_id: "short-lived-ak".to_string(),
            secret_access_key: "short-lived-sk".to_string(),
            session_token: Some("short-lived-token".to_string()),
            expires_in: Some(now + Duration::from_secs(600)),
        };
        let calls = Arc::new(AtomicUsize::new(0));
        let provider = SequenceProvider {
            credentials: Mutex::new(VecDeque::from([short_lived])),
            calls: calls.clone(),
        };
        let signer = Signer::new(
            Context::new(),
            provider,
            RequestSigner::new("s3", "test").with_time(now),
        );
        let mut parts = Request::get("https://example.com/object")
            .body(())?
            .into_parts()
            .0;
        let original = parts.clone();

        let err = signer
            .sign(&mut parts, Some(Duration::from_secs(3600)))
            .await
            .expect_err("credential must cover the entire presigned URL lifetime");

        assert_eq!(err.kind(), ErrorKind::CredentialInvalid);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.headers, original.headers);

        let mut header_parts = Request::get("https://example.com/object")
            .body(())?
            .into_parts()
            .0;
        signer.sign(&mut header_parts, None).await?;
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(
            header_parts
                .headers
                .get(header::AUTHORIZATION)
                .expect("authorization header must exist")
                .to_str()?
                .contains("Credential=short-lived-ak/")
        );
        Ok(())
    }

    /// (name, request_builder)
    type TestCase = (&'static str, fn() -> Request<&'static str>);

    fn test_cases() -> Vec<TestCase> {
        vec![
            ("get_request", test_get_request),
            ("get_request_with_sse", test_get_request_with_sse),
            ("get_request_with_query", test_get_request_with_query),
            ("get_request_virtual_host", test_get_request_virtual_host),
            (
                "get_request_with_query_virtual_host",
                test_get_request_with_query_virtual_host,
            ),
            ("put_request", test_put_request),
            (
                "put_request_with_body_digest",
                test_put_request_with_body_digest,
            ),
            ("put_request_virtual_host", test_put_request_virtual_host),
        ]
    }

    fn test_get_request() -> Request<&'static str> {
        let mut req = Request::new("");
        *req.method_mut() = http::Method::GET;
        *req.uri_mut() = "http://127.0.0.1:9000/hello"
            .parse()
            .expect("url must be valid");

        req
    }

    fn test_get_request_with_sse() -> Request<&'static str> {
        let mut req = Request::new("");
        *req.method_mut() = http::Method::GET;
        *req.uri_mut() = "http://127.0.0.1:9000/hello"
            .parse()
            .expect("url must be valid");
        req.headers_mut().insert(
            "x-amz-server-side-encryption",
            "a".parse().expect("must be valid"),
        );
        req.headers_mut().insert(
            "x-amz-server-side-encryption-customer-algorithm",
            "b".parse().expect("must be valid"),
        );
        req.headers_mut().insert(
            "x-amz-server-side-encryption-customer-key",
            "c".parse().expect("must be valid"),
        );
        req.headers_mut().insert(
            "x-amz-server-side-encryption-customer-key-md5",
            "d".parse().expect("must be valid"),
        );
        req.headers_mut().insert(
            "x-amz-server-side-encryption-aws-kms-key-id",
            "e".parse().expect("must be valid"),
        );

        req
    }

    fn test_get_request_with_query() -> Request<&'static str> {
        let mut req = Request::new("");
        *req.method_mut() = http::Method::GET;
        *req.uri_mut() = "http://127.0.0.1:9000/hello?list-type=2&max-keys=3&prefix=CI/&start-after=ExampleGuide.pdf"
            .parse()
            .expect("url must be valid");

        req
    }

    fn test_get_request_virtual_host() -> Request<&'static str> {
        let mut req = Request::new("");
        *req.method_mut() = http::Method::GET;
        *req.uri_mut() = "http://hello.s3.test.example.com"
            .parse()
            .expect("url must be valid");

        req
    }

    fn test_get_request_with_query_virtual_host() -> Request<&'static str> {
        let mut req = Request::new("");
        *req.method_mut() = http::Method::GET;
        *req.uri_mut() = "http://hello.s3.test.example.com?list-type=2&max-keys=3&prefix=CI/&start-after=ExampleGuide.pdf"
            .parse()
            .expect("url must be valid");

        req
    }

    fn test_put_request() -> Request<&'static str> {
        let content = "Hello,World!";
        let mut req = Request::new(content);
        *req.method_mut() = http::Method::PUT;
        *req.uri_mut() = "http://127.0.0.1:9000/hello"
            .parse()
            .expect("url must be valid");

        req.headers_mut().insert(
            header::CONTENT_LENGTH,
            HeaderValue::from_str(&content.len().to_string()).expect("must be valid"),
        );

        req
    }

    fn test_put_request_with_body_digest() -> Request<&'static str> {
        let content = "Hello,World!";
        let mut req = Request::new(content);
        *req.method_mut() = http::Method::PUT;
        *req.uri_mut() = "http://127.0.0.1:9000/hello"
            .parse()
            .expect("url must be valid");

        req.headers_mut().insert(
            header::CONTENT_LENGTH,
            HeaderValue::from_str(&content.len().to_string()).expect("must be valid"),
        );

        let body = hex_sha256(content.as_bytes());
        req.headers_mut().insert(
            "x-amz-content-sha256",
            HeaderValue::from_str(&body).expect("must be valid"),
        );

        req
    }

    fn test_put_request_virtual_host() -> Request<&'static str> {
        let content = "Hello,World!";
        let mut req = Request::new(content);
        *req.method_mut() = http::Method::PUT;
        *req.uri_mut() = "http://hello.s3.test.example.com"
            .parse()
            .expect("url must be valid");

        req.headers_mut().insert(
            header::CONTENT_LENGTH,
            HeaderValue::from_str(&content.len().to_string()).expect("must be valid"),
        );

        req
    }

    #[track_caller]
    fn compare_request(name: &str, l: &Request<&str>, r: &Request<&str>) {
        fn format_headers(req: &Request<&str>) -> Vec<String> {
            let mut hs = req
                .headers()
                .iter()
                .map(|(k, v)| format!("{}:{}", k, v.to_str().expect("must be valid")))
                .collect::<Vec<_>>();

            // Insert host if original request doesn't have it.
            if !hs.contains(&format!("host:{}", req.uri().authority().unwrap())) {
                hs.push(format!("host:{}", req.uri().authority().unwrap()))
            }

            hs.sort();
            hs
        }

        assert_eq!(
            format_headers(l),
            format_headers(r),
            "{name} header mismatch"
        );

        fn format_query(req: &Request<&str>) -> Vec<String> {
            let query = req.uri().query().unwrap_or_default();
            let mut query = form_urlencoded::parse(query.as_bytes())
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>();
            query.sort();
            query
        }

        assert_eq!(format_query(l), format_query(r), "{name} query mismatch");
    }

    #[tokio::test]
    async fn canonicalization_preserves_wire_uri() -> Result<()> {
        let credential = Credential {
            access_key_id: "access_key_id".to_string(),
            secret_access_key: "secret_access_key".to_string(),
            ..Default::default()
        };
        let now: Timestamp = "2026-07-22T00:00:00Z".parse()?;
        let signer = RequestSigner::new("s3", "test").with_time(now);
        let original_uri = format!("https://example.com/object%2Fname?{RAW_QUERY}");

        let mut canonical_parts = Request::get(&original_uri).body(())?.into_parts().0;
        let mut signing_req = SigningRequest::build(&mut canonical_parts)?;
        canonicalize_header(
            &mut signing_req,
            &credential,
            Some(Duration::from_secs(60)),
            now,
        )?;
        let auth_query = authentication_query(
            &signing_req,
            &credential,
            Some(Duration::from_secs(60)),
            now,
            "s3",
            "test",
        );
        let canonical_query = canonicalize_query(&signing_req, &auth_query);

        assert_eq!(canonical_uri(&signing_req.path)?, "/object%2Fname");
        assert!(canonical_query.contains(&("literal-plus".to_string(), "%2B".to_string())));
        assert!(canonical_query.contains(&("double".to_string(), "%252F".to_string())));
        assert!(canonical_query.contains(&(String::new(), "empty-key".to_string())));
        assert!(canonical_query.contains(&("flag".to_string(), String::new())));

        let mut header_parts = Request::get(&original_uri)
            .header("x-custom", " value ")
            .body(())?
            .into_parts()
            .0;
        signer
            .sign_request(&Context::new(), &mut header_parts, Some(&credential), None)
            .await?;
        assert_eq!(header_parts.uri.to_string(), original_uri);
        assert_eq!(header_parts.headers["x-custom"], " value ");

        let mut query_parts = Request::get(&original_uri).body(())?.into_parts().0;
        signer
            .sign_request(
                &Context::new(),
                &mut query_parts,
                Some(&credential),
                Some(Duration::from_secs(60)),
            )
            .await?;
        assert!(
            query_parts
                .uri
                .to_string()
                .starts_with(&format!("{original_uri}X-Amz-Algorithm="))
        );
        assert!(
            query_parts
                .uri
                .query()
                .unwrap()
                .contains("X-Amz-Signature=")
        );

        Ok(())
    }

    #[tokio::test]
    async fn test() -> Result<()> {
        for (name, req) in test_cases() {
            calculate(req)
                .await
                .unwrap_or_else(|err| panic!("calculate {name} should pass: {err:?}"));
            calculate_in_query(req)
                .await
                .unwrap_or_else(|err| panic!("calculate_in_query {name} should pass: {err:?}"));
            test_calculate_with_token(req).await.unwrap_or_else(|err| {
                panic!("test_calculate_with_token {name} should pass: {err:?}")
            });
            test_calculate_with_token_in_query(req)
                .await
                .unwrap_or_else(|err| {
                    panic!("test_calculate_with_token_in_query {name} should pass: {err:?}")
                });
        }
        Ok(())
    }

    async fn calculate(req_fn: fn() -> Request<&'static str>) -> Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();

        let mut req = req_fn();
        let name = format!(
            "{} {} {:?}",
            req.method(),
            req.uri().path(),
            req.uri().query(),
        );
        let now = Timestamp::now();

        let mut ss = SigningSettings::default();
        ss.percent_encoding_mode = PercentEncodingMode::Double;
        ss.payload_checksum_kind = PayloadChecksumKind::XAmzSha256;
        let id = Credentials::new(
            "access_key_id",
            "secret_access_key",
            None,
            None,
            "hardcoded-credentials",
        )
        .into();
        let sp = v4::SigningParams::builder()
            .identity(&id)
            .region("test")
            .name("s3")
            .time(now.as_system_time())
            .settings(ss)
            .build()
            .expect("signing params must be valid");

        let mut body = SignableBody::UnsignedPayload;
        if req.headers().get(X_AMZ_CONTENT_SHA_256).is_some() {
            body = SignableBody::Bytes(req.body().as_bytes());
        }

        let output = aws_sigv4::http_request::sign(
            SignableRequest::new(
                req.method().as_str(),
                req.uri().to_string(),
                req.headers()
                    .iter()
                    .map(|(k, v)| (k.as_str(), std::str::from_utf8(v.as_bytes()).unwrap())),
                body,
            )
            .unwrap(),
            &sp.into(),
        )?;
        let (aws_sig, _) = output.into_parts();
        aws_sig.apply_to_request_http1x(&mut req);
        let expected_req = req;

        let req = req_fn();
        let (mut parts, body) = req.into_parts();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let loader = StaticCredentialProvider::new("access_key_id", "secret_access_key");
        let cred = loader.provide_credential(&ctx).await?.unwrap();

        let builder = RequestSigner::new("s3", "test").with_time(now);
        builder
            .sign_request(&ctx, &mut parts, Some(&cred), None)
            .await
            .expect("must apply success");

        let actual_req = Request::from_parts(parts, body);

        compare_request(&name, &expected_req, &actual_req);

        Ok(())
    }

    async fn calculate_in_query(req_fn: fn() -> Request<&'static str>) -> Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();

        let mut req = req_fn();
        let name = format!(
            "{} {} {:?}",
            req.method(),
            req.uri().path(),
            req.uri().query(),
        );
        let now = Timestamp::now();

        let mut ss = SigningSettings::default();
        ss.percent_encoding_mode = PercentEncodingMode::Double;
        ss.payload_checksum_kind = PayloadChecksumKind::XAmzSha256;
        ss.signature_location = SignatureLocation::QueryParams;
        ss.expires_in = Some(Duration::from_secs(3600));
        let id = Credentials::new(
            "access_key_id",
            "secret_access_key",
            None,
            None,
            "hardcoded-credentials",
        )
        .into();
        let sp = v4::SigningParams::builder()
            .identity(&id)
            .region("test")
            .name("s3")
            .time(now.as_system_time())
            .settings(ss)
            .build()
            .expect("signing params must be valid");

        let mut body = SignableBody::UnsignedPayload;
        if req.headers().get(X_AMZ_CONTENT_SHA_256).is_some() {
            body = SignableBody::Bytes(req.body().as_bytes());
        }

        let output = aws_sigv4::http_request::sign(
            SignableRequest::new(
                req.method().as_str(),
                req.uri().to_string(),
                req.headers()
                    .iter()
                    .map(|(k, v)| (k.as_str(), std::str::from_utf8(v.as_bytes()).unwrap())),
                body,
            )
            .unwrap(),
            &sp.into(),
        )
        .expect("signing must succeed");
        let (aws_sig, _) = output.into_parts();
        aws_sig.apply_to_request_http1x(&mut req);
        let expected_req = req;

        let req = req_fn();
        let (mut parts, body) = req.into_parts();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let loader = StaticCredentialProvider::new("access_key_id", "secret_access_key");
        let cred = loader.provide_credential(&ctx).await?.unwrap();

        let builder = RequestSigner::new("s3", "test").with_time(now);

        builder
            .sign_request(
                &ctx,
                &mut parts,
                Some(&cred),
                Some(Duration::from_secs(3600)),
            )
            .await?;
        let actual_req = Request::from_parts(parts, body);

        compare_request(&name, &expected_req, &actual_req);

        Ok(())
    }

    async fn test_calculate_with_token(req_fn: fn() -> Request<&'static str>) -> Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();

        let mut req = req_fn();
        let name = format!(
            "{} {} {:?}",
            req.method(),
            req.uri().path(),
            req.uri().query(),
        );
        let now = Timestamp::now();

        let mut ss = SigningSettings::default();
        ss.percent_encoding_mode = PercentEncodingMode::Double;
        ss.payload_checksum_kind = PayloadChecksumKind::XAmzSha256;
        let id = Credentials::new(
            "access_key_id",
            "secret_access_key",
            Some("security_token".to_string()),
            None,
            "hardcoded-credentials",
        )
        .into();
        let sp = v4::SigningParams::builder()
            .identity(&id)
            .region("test")
            .name("s3")
            .time(now.as_system_time())
            .settings(ss)
            .build()
            .expect("signing params must be valid");

        let mut body = SignableBody::UnsignedPayload;
        if req.headers().get(X_AMZ_CONTENT_SHA_256).is_some() {
            body = SignableBody::Bytes(req.body().as_bytes());
        }

        let output = aws_sigv4::http_request::sign(
            SignableRequest::new(
                req.method().as_str(),
                req.uri().to_string(),
                req.headers()
                    .iter()
                    .map(|(k, v)| (k.as_str(), std::str::from_utf8(v.as_bytes()).unwrap())),
                body,
            )
            .unwrap(),
            &sp.into(),
        )
        .expect("signing must succeed");
        let (aws_sig, _) = output.into_parts();
        aws_sig.apply_to_request_http1x(&mut req);
        let expected_req = req;

        let req = req_fn();
        let (mut parts, body) = req.into_parts();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let loader = StaticCredentialProvider::new("access_key_id", "secret_access_key")
            .with_session_token("security_token");
        let cred = loader.provide_credential(&ctx).await?.unwrap();

        let builder = RequestSigner::new("s3", "test").with_time(now);
        builder
            .sign_request(&ctx, &mut parts, Some(&cred), None)
            .await
            .expect("must apply success");
        let actual_req = Request::from_parts(parts, body);

        compare_request(&name, &expected_req, &actual_req);

        Ok(())
    }

    async fn test_calculate_with_token_in_query(
        req_fn: fn() -> Request<&'static str>,
    ) -> Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();

        let mut req = req_fn();
        let name = format!(
            "{} {} {:?}",
            req.method(),
            req.uri().path(),
            req.uri().query(),
        );
        let now = Timestamp::now();

        let mut ss = SigningSettings::default();
        ss.percent_encoding_mode = PercentEncodingMode::Double;
        ss.payload_checksum_kind = PayloadChecksumKind::XAmzSha256;
        ss.signature_location = SignatureLocation::QueryParams;
        ss.expires_in = Some(Duration::from_secs(3600));
        let id = Credentials::new(
            "access_key_id",
            "secret_access_key",
            Some("security_token".to_string()),
            None,
            "hardcoded-credentials",
        )
        .into();
        let sp = v4::SigningParams::builder()
            .identity(&id)
            .region("test")
            // .security_token("security_token")
            .name("s3")
            .time(now.as_system_time())
            .settings(ss)
            .build()
            .expect("signing params must be valid");

        let mut body = SignableBody::UnsignedPayload;
        if req.headers().get(X_AMZ_CONTENT_SHA_256).is_some() {
            body = SignableBody::Bytes(req.body().as_bytes());
        }

        let output = aws_sigv4::http_request::sign(
            SignableRequest::new(
                req.method().as_str(),
                req.uri().to_string(),
                req.headers()
                    .iter()
                    .map(|(k, v)| (k.as_str(), std::str::from_utf8(v.as_bytes()).unwrap())),
                body,
            )
            .unwrap(),
            &sp.into(),
        )
        .expect("signing must succeed");
        let (aws_sig, _) = output.into_parts();
        aws_sig.apply_to_request_http1x(&mut req);
        let expected_req = req;

        let req = req_fn();
        let (mut parts, body) = req.into_parts();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let loader = StaticCredentialProvider::new("access_key_id", "secret_access_key")
            .with_session_token("security_token");
        let cred = loader.provide_credential(&ctx).await?.unwrap();

        let builder = RequestSigner::new("s3", "test").with_time(now);
        builder
            .sign_request(
                &ctx,
                &mut parts,
                Some(&cred),
                Some(Duration::from_secs(3600)),
            )
            .await
            .expect("must apply success");
        let actual_req = Request::from_parts(parts, body);

        compare_request(&name, &expected_req, &actual_req);

        Ok(())
    }
}
