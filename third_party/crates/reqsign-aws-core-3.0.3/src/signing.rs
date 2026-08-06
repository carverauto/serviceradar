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

use std::fmt::Write;
use std::time::Duration;

use http::{HeaderValue, Uri, header};
use percent_encoding::{percent_decode_str, utf8_percent_encode};
use reqsign_core::time::Timestamp;
use reqsign_core::{Result, SigningRequest};

use crate::Credential;
use crate::constants::{
    AWS_QUERY_ENCODE_SET, AWS_URI_ENCODE_SET, X_AMZ_CONTENT_SHA_256, X_AMZ_DATE,
    X_AMZ_S3_SESSION_TOKEN, X_AMZ_SECURITY_TOKEN,
};

/// Build the canonical request shared by AWS SigV4-family algorithms.
pub fn canonical_request_string(
    request: &SigningRequest,
    canonical_query: &[(String, String)],
) -> Result<String> {
    let mut output = String::with_capacity(256);

    writeln!(output, "{}", request.method)
        .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write method: {e}")))?;
    writeln!(output, "{}", canonical_uri(&request.path)?).map_err(|e| {
        reqsign_core::Error::unexpected(format!("failed to write encoded path: {e}"))
    })?;
    writeln!(
        output,
        "{}",
        canonical_query
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>()
            .join("&")
    )
    .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write query: {e}")))?;

    let signed_headers = request.header_name_to_vec_sorted();
    for name in &signed_headers {
        let mut value = request.headers[*name].clone();
        SigningRequest::header_value_normalize(&mut value);
        writeln!(
            output,
            "{}:{}",
            name,
            value.to_str().map_err(|e| {
                reqsign_core::Error::request_invalid("invalid signed header value").with_source(e)
            })?
        )
        .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write header: {e}")))?;
    }
    writeln!(output)
        .map_err(|e| reqsign_core::Error::unexpected(format!("failed to write newline: {e}")))?;
    writeln!(output, "{}", signed_headers.join(";")).map_err(|e| {
        reqsign_core::Error::unexpected(format!("failed to write signed headers: {e}"))
    })?;

    if request.headers.get(X_AMZ_CONTENT_SHA_256).is_none() {
        write!(output, "UNSIGNED-PAYLOAD").map_err(|e| {
            reqsign_core::Error::unexpected(format!("failed to write unsigned payload: {e}"))
        })?;
    } else {
        write!(
            output,
            "{}",
            request.headers[X_AMZ_CONTENT_SHA_256]
                .to_str()
                .map_err(|e| {
                    reqsign_core::Error::unexpected(format!("invalid header value: {e}"))
                })?
        )
        .map_err(|e| {
            reqsign_core::Error::unexpected(format!("failed to write content sha256: {e}"))
        })?;
    }

    Ok(output)
}

/// Add headers shared by AWS SigV4-family algorithms.
pub fn canonicalize_headers(
    request: &mut SigningRequest,
    credential: &Credential,
    expires_in: Option<Duration>,
    now: Timestamp,
) -> Result<()> {
    if request.headers.get(header::HOST).is_none() {
        request.headers.insert(
            header::HOST,
            request.authority.as_str().parse().map_err(|e| {
                reqsign_core::Error::unexpected(format!(
                    "failed to parse authority as header value: {e}"
                ))
            })?,
        );
    }

    if expires_in.is_some() {
        return Ok(());
    }

    if request.headers.get(X_AMZ_DATE).is_none() {
        let value = HeaderValue::try_from(now.format_iso8601()).map_err(|e| {
            reqsign_core::Error::unexpected(format!("failed to create date header: {e}"))
        })?;
        request.headers.insert(X_AMZ_DATE, value);
    }

    if request.headers.get(X_AMZ_CONTENT_SHA_256).is_none() {
        request.headers.insert(
            X_AMZ_CONTENT_SHA_256,
            HeaderValue::from_static("UNSIGNED-PAYLOAD"),
        );
    }

    if let Some(token) = &credential.session_token {
        let mut value = HeaderValue::from_str(token).map_err(|e| {
            reqsign_core::Error::unexpected(format!("failed to create security token header: {e}"))
        })?;
        value.set_sensitive(true);

        let is_s3_express = request.authority.as_str().contains("s3express")
            || request.authority.as_str().contains("--x-s3");
        if is_s3_express {
            request.headers.insert(X_AMZ_S3_SESSION_TOKEN, value);
        } else {
            request.headers.insert(X_AMZ_SECURITY_TOKEN, value);
        }
    }

    Ok(())
}

/// Encode and sort the complete canonical query.
pub fn canonicalize_query(
    request: &SigningRequest,
    authentication_query: &[(String, String)],
) -> Vec<(String, String)> {
    let mut query = request
        .query
        .iter()
        .chain(authentication_query)
        .map(|(key, value)| {
            (
                utf8_percent_encode(key, &AWS_QUERY_ENCODE_SET).to_string(),
                utf8_percent_encode(value, &AWS_QUERY_ENCODE_SET).to_string(),
            )
        })
        .collect::<Vec<_>>();
    query.sort();
    query
}

/// Encode a wire-ready path for use in an AWS canonical request.
pub fn canonical_uri(path: &str) -> Result<String> {
    path.split('/')
        .map(|segment| {
            let decoded = percent_decode_str(segment).decode_utf8().map_err(|e| {
                reqsign_core::Error::request_invalid("failed to decode URI path segment")
                    .with_source(e)
            })?;
            Ok(utf8_percent_encode(&decoded, &AWS_URI_ENCODE_SET).to_string())
        })
        .collect::<Result<Vec<_>>>()
        .map(|segments| segments.join("/"))
}

/// Append encoded query pairs without rewriting existing wire query bytes.
pub fn append_query_pairs(uri: &Uri, pairs: &[(String, String)]) -> Result<Uri> {
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

/// Append an encoded query fragment without rewriting existing wire query bytes.
pub fn append_query_fragment(uri: &Uri, fragment: &str) -> Result<Uri> {
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
