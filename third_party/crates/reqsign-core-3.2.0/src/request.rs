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

use std::borrow::Cow;
use std::time::Duration;

use crate::{Error, Result};
use http::HeaderMap;
use http::HeaderValue;
use http::Method;
use http::header::HeaderName;
use http::uri::Authority;
use http::uri::PathAndQuery;
use http::uri::Scheme;

fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            (
                percent_encoding::percent_decode_str(key)
                    .decode_utf8_lossy()
                    .into_owned(),
                percent_encoding::percent_decode_str(value)
                    .decode_utf8_lossy()
                    .into_owned(),
            )
        })
        .collect()
}

/// A service-local canonicalization view and signed-header staging area.
///
/// The method and URI-derived fields are read-only working values. They do not own
/// the wire URI and must not be mutated to express signing output. The URI supplied
/// to [`Self::build`] is already the final caller-provided representation; services
/// derive canonical values locally and construct query authentication from the
/// original URI.
#[derive(Debug)]
pub struct SigningRequest {
    /// Read-only HTTP method used for canonicalization.
    pub method: Method,
    /// Read-only HTTP scheme used for canonicalization.
    pub scheme: Scheme,
    /// Read-only HTTP authority used for canonicalization.
    pub authority: Authority,
    /// Read-only, percent-encoded wire path.
    ///
    /// Services may derive a canonical path from this value, but must not decode it
    /// and write the result back to the request URI.
    pub path: String,
    /// HTTP query parameters decoded once from the wire query for canonicalization.
    ///
    /// Percent escapes are decoded once, literal `+` remains `+`, and duplicate order
    /// is retained. This working view does not own or rebuild the wire URI.
    pub query: Vec<(String, String)>,
    /// Staged HTTP headers committed by [`Self::apply`].
    pub headers: HeaderMap,
}

impl SigningRequest {
    /// Build a read-only request-target working view from http::request::Parts.
    ///
    /// The URI path and query must already be percent-encoded for transport, and the
    /// URI must contain an authority. This method clones the URI-derived values and
    /// headers; the input request head remains unchanged on success or error.
    pub fn build(parts: &mut http::request::Parts) -> Result<Self> {
        let uri = parts.uri.clone().into_parts();
        let paq = uri
            .path_and_query
            .unwrap_or_else(|| PathAndQuery::from_static("/"));

        Ok(SigningRequest {
            method: parts.method.clone(),
            scheme: uri.scheme.unwrap_or(Scheme::HTTP),
            authority: uri.authority.ok_or_else(|| {
                Error::request_invalid("request without authority is invalid for signing")
            })?,
            path: paq.path().to_string(),
            query: paq.query().map(parse_query).unwrap_or_default(),
            headers: parts.headers.clone(),
        })
    }

    /// Commit staged headers back to http::request::Parts.
    ///
    /// In debug builds, this method verifies that the method, scheme, authority, path,
    /// and decoded query working view still match `parts`. A mismatch returns an error
    /// without changing `parts`. Release builds omit this implementation check.
    ///
    /// On success, only headers are committed. This method never writes the method or
    /// URI. Query signers must construct their final URI from the original wire URI and
    /// assign it separately after all fallible signing work succeeds.
    pub fn apply(self, parts: &mut http::request::Parts) -> Result<()> {
        #[cfg(debug_assertions)]
        self.validate_request_view(parts)?;

        parts.headers = self.headers;

        Ok(())
    }

    #[cfg(debug_assertions)]
    fn validate_request_view(&self, parts: &http::request::Parts) -> Result<()> {
        let uri = parts.uri.clone().into_parts();
        let paq = uri
            .path_and_query
            .unwrap_or_else(|| PathAndQuery::from_static("/"));
        let scheme = uri.scheme.unwrap_or(Scheme::HTTP);
        let authority = uri.authority.ok_or_else(|| {
            Error::request_invalid("request without authority is invalid for signing")
        })?;
        let query = paq.query().map(parse_query).unwrap_or_default();

        if self.method != parts.method
            || self.scheme != scheme
            || self.authority != authority
            || self.path != paq.path()
            || self.query != query
        {
            return Err(Error::request_invalid(
                "signing request method or URI working view was modified",
            ));
        }

        Ok(())
    }

    /// Return the entire working path percent-decoded.
    ///
    /// This is a canonicalization helper, not a wire URI builder. Decoding the entire
    /// path turns encoded slashes such as `%2F` into `/`; services where encoded slash
    /// is data must decode path segments separately.
    pub fn path_percent_decoded(&self) -> Cow<'_, str> {
        percent_encoding::percent_decode_str(&self.path).decode_utf8_lossy()
    }

    /// Return the combined key and value length of the decoded working query.
    ///
    /// This is not the byte length of the wire query.
    #[inline]
    pub fn query_size(&self) -> usize {
        self.query
            .iter()
            .map(|(k, v)| k.len() + v.len())
            .sum::<usize>()
    }

    /// Push a new query pair into the working query view.
    ///
    /// This does not modify the wire URI. [`Self::apply`] rejects a modified
    /// request-target view in debug builds and ignores it in release builds. Query
    /// signers must construct their final URI from the original wire URI instead.
    #[inline]
    pub fn query_push(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.query.push((key.into(), value.into()));
    }

    /// Push a query string into the working query view.
    ///
    /// This does not modify the wire URI; see [`Self::query_push`].
    #[inline]
    pub fn query_append(&mut self, query: &str) {
        self.query.push((query.to_string(), "".to_string()));
    }

    /// Clone working query pairs whose keys match a canonicalization filter.
    pub fn query_to_vec_with_filter(&self, filter: impl Fn(&str) -> bool) -> Vec<(String, String)> {
        self.query
            .iter()
            // Filter all queries
            .filter(|(k, _)| filter(k))
            // Clone all queries
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// Convert sorted query pairs to a canonical string.
    ///
    /// This helper does not produce or modify a wire URI.
    ///
    /// ```shell
    /// [(a, b), (c, d)] => "a:b\nc:d"
    /// ```
    pub fn query_to_string(mut query: Vec<(String, String)>, sep: &str, join: &str) -> String {
        let mut s = String::with_capacity(16);

        // Sort via header name.
        query.sort();

        for (idx, (k, v)) in query.into_iter().enumerate() {
            if idx != 0 {
                s.push_str(join);
            }

            s.push_str(&k);
            if !v.is_empty() {
                s.push_str(sep);
                s.push_str(&v);
            }
        }

        s
    }

    /// Convert sorted query pairs to a string after percent-decoding each value.
    ///
    /// Values from [`Self::query`] have already been decoded once. Passing them to
    /// this helper performs an additional decode and is only correct when a service
    /// protocol explicitly requires it. This helper does not produce a wire URI.
    ///
    /// ```shell
    /// [(a, b), (c, d)] => "a:b\nc:d"
    /// ```
    pub fn query_to_percent_decoded_string(
        mut query: Vec<(String, String)>,
        sep: &str,
        join: &str,
    ) -> String {
        let mut s = String::with_capacity(16);

        // Sort via header name.
        query.sort();

        for (idx, (k, v)) in query.into_iter().enumerate() {
            if idx != 0 {
                s.push_str(join);
            }

            s.push_str(&k);
            if !v.is_empty() {
                s.push_str(sep);
                s.push_str(&percent_encoding::percent_decode_str(&v).decode_utf8_lossy());
            }
        }

        s
    }

    /// Get header value by name.
    ///
    /// Returns empty string if header not found.
    #[inline]
    pub fn header_get_or_default(&self, key: &HeaderName) -> Result<&str> {
        match self.headers.get(key) {
            Some(v) => v
                .to_str()
                .map_err(|e| Error::request_invalid("invalid header value").with_source(e)),
            None => Ok(""),
        }
    }

    /// Normalize a header value for canonicalization.
    ///
    /// Normalize a clone when the protocol does not require changing the wire header;
    /// mutating a value inside [`Self::headers`] changes the header committed by
    /// [`Self::apply`].
    pub fn header_value_normalize(v: &mut HeaderValue) {
        let bs = v.as_bytes();

        let starting_index = bs.iter().position(|b| *b != b' ').unwrap_or(0);
        let ending_offset = bs.iter().rev().position(|b| *b != b' ').unwrap_or(0);
        let ending_index = bs.len() - ending_offset;

        // This can't fail because we started with a valid HeaderValue and then only trimmed spaces
        *v = HeaderValue::from_bytes(&bs[starting_index..ending_index])
            .expect("invalid header value")
    }

    /// Get header names as sorted vector.
    pub fn header_name_to_vec_sorted(&self) -> Vec<&str> {
        let mut h = self
            .headers
            .keys()
            .map(|k| k.as_str())
            .collect::<Vec<&str>>();
        h.sort_unstable();

        h
    }

    /// Get header names with given prefix.
    pub fn header_to_vec_with_prefix(&self, prefix: &str) -> Vec<(String, String)> {
        self.headers
            .iter()
            // Filter all header that starts with prefix
            .filter(|(k, _)| k.as_str().starts_with(prefix))
            // Convert all header name to lowercase
            .map(|(k, v)| {
                (
                    k.as_str().to_lowercase(),
                    v.to_str().expect("must be valid header").to_string(),
                )
            })
            .collect()
    }

    /// Convert sorted headers to string.
    ///
    /// ```shell
    /// [(a, b), (c, d)] => "a:b\nc:d"
    /// ```
    pub fn header_to_string(mut headers: Vec<(String, String)>, sep: &str, join: &str) -> String {
        let mut s = String::with_capacity(16);

        // Sort via header name.
        headers.sort();

        for (idx, (k, v)) in headers.into_iter().enumerate() {
            if idx != 0 {
                s.push_str(join);
            }

            s.push_str(&k);
            s.push_str(sep);
            s.push_str(&v);
        }

        s
    }
}

/// A service-selected authentication placement.
///
/// This type does not define a universal mapping from `expires_in` to query
/// authentication. Services and credential types decide which placement applies.
#[derive(Copy, Clone, PartialEq, Eq)]
pub enum SigningMethod {
    /// Signing with header.
    Header,
    /// Signing with query.
    Query(Duration),
}

#[cfg(test)]
mod tests {
    use super::*;
    use http::{HeaderValue, Request};

    const RAW_QUERY: &str = "slash=%2F&hash=%23&amp=%26&equals=%3D&space=%20&encoded-plus=%2B&literal-plus=+&double=%252F&dup=first&dup=second&=empty-key&empty=&flag&flag=&";

    fn request_parts() -> http::request::Parts {
        Request::get(format!("https://example.com/object%2Fname?{RAW_QUERY}"))
            .header("x-original", " value ")
            .body(())
            .expect("request must build")
            .into_parts()
            .0
    }

    #[test]
    fn build_is_read_only_and_parses_wire_query_once() {
        let mut parts = request_parts();
        let original = parts.clone();

        let signing = SigningRequest::build(&mut parts).expect("signing request must build");

        assert_eq!(parts.method, original.method);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.version, original.version);
        assert_eq!(parts.headers, original.headers);
        assert_eq!(signing.path, "/object%2Fname");
        assert_eq!(
            signing.query,
            vec![
                ("slash".to_string(), "/".to_string()),
                ("hash".to_string(), "#".to_string()),
                ("amp".to_string(), "&".to_string()),
                ("equals".to_string(), "=".to_string()),
                ("space".to_string(), " ".to_string()),
                ("encoded-plus".to_string(), "+".to_string()),
                ("literal-plus".to_string(), "+".to_string()),
                ("double".to_string(), "%2F".to_string()),
                ("dup".to_string(), "first".to_string()),
                ("dup".to_string(), "second".to_string()),
                (String::new(), "empty-key".to_string()),
                ("empty".to_string(), String::new()),
                ("flag".to_string(), String::new()),
                ("flag".to_string(), String::new()),
            ]
        );
    }

    #[test]
    fn build_error_leaves_request_unchanged() {
        let mut parts = Request::get("/relative")
            .header("x-original", "value")
            .body(())
            .expect("request must build")
            .into_parts()
            .0;
        let original = parts.clone();

        assert!(SigningRequest::build(&mut parts).is_err());
        assert_eq!(parts.method, original.method);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.version, original.version);
        assert_eq!(parts.headers, original.headers);
    }

    #[test]
    fn apply_commits_only_headers() {
        let mut parts = request_parts();
        let original = parts.clone();
        let mut signing =
            SigningRequest::build(&mut parts).expect("signing request must build successfully");
        signing
            .headers
            .insert("authorization", HeaderValue::from_static("signed"));

        signing.apply(&mut parts).expect("apply must succeed");

        assert_eq!(parts.method, original.method);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.version, original.version);
        assert_eq!(
            parts.headers.get("authorization"),
            Some(&HeaderValue::from_static("signed"))
        );
    }

    #[cfg(debug_assertions)]
    #[test]
    fn apply_rejects_modified_request_view_atomically() {
        type ViewMutation = Box<dyn Fn(&mut SigningRequest)>;

        let mutations: Vec<ViewMutation> = vec![
            Box::new(|signing| signing.method = Method::POST),
            Box::new(|signing| signing.scheme = Scheme::HTTP),
            Box::new(|signing| signing.authority = "other.example.com".parse().unwrap()),
            Box::new(|signing| signing.path.push_str("/changed")),
            Box::new(|signing| signing.query_push("auth", "value")),
        ];

        for mutate in mutations {
            let mut parts = request_parts();
            let original = parts.clone();
            let mut signing =
                SigningRequest::build(&mut parts).expect("signing request must build successfully");
            signing
                .headers
                .insert("authorization", HeaderValue::from_static("signed"));
            mutate(&mut signing);

            assert!(signing.apply(&mut parts).is_err());
            assert_eq!(parts.method, original.method);
            assert_eq!(parts.uri, original.uri);
            assert_eq!(parts.version, original.version);
            assert_eq!(parts.headers, original.headers);
        }
    }

    #[cfg(not(debug_assertions))]
    #[test]
    fn apply_omits_request_view_validation_in_release() {
        let mut parts = request_parts();
        let original = parts.clone();
        let mut signing =
            SigningRequest::build(&mut parts).expect("signing request must build successfully");
        signing.method = Method::POST;
        signing.scheme = Scheme::HTTP;
        signing.authority = "other.example.com".parse().unwrap();
        signing.path.push_str("/changed");
        signing.query_push("auth", "value");
        signing
            .headers
            .insert("authorization", HeaderValue::from_static("signed"));

        signing.apply(&mut parts).expect("apply must succeed");

        assert_eq!(parts.method, original.method);
        assert_eq!(parts.uri, original.uri);
        assert_eq!(parts.version, original.version);
        assert_eq!(
            parts.headers.get("authorization"),
            Some(&HeaderValue::from_static("signed"))
        );
    }
}
