use std::borrow::Cow;
use std::mem;
use std::time::Duration;

use crate::{Error, Result};
use http::header::HeaderName;
use http::uri::Authority;
use http::uri::PathAndQuery;
use http::uri::Scheme;
use http::HeaderMap;
use http::HeaderValue;
use http::Method;
use http::Uri;
use std::str::FromStr;

/// Signing context for request.
#[derive(Debug)]
pub struct SigningRequest {
    /// HTTP method.
    pub method: Method,
    /// HTTP scheme.
    pub scheme: Scheme,
    /// HTTP authority.
    pub authority: Authority,
    /// HTTP path.
    pub path: String,
    /// HTTP query parameters.
    pub query: Vec<(String, String)>,
    /// HTTP headers.
    pub headers: HeaderMap,
}

impl SigningRequest {
    /// Build a signing context from http::request::Parts.
    pub fn build(parts: &mut http::request::Parts) -> Result<Self> {
        let uri = mem::take(&mut parts.uri).into_parts();
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
            query: paq
                .query()
                .map(|v| {
                    form_urlencoded::parse(v.as_bytes())
                        .map(|(k, v)| (k.into_owned(), v.into_owned()))
                        .collect()
                })
                .unwrap_or_default(),

            // Take the headers out of the request to avoid copy.
            // We will return it back when apply the context.
            headers: mem::take(&mut parts.headers),
        })
    }

    /// Apply the signing context back to http::request::Parts.
    pub fn apply(mut self, parts: &mut http::request::Parts) -> Result<()> {
        let query_size = self.query_size();

        // Return headers back.
        mem::swap(&mut parts.headers, &mut self.headers);
        parts.method = self.method;
        parts.uri = {
            let mut uri_parts = mem::take(&mut parts.uri).into_parts();
            // Return scheme bakc.
            uri_parts.scheme = Some(self.scheme);
            // Return authority back.
            uri_parts.authority = Some(self.authority);
            // Build path and query.
            uri_parts.path_and_query =
                {
                    let paq = if query_size == 0 {
                        self.path
                    } else {
                        let mut s = self.path;
                        s.reserve(query_size + 1);

                        s.push('?');
                        for (i, (k, v)) in self.query.iter().enumerate() {
                            if i > 0 {
                                s.push('&');
                            }

                            s.push_str(k);
                            if !v.is_empty() {
                                s.push('=');
                                s.push_str(v);
                            }
                        }

                        s
                    };

                    Some(PathAndQuery::from_str(&paq).map_err(|e| {
                        Error::request_invalid("invalid path and query").with_source(e)
                    })?)
                };
            Uri::from_parts(uri_parts)
                .map_err(|e| Error::request_invalid("failed to build URI").with_source(e))?
        };

        Ok(())
    }

    /// Get the path percent decoded.
    pub fn path_percent_decoded(&self) -> Cow<'_, str> {
        percent_encoding::percent_decode_str(&self.path).decode_utf8_lossy()
    }

    /// Get query size.
    #[inline]
    pub fn query_size(&self) -> usize {
        self.query
            .iter()
            .map(|(k, v)| k.len() + v.len())
            .sum::<usize>()
    }

    /// Push a new query pair into query list.
    #[inline]
    pub fn query_push(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.query.push((key.into(), value.into()));
    }

    /// Push a query string into query list.
    #[inline]
    pub fn query_append(&mut self, query: &str) {
        self.query.push((query.to_string(), "".to_string()));
    }

    /// Get query value by filter.
    pub fn query_to_vec_with_filter(&self, filter: impl Fn(&str) -> bool) -> Vec<(String, String)> {
        self.query
            .iter()
            // Filter all queries
            .filter(|(k, _)| filter(k))
            // Clone all queries
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// Convert sorted query to string.
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

    /// Convert sorted query to percent decoded string.
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

    /// Normalize header value.
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

/// SigningMethod is the method that used in signing.
#[derive(Copy, Clone, PartialEq, Eq)]
pub enum SigningMethod {
    /// Signing with header.
    Header,
    /// Signing with query.
    Query(Duration),
}
