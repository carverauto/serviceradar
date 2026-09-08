use crate::constants::*;
use crate::Credential;
use async_trait::async_trait;
use http::request::Parts;
use http::{header, HeaderValue};
use log::debug;
use percent_encoding::percent_encode;
use reqsign_core::hash::{base64_decode, base64_hmac_sha256};
use reqsign_core::time::{format_http_date, now, DateTime};
use reqsign_core::{Context, Result, SignRequest, SigningMethod, SigningRequest};
use std::fmt::Write;
use std::time::Duration;

/// RequestSigner that implement Azure Storage Shared Key Authorization.
///
/// - [Authorize with Shared Key](https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key)
#[derive(Debug)]
pub struct RequestSigner {
    time: Option<DateTime>,
}

impl RequestSigner {
    /// Create a new builder for Azure Storage signer.
    pub fn new() -> Self {
        Self { time: None }
    }

    /// Specify the signing time.
    ///
    /// # Note
    ///
    /// We should always take current time to sign requests.
    /// Only use this function for testing.
    #[cfg(test)]
    pub fn with_time(mut self, time: DateTime) -> Self {
        self.time = Some(time);
        self
    }
}

impl Default for RequestSigner {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl SignRequest for RequestSigner {
    type Credential = Credential;

    async fn sign_request(
        &self,
        _: &Context,
        req: &mut Parts,
        credential: Option<&Self::Credential>,
        expires_in: Option<Duration>,
    ) -> Result<()> {
        let Some(cred) = credential else {
            return Err(reqsign_core::Error::request_invalid(
                "credential is required",
            ));
        };

        let method = if let Some(expires_in) = expires_in {
            SigningMethod::Query(expires_in)
        } else {
            SigningMethod::Header
        };

        let mut ctx = SigningRequest::build(req)?;

        // Handle different credential types
        match cred {
            Credential::SasToken { token } => {
                // SAS token authentication
                ctx.query_append(token);
            }
            Credential::BearerToken { token, .. } => {
                // Bearer token authentication
                match method {
                    SigningMethod::Query(_) => {
                        return Err(reqsign_core::Error::request_invalid(
                            "BearerToken can't be used in query string",
                        ));
                    }
                    SigningMethod::Header => {
                        ctx.headers.insert(
                            X_MS_DATE,
                            format_http_date(now()).parse().map_err(|e| {
                                reqsign_core::Error::unexpected("failed to parse date header")
                                    .with_source(e)
                            })?,
                        );
                        ctx.headers.insert(header::AUTHORIZATION, {
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
                        // try sign request use account_sas token
                        let signer = crate::account_sas::AccountSharedAccessSignature::new(
                            account_name.clone(),
                            account_key.clone(),
                            now()
                                + chrono::TimeDelta::from_std(d).map_err(|e| {
                                    reqsign_core::Error::unexpected("failed to convert duration")
                                        .with_source(e)
                                })?,
                        );
                        let signer_token = signer.token().map_err(|e| {
                            reqsign_core::Error::unexpected("failed to generate account SAS token")
                                .with_source(e)
                        })?;
                        signer_token.iter().for_each(|(k, v)| {
                            ctx.query_push(k, v);
                        });
                    }
                    SigningMethod::Header => {
                        let now_time = self.time.unwrap_or_else(now);
                        let string_to_sign = string_to_sign(&mut ctx, account_name, now_time)?;
                        let decode_content = base64_decode(account_key).map_err(|e| {
                            reqsign_core::Error::unexpected("failed to decode account key")
                                .with_source(e)
                        })?;
                        let signature =
                            base64_hmac_sha256(&decode_content, string_to_sign.as_bytes());

                        ctx.headers.insert(header::AUTHORIZATION, {
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

        // Apply percent encoding for query parameters
        for (_, v) in ctx.query.iter_mut() {
            *v = percent_encode(v.as_bytes(), &AZURE_QUERY_ENCODE_SET).to_string();
        }

        ctx.apply(req)
    }
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
/// For sub-requests of batch API, requests should be signed without `x-ms-version` header.
/// Set the `omit_service_version` to `ture` for such.
///
/// ## Reference
///
/// - [Blob, Queue, and File Services (Shared Key authorization)](https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key)
fn string_to_sign(
    ctx: &mut SigningRequest,
    account_name: &str,
    now_time: DateTime,
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

    debug!("string to sign: {}", &s);

    Ok(s)
}

/// ## Reference
///
/// - [Constructing the canonicalized headers string](https://docs.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key#constructing-the-canonicalized-headers-string)
fn canonicalize_header(ctx: &mut SigningRequest, now_time: DateTime) -> Result<String> {
    ctx.headers.insert(
        X_MS_DATE,
        format_http_date(now_time).parse().map_err(|e| {
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
fn canonicalize_resource(ctx: &mut SigningRequest, account_name: &str) -> String {
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
        SigningRequest::query_to_percent_decoded_string(query, ":", "\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use http::Request;
    use reqsign_core::{Context, OsEnv};
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::time::Duration;

    #[tokio::test]
    async fn test_sas_token() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let cred = Credential::with_sas_token("sv=2021-01-01&ss=b&srt=c&sp=rwdlaciytfx&se=2022-01-01T11:00:14Z&st=2022-01-02T03:00:14Z&spr=https&sig=KEllk4N8f7rJfLjQCmikL2fRVt%2B%2Bl73UBkbgH%2FK3VGE%3D");

        let builder = RequestSigner::new();

        // Construct request
        let req = Request::builder()
            .uri("https://test.blob.core.windows.net/testbucket/testblob")
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        // Test query signing
        assert!(builder
            .sign_request(&ctx, &mut parts, Some(&cred), Some(Duration::from_secs(1)))
            .await
            .is_ok());
        assert_eq!(parts.uri, "https://test.blob.core.windows.net/testbucket/testblob?sv=2021-01-01&ss=b&srt=c&sp=rwdlaciytfx&se=2022-01-01T11:00:14Z&st=2022-01-02T03:00:14Z&spr=https&sig=KEllk4N8f7rJfLjQCmikL2fRVt%2B%2Bl73UBkbgH%2FK3VGE%3D")
    }

    #[tokio::test]
    async fn test_bearer_token() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let cred = Credential::with_bearer_token(
            "token",
            Some(now() + chrono::TimeDelta::try_hours(1).unwrap()),
        );
        let builder = RequestSigner::new();

        let req = Request::builder()
            .uri("https://test.blob.core.windows.net/testbucket/testblob")
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();

        // Can effectively sign request with header method
        assert!(builder
            .sign_request(&ctx, &mut parts, Some(&cred), None)
            .await
            .is_ok());
        let authorization = parts
            .headers
            .get("Authorization")
            .unwrap()
            .to_str()
            .unwrap();
        assert_eq!("Bearer token", authorization);

        // Will not sign request with query method
        let req = Request::builder()
            .uri("https://test.blob.core.windows.net/testbucket/testblob")
            .body(())
            .unwrap();
        let (mut parts, _) = req.into_parts();
        assert!(builder
            .sign_request(&ctx, &mut parts, Some(&cred), Some(Duration::from_secs(1)))
            .await
            .is_err());
    }
}
