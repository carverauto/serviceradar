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
use crate::constants::*;
use http::request::Parts;
use http::{HeaderValue, Uri, header};
use log::debug;
use percent_encoding::{percent_decode_str, percent_encode};
use reqsign_core::hash::{base64_decode, base64_hmac_sha256};
use reqsign_core::time::Timestamp;
use reqsign_core::{
    Context, Result, SignRequest, SigningCredential, SigningMethod, SigningRequest,
};
use std::fmt::Write;
use std::sync::Mutex;
use std::time::Duration;

const BEARER_TOKEN_OPERATION_HEADROOM: Duration = Duration::from_secs(20);

/// Resource kind required by SAS generation.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum SasResourceKind {
    /// Container SAS.
    Container,
    /// Blob SAS.
    Blob,
}

/// RequestSigner that implement Azure Storage Shared Key Authorization.
///
/// - [Authorize with Shared Key](https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key)
#[derive(Debug)]
pub struct RequestSigner {
    time: Option<Timestamp>,
    service_sas_permissions: Option<String>,
    service_sas_start: Option<Timestamp>,
    service_sas_ip: Option<String>,
    service_sas_protocol: Option<String>,
    service_sas_version: Option<String>,

    user_delegation_presign: Option<UserDelegationPresignConfig>,
    user_delegation_key_cache: Mutex<Option<crate::user_delegation::UserDelegationKey>>,
}

#[derive(Clone, Debug)]
struct UserDelegationPresignConfig {
    resource: SasResourceKind,
    permissions: String,
    start: Option<Timestamp>,
    ip: Option<String>,
    protocol: Option<String>,
    version: Option<String>,
}

impl RequestSigner {
    /// Create a new builder for Azure Storage signer.
    pub fn new() -> Self {
        Self {
            time: None,
            service_sas_permissions: None,
            service_sas_start: None,
            service_sas_ip: None,
            service_sas_protocol: None,
            service_sas_version: None,

            user_delegation_presign: None,
            user_delegation_key_cache: Mutex::new(None),
        }
    }

    /// Configure Service SAS presign permissions for Shared Key query signing.
    ///
    /// This setting is required when `expires_in` is provided and credential is `SharedKey`.
    pub fn with_service_sas_permissions(mut self, permissions: &str) -> Self {
        self.service_sas_permissions = Some(permissions.to_string());
        self
    }

    /// Configure Service SAS presign start time for Shared Key query signing.
    pub fn with_service_sas_start(mut self, start: Timestamp) -> Self {
        self.service_sas_start = Some(start);
        self
    }

    /// Configure Service SAS presign allowed IP range.
    pub fn with_service_sas_ip(mut self, ip: &str) -> Self {
        self.service_sas_ip = Some(ip.to_string());
        self
    }

    /// Configure Service SAS presign allowed protocol, e.g. `https` or `https,http`.
    pub fn with_service_sas_protocol(mut self, protocol: &str) -> Self {
        self.service_sas_protocol = Some(protocol.to_string());
        self
    }

    /// Configure Service SAS presign service version.
    pub fn with_service_sas_version(mut self, version: &str) -> Self {
        self.service_sas_version = Some(version.to_string());
        self
    }

    /// Enable User Delegation SAS presign for Bearer Token query signing.
    ///
    /// This is only used when `expires_in` is provided and credential is `BearerToken`.
    pub fn with_user_delegation_presign(
        mut self,
        resource: SasResourceKind,
        permissions: &str,
    ) -> Self {
        self.user_delegation_presign = Some(UserDelegationPresignConfig {
            resource,
            permissions: permissions.to_string(),
            start: None,
            ip: None,
            protocol: None,
            version: None,
        });
        self
    }

    /// Configure User Delegation SAS presign start time.
    pub fn with_user_delegation_start(mut self, start: Timestamp) -> Self {
        if let Some(cfg) = self.user_delegation_presign.as_mut() {
            cfg.start = Some(start);
        }
        self
    }

    /// Configure User Delegation SAS presign allowed IP range.
    pub fn with_user_delegation_ip(mut self, ip: &str) -> Self {
        if let Some(cfg) = self.user_delegation_presign.as_mut() {
            cfg.ip = Some(ip.to_string());
        }
        self
    }

    /// Configure User Delegation SAS presign allowed protocol, e.g. `https` or `https,http`.
    pub fn with_user_delegation_protocol(mut self, protocol: &str) -> Self {
        if let Some(cfg) = self.user_delegation_presign.as_mut() {
            cfg.protocol = Some(protocol.to_string());
        }
        self
    }

    /// Configure User Delegation SAS presign service version.
    pub fn with_user_delegation_version(mut self, version: &str) -> Self {
        if let Some(cfg) = self.user_delegation_presign.as_mut() {
            cfg.version = Some(version.to_string());
        }
        self
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
        credential: &Credential,
        signing_time: Timestamp,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        match credential {
            Credential::BearerToken { .. } => {
                let cached_key_covers_operation = expires_in.is_some_and(|expires| {
                    self.user_delegation_key_cache
                        .lock()
                        .expect("lock poisoned")
                        .as_ref()
                        .is_some_and(|key| {
                            key.signed_expiry
                                > signing_time + expires + BEARER_TOKEN_OPERATION_HEADROOM
                        })
                });

                if cached_key_covers_operation {
                    signing_time
                } else {
                    signing_time + BEARER_TOKEN_OPERATION_HEADROOM
                }
            }
            Credential::SharedKey { .. } | Credential::SasToken { .. } => signing_time,
        }
    }
}

impl Default for RequestSigner {
    fn default() -> Self {
        Self::new()
    }
}
impl SignRequest for RequestSigner {
    type Credential = Credential;

    fn required_valid_until(
        &self,
        credential: &Self::Credential,
        expires_in: Option<Duration>,
    ) -> Timestamp {
        self.required_valid_until_at(credential, self.get_time(), expires_in)
    }

    async fn sign_request(
        &self,
        context: &Context,
        req: &mut Parts,
        credential: Option<&Self::Credential>,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        let Some(cred) = credential else {
            return Ok(());
        };

        let signing_time = self.get_time();
        let required_until = self.required_valid_until_at(cred, signing_time, expires_in);
        if !cred.is_valid_at(required_until) {
            return Err(reqsign_core::Error::credential_invalid(
                "credential expires before the requested signing operation deadline",
            ));
        }
        let method = if let Some(expires_in) = expires_in {
            SigningMethod::Query(expires_in)
        } else {
            SigningMethod::Header
        };

        let original_uri = req.uri.clone();
        let mut sctx = SigningRequest::build(req)?;
        let mut final_uri = None;

        // Handle different credential types
        match cred {
            Credential::SasToken { token } => {
                // SAS token authentication
                final_uri = Some(append_query_fragment(&original_uri, token)?);
            }
            Credential::BearerToken { token, .. } => {
                // Bearer token authentication
                match method {
                    SigningMethod::Query(d) => {
                        let Some(cfg) = &self.user_delegation_presign else {
                            return Err(reqsign_core::Error::request_invalid(
                                "BearerToken can't be used in query string",
                            ));
                        };

                        let expiry = signing_time + d;

                        let resource = service_sas_resource(&sctx.path)?;
                        match (cfg.resource, &resource) {
                            (
                                SasResourceKind::Container,
                                crate::service_sas::ServiceSasResource::Container { .. },
                            ) => {}
                            (
                                SasResourceKind::Blob,
                                crate::service_sas::ServiceSasResource::Blob { .. },
                            ) => {}
                            _ => {
                                return Err(reqsign_core::Error::request_invalid(
                                    "request resource doesn't match configured SAS resource kind",
                                ));
                            }
                        }

                        let account = infer_account_name(sctx.authority.as_str())?;

                        let key = {
                            let cached = self
                                .user_delegation_key_cache
                                .lock()
                                .expect("lock poisoned")
                                .clone();
                            if let Some(cached) = cached {
                                if cached.signed_expiry > expiry + Duration::from_secs(20) {
                                    cached
                                } else {
                                    let version = cfg.version.as_deref().unwrap_or("2020-12-06");
                                    let fetched = crate::user_delegation::get_user_delegation_key(
                                        context,
                                        crate::user_delegation::UserDelegationKeyRequest {
                                            scheme: sctx.scheme.as_str(),
                                            authority: sctx.authority.as_str(),
                                            bearer_token: token,
                                            start: signing_time,
                                            expiry,
                                            service_version: version,
                                            now: signing_time,
                                        },
                                    )
                                    .await?;
                                    *self
                                        .user_delegation_key_cache
                                        .lock()
                                        .expect("lock poisoned") = Some(fetched.clone());
                                    fetched
                                }
                            } else {
                                let version = cfg.version.as_deref().unwrap_or("2020-12-06");
                                let fetched = crate::user_delegation::get_user_delegation_key(
                                    context,
                                    crate::user_delegation::UserDelegationKeyRequest {
                                        scheme: sctx.scheme.as_str(),
                                        authority: sctx.authority.as_str(),
                                        bearer_token: token,
                                        start: signing_time,
                                        expiry,
                                        service_version: version,
                                        now: signing_time,
                                    },
                                )
                                .await?;
                                *self
                                    .user_delegation_key_cache
                                    .lock()
                                    .expect("lock poisoned") = Some(fetched.clone());
                                fetched
                            }
                        };

                        let mut signer =
                            crate::user_delegation::UserDelegationSharedAccessSignature::new(
                                account,
                                key,
                                resource,
                                cfg.permissions.to_string(),
                                expiry,
                            );
                        if let Some(start) = cfg.start {
                            signer = signer.with_start(start);
                        }
                        if let Some(ip) = &cfg.ip {
                            signer = signer.with_ip(ip);
                        }
                        if let Some(protocol) = &cfg.protocol {
                            signer = signer.with_protocol(protocol);
                        }
                        if let Some(version) = &cfg.version {
                            signer = signer.with_version(version);
                        }

                        let signer_token = signer.token().map_err(|e| {
                            reqsign_core::Error::unexpected(
                                "failed to generate user delegation SAS token",
                            )
                            .with_source(e)
                        })?;
                        final_uri = Some(append_query_pairs(&original_uri, &signer_token)?);
                    }
                    SigningMethod::Header => {
                        sctx.headers.insert(
                            X_MS_DATE,
                            signing_time.format_http_date().parse().map_err(|e| {
                                reqsign_core::Error::unexpected("failed to parse date header")
                                    .with_source(e)
                            })?,
                        );
                        sctx.headers.insert(header::AUTHORIZATION, {
                            let mut value: HeaderValue =
                                format!("Bearer {token}").parse().map_err(|e| {
                                    reqsign_core::Error::unexpected(
                                        "failed to parse authorization header",
                                    )
                                    .with_source(e)
                                })?;
                            value.set_sensitive(true);
                            value
                        });
                    }
                }
            }
            Credential::SharedKey {
                account_name,
                account_key,
            } => {
                // Shared key authentication
                match method {
                    SigningMethod::Query(d) => {
                        let Some(permissions) = &self.service_sas_permissions else {
                            return Err(reqsign_core::Error::request_invalid(
                                "Service SAS permissions are required for presign",
                            ));
                        };

                        let resource = service_sas_resource(&sctx.path)?;

                        let mut signer = crate::service_sas::ServiceSharedAccessSignature::new(
                            account_name.clone(),
                            account_key.clone(),
                            resource,
                            permissions.to_string(),
                            signing_time + d,
                        );
                        if let Some(start) = self.service_sas_start {
                            signer = signer.with_start(start);
                        }
                        if let Some(ip) = &self.service_sas_ip {
                            signer = signer.with_ip(ip);
                        }
                        if let Some(protocol) = &self.service_sas_protocol {
                            signer = signer.with_protocol(protocol);
                        }
                        if let Some(version) = &self.service_sas_version {
                            signer = signer.with_version(version);
                        }

                        let signer_token = signer.token().map_err(|e| {
                            reqsign_core::Error::unexpected("failed to generate service SAS token")
                                .with_source(e)
                        })?;
                        final_uri = Some(append_query_pairs(&original_uri, &signer_token)?);
                    }
                    SigningMethod::Header => {
                        let string_to_sign = string_to_sign(&mut sctx, account_name, signing_time)?;
                        let decode_content = base64_decode(account_key).map_err(|e| {
                            reqsign_core::Error::unexpected("failed to decode account key")
                                .with_source(e)
                        })?;
                        let signature =
                            base64_hmac_sha256(&decode_content, string_to_sign.as_bytes());

                        sctx.headers.insert(header::AUTHORIZATION, {
                            let mut value: HeaderValue =
                                format!("SharedKey {account_name}:{signature}")
                                    .parse()
                                    .map_err(|e| {
                                        reqsign_core::Error::unexpected(
                                            "failed to parse authorization header",
                                        )
                                        .with_source(e)
                                    })?;
                            value.set_sensitive(true);
                            value
                        });
                    }
                }
            }
        }

        sctx.apply(req)?;
        if let Some(uri) = final_uri {
            req.uri = uri;
        }
        Ok(())
    }
}

fn service_sas_resource(path: &str) -> Result<crate::service_sas::ServiceSasResource> {
    let mut segments = path
        .strip_prefix('/')
        .unwrap_or(path)
        .split('/')
        .filter(|segment| !segment.is_empty())
        .map(|segment| percent_decode_str(segment).decode_utf8_lossy().into_owned());
    let container = segments
        .next()
        .ok_or_else(|| reqsign_core::Error::request_invalid("missing container in path"))?;
    let rest = segments.collect::<Vec<_>>();

    if rest.is_empty() {
        Ok(crate::service_sas::ServiceSasResource::Container { container })
    } else {
        Ok(crate::service_sas::ServiceSasResource::Blob {
            container,
            blob: rest.join("/"),
        })
    }
}

fn append_query_pairs(uri: &Uri, pairs: &[(String, String)]) -> Result<Uri> {
    let fragment = pairs
        .iter()
        .map(|(key, value)| {
            format!(
                "{}={}",
                percent_encode(key.as_bytes(), &AZURE_QUERY_ENCODE_SET),
                percent_encode(value.as_bytes(), &AZURE_QUERY_ENCODE_SET)
            )
        })
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
        reqsign_core::Error::request_invalid("failed to append SAS query fragment").with_source(e)
    })
}

fn infer_account_name(authority: &str) -> Result<String> {
    let host = authority.split('@').next_back().unwrap_or(authority);
    let host = host.split(':').next().unwrap_or(host);
    let Some((account, _)) = host.split_once('.') else {
        return Err(reqsign_core::Error::request_invalid(
            "failed to infer account name from authority",
        ));
    };
    Ok(account.to_string())
}

/// Construct string to sign
///
/// ## Format
///
/// ```text
/// VERB + "\n" +
/// Content-Encoding + "\n" +
/// Content-Language + "\n" +
/// Content-Length + "\n" +
/// Content-MD5 + "\n" +
/// Content-Type + "\n" +
/// Date + "\n" +
/// If-Modified-Since + "\n" +
/// If-Match + "\n" +
/// If-None-Match + "\n" +
/// If-Unmodified-Since + "\n" +
/// Range + "\n" +
/// CanonicalizedHeaders +
/// CanonicalizedResource;
/// ```
/// ## Note
///
/// Reqsign signs the Azure service headers already present on the request.
/// Callers should include `x-ms-version` for ordinary Azure Storage requests,
/// but omit it for batch API sub-requests, which Azure requires to be signed
/// without that header.
///
/// ## Reference
///
/// - [Blob, Queue, and File Services (Shared Key authorization)](https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key)
fn string_to_sign(
    ctx: &mut SigningRequest,
    account_name: &str,
    now_time: Timestamp,
) -> Result<String> {
    let mut s = String::with_capacity(128);

    writeln!(&mut s, "{}", ctx.method.as_str()).map_err(|e| {
        reqsign_core::Error::unexpected("failed to write method to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::CONTENT_ENCODING)
            .map_err(|e| reqsign_core::Error::unexpected(
                "failed to get content-encoding header"
            )
            .with_source(e))?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write content-encoding to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::CONTENT_LANGUAGE)
            .map_err(|e| reqsign_core::Error::unexpected(
                "failed to get content-language header"
            )
            .with_source(e))?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write content-language to string").with_source(e)
    })?;
    writeln!(&mut s, "{}", {
        let content_length = ctx
            .header_get_or_default(&header::CONTENT_LENGTH)
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to get content-length header")
                    .with_source(e)
            })?;
        if content_length == "0" {
            ""
        } else {
            content_length
        }
    })
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write content-length to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&"content-md5".parse().map_err(|e| {
            reqsign_core::Error::unexpected("failed to parse content-md5 header name")
                .with_source(e)
        })?)
        .map_err(
            |e| reqsign_core::Error::unexpected("failed to get content-md5 header").with_source(e)
        )?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write content-md5 to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::CONTENT_TYPE)
            .map_err(
                |e| reqsign_core::Error::unexpected("failed to get content-type header")
                    .with_source(e)
            )?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write content-type to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::DATE)
            .map_err(
                |e| reqsign_core::Error::unexpected("failed to get date header").with_source(e)
            )?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write date to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::IF_MODIFIED_SINCE)
            .map_err(|e| reqsign_core::Error::unexpected(
                "failed to get if-modified-since header"
            )
            .with_source(e))?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write if-modified-since to string")
            .with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::IF_MATCH).map_err(|e| {
            reqsign_core::Error::unexpected("failed to get if-match header").with_source(e)
        })?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write if-match to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::IF_NONE_MATCH)
            .map_err(
                |e| reqsign_core::Error::unexpected("failed to get if-none-match header")
                    .with_source(e)
            )?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write if-none-match to string").with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::IF_UNMODIFIED_SINCE)
            .map_err(|e| reqsign_core::Error::unexpected(
                "failed to get if-unmodified-since header"
            )
            .with_source(e))?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write if-unmodified-since to string")
            .with_source(e)
    })?;
    writeln!(
        &mut s,
        "{}",
        ctx.header_get_or_default(&header::RANGE)
            .map_err(
                |e| reqsign_core::Error::unexpected("failed to get range header").with_source(e)
            )?
    )
    .map_err(|e| {
        reqsign_core::Error::unexpected("failed to write range to string").with_source(e)
    })?;
    writeln!(&mut s, "{}", canonicalize_header(ctx, now_time)?).map_err(|e| {
        reqsign_core::Error::unexpected("failed to write canonicalized headers to string")
            .with_source(e)
    })?;
    write!(&mut s, "{}", canonicalize_resource(ctx, account_name)).map_err(|e| {
        reqsign_core::Error::unexpected("failed to write canonicalized resource to string")
            .with_source(e)
    })?;

    debug!("string to sign: {}", s);

    Ok(s)
}

/// ## Reference
///
/// - [Constructing the canonicalized headers string](https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key#constructing-the-canonicalized-headers-string)
fn canonicalize_header(ctx: &mut SigningRequest, now_time: Timestamp) -> Result<String> {
    ctx.headers.insert(
        X_MS_DATE,
        now_time.format_http_date().parse().map_err(|e| {
            reqsign_core::Error::unexpected("failed to parse x-ms-date header").with_source(e)
        })?,
    );

    Ok(SigningRequest::header_to_string(
        ctx.header_to_vec_with_prefix("x-ms-"),
        ":",
        "\n",
    ))
}

/// ## Reference
///
/// - [Constructing the canonicalized resource string](https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key#constructing-the-canonicalized-resource-string)
fn canonicalize_resource(ctx: &SigningRequest, account_name: &str) -> String {
    if ctx.query.is_empty() {
        return format!("/{}{}", account_name, ctx.path);
    }

    let query = ctx
        .query
        .iter()
        .map(|(k, v)| (k.to_lowercase(), v.clone()))
        .collect();

    format!(
        "/{}{}\n{}",
        account_name,
        ctx.path,
        SigningRequest::query_to_string(query, ":", "\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use http::Request;
    use reqsign_core::{Context, HttpSend, OsEnv};
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::str::FromStr;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    const RAW_QUERY: &str = "slash=%2F&hash=%23&amp=%26&equals=%3D&space=%20&encoded-plus=%2B&literal-plus=+&double=%252F&dup=first&dup=second&=empty-key&empty=&flag&flag=&";

    #[test]
    fn bearer_deadline_covers_rpc_not_generated_sas_lifetime() {
        let now: Timestamp = "2026-07-22T00:00:00Z"
            .parse()
            .expect("timestamp must parse");
        let signer = RequestSigner::new().with_time(now);
        let bearer = Credential::with_bearer_token("token", None);
        let shared_key = Credential::with_shared_key("account", "key");

        assert_eq!(
            signer.required_valid_until(&bearer, Some(Duration::from_secs(3600))),
            now + BEARER_TOKEN_OPERATION_HEADROOM
        );
        assert_eq!(
            signer.required_valid_until(&shared_key, Some(Duration::from_secs(3600))),
            now
        );
    }

    #[test]
    fn canonical_resource_decodes_query_once_without_form_semantics() {
        let mut parts = Request::get(
            "https://account.blob.core.windows.net/container/blob?versionId=a%2Bb%3Dc%2525%26e&literal=+",
        )
        .body(())
        .unwrap()
        .into_parts()
        .0;
        let signing_req = SigningRequest::build(&mut parts).unwrap();

        assert_eq!(
            canonicalize_resource(&signing_req, "account"),
            "/account/container/blob\nliteral:+\nversionid:a+b=c%25&e"
        );
        assert_eq!(
            service_sas_resource("/container/blob%2Fname").unwrap(),
            crate::service_sas::ServiceSasResource::Blob {
                container: "container".to_string(),
                blob: "blob/name".to_string(),
            }
        );
        assert_eq!(
            service_sas_resource("/container%2Fname").unwrap(),
            crate::service_sas::ServiceSasResource::Container {
                container: "container/name".to_string(),
            }
        );
    }

    #[tokio::test]
    async fn test_sas_token() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let cred = Credential::with_sas_token(
            "sv=2021-01-01&ss=b&srt=c&sp=rwdlaciytfx&se=2022-01-01T11:00:14Z&st=2022-01-02T03:00:14Z&spr=https&sig=KEllk4N8f7rJfLjQCmikL2fRVt%2B%2Bl73UBkbgH%2FK3VGE%3D",
        );

        let builder = RequestSigner::new();
        let original_uri =
            format!("https://test.blob.core.windows.net/testbucket/testblob?{RAW_QUERY}");

        // Construct request
        let req = Request::builder().uri(&original_uri).body(()).unwrap();
        let (mut parts, _) = req.into_parts();

        // A SAS credential selects query authentication even without expires_in.
        assert!(
            builder
                .sign_request(&ctx, &mut parts, Some(&cred), None)
                .await
                .is_ok()
        );
        assert_eq!(
            parts.uri.to_string(),
            format!(
                "{original_uri}sv=2021-01-01&ss=b&srt=c&sp=rwdlaciytfx&se=2022-01-01T11:00:14Z&st=2022-01-02T03:00:14Z&spr=https&sig=KEllk4N8f7rJfLjQCmikL2fRVt%2B%2Bl73UBkbgH%2FK3VGE%3D"
            )
        )
    }

    #[tokio::test]
    async fn test_bearer_token() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let cred = Credential::with_bearer_token(
            "token",
            Some(Timestamp::now() + Duration::from_secs(3600)),
        );
        let builder = RequestSigner::new();

        let original_uri =
            format!("https://test.blob.core.windows.net/testbucket/testblob?{RAW_QUERY}");
        let req = Request::builder().uri(&original_uri).body(()).unwrap();
        let (mut parts, _) = req.into_parts();

        // Can effectively sign request with header method
        assert!(
            builder
                .sign_request(&ctx, &mut parts, Some(&cred), None)
                .await
                .is_ok()
        );
        let authorization = parts
            .headers
            .get("Authorization")
            .unwrap()
            .to_str()
            .unwrap();
        assert_eq!("Bearer token", authorization);
        assert_eq!(parts.uri.to_string(), original_uri);

        // Will not sign request with query method
        let req = Request::builder().uri(&original_uri).body(()).unwrap();
        let (mut parts, _) = req.into_parts();
        assert!(
            builder
                .sign_request(&ctx, &mut parts, Some(&cred), Some(Duration::from_secs(1)))
                .await
                .is_err()
        );
        assert_eq!(parts.uri.to_string(), original_uri);
    }

    #[tokio::test]
    async fn test_shared_key_presign_service_sas() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);

        let now = Timestamp::from_str("2022-03-01T08:12:34Z").unwrap();
        let key = reqsign_core::hash::base64_encode("key".as_bytes());
        let cred = Credential::with_shared_key("account", &key);

        let builder = RequestSigner::new()
            .with_time(now)
            .with_service_sas_permissions("r");

        let original_uri =
            format!("https://account.blob.core.windows.net/container/path/to/blob.txt?{RAW_QUERY}");
        let req = Request::builder().uri(&original_uri).body(()).unwrap();
        let (mut parts, _) = req.into_parts();

        builder
            .sign_request(
                &ctx,
                &mut parts,
                Some(&cred),
                Some(Duration::from_secs(300)),
            )
            .await
            .unwrap();

        assert_eq!(
            parts.uri.to_string(),
            format!(
                "{original_uri}sv=2020-12-06&se=2022-03-01T08%3A17%3A34Z&sp=r&sr=b&sig=CP9a2LIrR9zeG4I4jZjqPetJSXWJ77QeUA7c3GMypyM%3D"
            )
        );
    }

    #[derive(Clone, Debug, Default)]
    struct MockUserDelegationHttpSend {
        calls: Arc<AtomicUsize>,
    }
    impl HttpSend for MockUserDelegationHttpSend {
        async fn http_send(
            &self,
            req: http::Request<Bytes>,
        ) -> reqsign_core::Result<http::Response<Bytes>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if req.method() != http::Method::POST {
                return Err(reqsign_core::Error::unexpected("unexpected request method")
                    .with_context(req.method().to_string()));
            }

            let uri = req.uri().to_string();
            if uri
                != "https://account.blob.core.windows.net/?restype=service&comp=userdelegationkey"
            {
                return Err(
                    reqsign_core::Error::unexpected("unexpected request uri").with_context(uri)
                );
            }

            let version = req
                .headers()
                .get("x-ms-version")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_string();
            if version != "2020-12-06" {
                return Err(
                    reqsign_core::Error::unexpected("unexpected x-ms-version header")
                        .with_context(version),
                );
            }

            let date = req
                .headers()
                .get("x-ms-date")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_string();
            if date != "Tue, 01 Mar 2022 08:12:34 GMT" {
                return Err(
                    reqsign_core::Error::unexpected("unexpected x-ms-date header")
                        .with_context(date),
                );
            }

            let content_type = req
                .headers()
                .get(http::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_string();
            if content_type != "application/xml" {
                return Err(
                    reqsign_core::Error::unexpected("unexpected content-type header")
                        .with_context(content_type),
                );
            }

            let auth = req
                .headers()
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_string();
            if auth != "Bearer token" {
                return Err(
                    reqsign_core::Error::unexpected("unexpected authorization header")
                        .with_context(auth),
                );
            }

            let body = String::from_utf8_lossy(req.body()).to_string();
            if !body.contains("<KeyInfo>")
                || !body.contains("<Start>2022-03-01T08:12:34Z</Start>")
                || !body.contains("<Expiry>2022-03-01T08:17:34Z</Expiry>")
            {
                return Err(
                    reqsign_core::Error::unexpected("unexpected request body").with_context(body)
                );
            }

            let body = r#"
<UserDelegationKey>
  <SignedOid>oid</SignedOid>
  <SignedTid>tid</SignedTid>
  <SignedStart>2022-03-01T08:12:34Z</SignedStart>
  <SignedExpiry>2022-03-01T09:12:34Z</SignedExpiry>
  <SignedService>b</SignedService>
  <SignedVersion>2020-12-06</SignedVersion>
  <Value>a2V5</Value>
</UserDelegationKey>
"#;

            Ok(http::Response::builder()
                .status(200)
                .body(Bytes::from(body))
                .unwrap())
        }
    }

    #[tokio::test]
    async fn test_bearer_token_presign_user_delegation_sas() {
        let now = Timestamp::from_str("2022-03-01T08:12:34Z").unwrap();

        let http_send = MockUserDelegationHttpSend::default();
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(http_send.clone())
            .with_env(OsEnv);

        let cred = Credential::with_bearer_token("token", None);
        let builder = RequestSigner::new()
            .with_time(now)
            .with_user_delegation_presign(SasResourceKind::Blob, "r");

        let original_uri =
            format!("https://account.blob.core.windows.net/container/path/to/blob.txt?{RAW_QUERY}");
        let req = Request::builder().uri(&original_uri).body(()).unwrap();
        let (mut parts, _) = req.into_parts();

        builder
            .sign_request(
                &ctx,
                &mut parts,
                Some(&cred),
                Some(Duration::from_secs(300)),
            )
            .await
            .unwrap();

        assert_eq!(
            parts.uri.to_string(),
            format!(
                "{original_uri}sv=2020-12-06&se=2022-03-01T08%3A17%3A34Z&sp=r&sr=b&skoid=oid&sktid=tid&skt=2022-03-01T08%3A12%3A34Z&ske=2022-03-01T09%3A12%3A34Z&sks=b&skv=2020-12-06&sig=VkI3h/LWkD6qcDzshjQzCuCdMPDCFA3tMEbxM%2BED5Nc%3D"
            )
        );

        let near_expiry_cred =
            Credential::with_bearer_token("token", Some(now + Duration::from_secs(5)));
        assert_eq!(
            builder.required_valid_until(&near_expiry_cred, Some(Duration::from_secs(300))),
            now
        );

        let req = Request::builder().uri(&original_uri).body(()).unwrap();
        let (mut cached_parts, _) = req.into_parts();
        builder
            .sign_request(
                &ctx,
                &mut cached_parts,
                Some(&near_expiry_cred),
                Some(Duration::from_secs(300)),
            )
            .await
            .unwrap();
        assert_eq!(cached_parts.uri, parts.uri);
        assert_eq!(http_send.calls.load(Ordering::SeqCst), 1);
    }
}
