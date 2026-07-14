use std::borrow::Borrow;
use std::convert::{From, TryInto};
use std::fs;
use std::str;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use http::{
    header::{
        HeaderMap, HeaderValue, IntoHeaderName, ACCEPT, CONNECTION, CONTENT_LENGTH, CONTENT_TYPE, TRANSFER_ENCODING,
        USER_AGENT,
    },
    Method,
};
use url::Url;

#[cfg(feature = "charsets")]
use crate::charsets::Charset;
use crate::error::{Error, ErrorKind, Result};
use crate::parsing::Response;
use crate::request::{
    body::{self, Body, BodyKind},
    header_append, header_insert, header_insert_if_missing,
    proxy::ProxySettings,
    BaseSettings, PreparedRequest,
};
use crate::tls::Certificate;

const DEFAULT_USER_AGENT: &str = concat!("attohttpc/", env!("CARGO_PKG_VERSION"));

/// `RequestBuilder` is the main way of building requests.
///
/// You can create a `RequestBuilder` using the `new` or `try_new` method, but the recommended way
/// or use one of the simpler constructors available in the crate root or on the `Session` struct,
/// such as `get`, `post`, etc.
#[derive(Debug)]
pub struct RequestBuilder<B = body::Empty> {
    url: Url,
    method: Method,
    body: B,
    // Headers are always modified by [Self::try_prepare], it's cheaper to keep them
    // separate than to clone all of BaseSettings through [Arc::make_mut].
    headers: HeaderMap,
    base_settings: Arc<BaseSettings>,
}

impl RequestBuilder {
    /// Create a new `RequestBuilder` with the base URL and the given method.
    ///
    /// # Panics
    /// Panics if the base url is invalid or if the method is CONNECT.
    pub fn new<U>(method: Method, base_url: U) -> Self
    where
        U: AsRef<str>,
    {
        Self::try_new(method, base_url).expect("invalid url or method")
    }

    /// Try to create a new `RequestBuilder`.
    ///
    /// If the base URL is invalid, an error is returned.
    /// If the method is CONNECT, an error is also returned. CONNECT is not yet supported.
    pub fn try_new<U>(method: Method, base_url: U) -> Result<Self>
    where
        U: AsRef<str>,
    {
        Self::try_with_settings(method, base_url, Arc::new(BaseSettings::default()))
    }

    pub(crate) fn with_settings<U>(method: Method, base_url: U, base_settings: Arc<BaseSettings>) -> Self
    where
        U: AsRef<str>,
    {
        Self::try_with_settings(method, base_url, base_settings).expect("invalid url or method")
    }

    pub(crate) fn try_with_settings<U>(method: Method, base_url: U, base_settings: Arc<BaseSettings>) -> Result<Self>
    where
        U: AsRef<str>,
    {
        let url = Url::parse(base_url.as_ref()).map_err(|_| ErrorKind::InvalidBaseUrl)?;

        if method == Method::CONNECT {
            return Err(ErrorKind::ConnectNotSupported.into());
        }

        Ok(Self {
            url,
            method,
            body: body::Empty,
            headers: base_settings.headers.clone(),
            base_settings,
        })
    }
}

impl<B> RequestBuilder<B> {
    /// Associate a query string parameter to the given value.
    ///
    /// The same key can be used multiple times.
    pub fn param<K, V>(mut self, key: K, value: V) -> Self
    where
        K: AsRef<str>,
        V: ToString,
    {
        self.url.query_pairs_mut().append_pair(key.as_ref(), &value.to_string());
        self
    }

    /// Associated a list of pairs to query parameters.
    ///
    /// The same key can be used multiple times.
    ///
    /// # Example
    /// ```
    /// attohttpc::get("http://foo.bar").params(&[("p1", "v1"), ("p2", "v2")]);
    /// ```
    pub fn params<P, K, V>(mut self, pairs: P) -> Self
    where
        P: IntoIterator,
        P::Item: Borrow<(K, V)>,
        K: AsRef<str>,
        V: ToString,
    {
        for pair in pairs.into_iter() {
            let (key, value) = pair.borrow();
            self.url.query_pairs_mut().append_pair(key.as_ref(), &value.to_string());
        }
        self
    }

    /// Set the query parameters of this request to be the URL-encoded representation of the given object.
    #[cfg(feature = "form")]
    pub fn query<T: serde::Serialize>(mut self, value: &T) -> Result<Self> {
        value.serialize(serde_urlencoded::Serializer::new(&mut self.url.query_pairs_mut()))?;
        Ok(self)
    }

    /// Enable HTTP basic authentication.
    pub fn basic_auth(self, username: impl std::fmt::Display, password: Option<impl std::fmt::Display>) -> Self {
        let auth = match password {
            Some(password) => format!("{username}:{password}"),
            None => format!("{username}:"),
        };
        self.header(
            http::header::AUTHORIZATION,
            format!(
                "Basic {}",
                base64::engine::general_purpose::STANDARD.encode(auth.as_bytes())
            ),
        )
    }

    /// Enable HTTP bearer authentication.
    pub fn bearer_auth(self, token: impl Into<String>) -> Self {
        self.header(http::header::AUTHORIZATION, format!("Bearer {}", token.into()))
    }

    /// Set the body of this request.
    ///
    /// The [BodyKind enum](crate::body::BodyKind) and [Body trait](crate::body::Body)
    /// determine how to implement custom request body types.
    pub fn body<B1: Body>(self, body: B1) -> RequestBuilder<B1> {
        RequestBuilder {
            url: self.url,
            method: self.method,
            body,
            headers: self.headers,
            base_settings: self.base_settings,
        }
    }

    /// Set the body of this request to be text.
    ///
    /// If the `Content-Type` header is unset, it will be set to `text/plain` and the charset to UTF-8.
    pub fn text<B1: AsRef<str>>(mut self, body: B1) -> RequestBuilder<body::Text<B1>> {
        self.headers
            .entry(http::header::CONTENT_TYPE)
            .or_insert(HeaderValue::from_static("text/plain; charset=utf-8"));
        self.body(body::Text(body))
    }

    /// Set the body of this request to be bytes.
    ///
    /// If the `Content-Type` header is unset, it will be set to `application/octet-stream`.
    pub fn bytes<B1: AsRef<[u8]>>(mut self, body: B1) -> RequestBuilder<body::Bytes<B1>> {
        self.headers
            .entry(http::header::CONTENT_TYPE)
            .or_insert(HeaderValue::from_static("application/octet-stream"));
        self.body(body::Bytes(body))
    }

    /// Set the body of this request using a local file.
    ///
    /// If the `Content-Type` header is unset, it will be set to `application/octet-stream`.
    pub fn file(mut self, body: fs::File) -> RequestBuilder<body::File> {
        self.headers
            .entry(http::header::CONTENT_TYPE)
            .or_insert(HeaderValue::from_static("application/octet-stream"));
        self.body(body::File(body))
    }

    /// Set the body of this request to be the JSON representation of the given object.
    ///
    /// If the `Content-Type` header is unset, it will be set to `application/json` and the charset to UTF-8.
    #[cfg(feature = "json")]
    pub fn json<T: serde::Serialize>(mut self, value: &T) -> Result<RequestBuilder<body::Bytes<Vec<u8>>>> {
        let body = serde_json::to_vec(value)?;
        self.headers
            .entry(http::header::CONTENT_TYPE)
            .or_insert(HeaderValue::from_static("application/json; charset=utf-8"));
        Ok(self.body(body::Bytes(body)))
    }

    /// Set the body of this request to stream out a JSON representation of the given object.
    ///
    /// If the `Content-Type` header is unset, it will be set to `application/json` and the charset to UTF-8.
    #[cfg(feature = "json")]
    pub fn json_streaming<T: serde::Serialize>(mut self, value: T) -> RequestBuilder<body::Json<T>> {
        self.headers
            .entry(http::header::CONTENT_TYPE)
            .or_insert(HeaderValue::from_static("application/json; charset=utf-8"));
        self.body(body::Json(value))
    }

    /// Set the body of this request to be the URL-encoded representation of the given object.
    ///
    /// If the `Content-Type` header is unset, it will be set to `application/x-www-form-urlencoded`.
    #[cfg(feature = "form")]
    pub fn form<T: serde::Serialize>(mut self, value: &T) -> Result<RequestBuilder<body::Bytes<Vec<u8>>>> {
        let body = serde_urlencoded::to_string(value)?.into_bytes();
        self.headers
            .entry(http::header::CONTENT_TYPE)
            .or_insert(HeaderValue::from_static("application/x-www-form-urlencoded"));
        Ok(self.body(body::Bytes(body)))
    }

    /// Get a mutable reference to headers.
    pub fn headers(&self) -> &HeaderMap {
        &self.headers
    }

    /// Get a mutable reference to headers.
    pub fn headers_mut(&mut self) -> &mut HeaderMap {
        &mut self.headers
    }

    //
    // Settings
    //

    /// Modify a header for this request.
    ///
    /// If the header is already present, the value will be replaced. If you wish to append a new header,
    /// use `header_append`.
    ///
    /// # Panics
    /// This method will panic if the value is invalid.
    pub fn header<H, V>(self, header: H, value: V) -> Self
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        self.try_header(header, value).expect("invalid header value")
    }

    /// Append a new header for this request.
    ///
    /// The new header is always appended to the request, even if the header already exists.
    ///
    /// # Panics
    /// This method will panic if the value is invalid.
    pub fn header_append<H, V>(self, header: H, value: V) -> Self
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        self.try_header_append(header, value).expect("invalid header value")
    }

    /// Modify a header for this request.
    ///
    /// If the header is already present, the value will be replaced. If you wish to append a new header,
    /// use `header_append`.
    pub fn try_header<H, V>(mut self, header: H, value: V) -> Result<Self>
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        header_insert(&mut self.headers, header, value)?;
        Ok(self)
    }

    /// Append a new header to this request.
    ///
    /// The new header is always appended to the request, even if the header already exists.
    pub fn try_header_append<H, V>(mut self, header: H, value: V) -> Result<Self>
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        header_append(&mut self.headers, header, value)?;
        Ok(self)
    }

    /// Set the maximum number of headers accepted in responses to this request.
    ///
    /// The default is 100.
    pub fn max_headers(mut self, max_headers: usize) -> Self {
        self.base_settings.set_max_headers(max_headers);
        self
    }

    /// Set the maximum number of redirections this request can perform.
    ///
    /// The default is 5.
    pub fn max_redirections(mut self, max_redirections: u32) -> Self {
        self.base_settings.set_max_redirections(max_redirections);
        self
    }

    /// Sets if this request should follow redirects, 3xx codes.
    ///
    /// This value defaults to true.
    pub fn follow_redirects(mut self, follow_redirects: bool) -> Self {
        self.base_settings.set_follow_redirects(follow_redirects);
        self
    }

    /// Sets a connect timeout for this request.
    ///
    /// The default is 30 seconds.
    pub fn connect_timeout(mut self, connect_timeout: Duration) -> Self {
        self.base_settings.set_connect_timeout(connect_timeout);
        self
    }

    /// Sets a read timeout for this request.
    ///
    /// The default is 30 seconds.
    pub fn read_timeout(mut self, read_timeout: Duration) -> Self {
        self.base_settings.set_read_tmeout(read_timeout);
        self
    }

    /// Sets a timeout for the whole request.
    ///
    /// Applies after a TCP connection is established. Defaults to no timeout.
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.base_settings.set_timeout(Some(timeout));
        self
    }

    /// Sets the proxy settigns for this request.
    ///
    /// If left untouched, the defaults are to use system proxy settings found in environment variables.
    pub fn proxy_settings(mut self, proxy_settings: ProxySettings) -> Self {
        self.base_settings.set_proxy_settings(proxy_settings);
        self
    }

    /// Set the default charset to use while parsing the response of this request.
    ///
    /// If the response does not say which charset it uses, this charset will be used to decode the request.
    /// This value defaults to `None`, in which case ISO-8859-1 is used.
    #[cfg(feature = "charsets")]
    pub fn default_charset(mut self, default_charset: Option<Charset>) -> Self {
        self.base_settings.set_default_charset(default_charset);
        self
    }

    /// Sets if this request will announce that it accepts compression.
    ///
    /// This value defaults to true. Note that this only lets the browser know that this request supports
    /// compression, the server might choose not to compress the content.
    #[cfg(feature = "flate2")]
    pub fn allow_compression(mut self, allow_compression: bool) -> Self {
        self.base_settings.set_allow_compression(allow_compression);
        self
    }

    /// Sets if this request will accept invalid TLS certificates.
    ///
    /// Accepting invalid certificates implies that invalid hostnames are accepted
    /// as well.
    ///
    /// The default value is `false`.
    ///
    /// # Danger
    /// Use this setting with care. This will accept **any** TLS certificate valid or not.
    /// If you are using self signed certificates, it is much safer to add their root CA
    /// to the list of trusted root CAs by your system.
    pub fn danger_accept_invalid_certs(mut self, accept_invalid_certs: bool) -> Self {
        self.base_settings.set_accept_invalid_certs(accept_invalid_certs);
        self
    }

    /// Sets if this request will accept an invalid hostname in a TLS certificate.
    ///
    /// The default value is `false`.
    ///
    /// # Danger
    /// Use this setting with care. This will accept TLS certificates that do not match
    /// the hostname.
    pub fn danger_accept_invalid_hostnames(mut self, accept_invalid_hostnames: bool) -> Self {
        self.base_settings
            .set_accept_invalid_hostnames(accept_invalid_hostnames);
        self
    }

    /// Adds a root certificate that will be trusted.
    pub fn add_root_certificate(mut self, cert: Certificate) -> Self {
        self.base_settings.add_root_certificate(cert);
        self
    }
}

impl<B: Body> RequestBuilder<B> {
    /// Create a `PreparedRequest` from this `RequestBuilder`.
    ///
    /// # Panics
    /// Will panic if an error occurs trying to prepare the request. It shouldn't happen.
    pub fn prepare(self) -> PreparedRequest<B> {
        self.try_prepare().expect("failed to prepare request")
    }

    /// Create a `PreparedRequest` from this `RequestBuilder`.
    pub fn try_prepare(self) -> Result<PreparedRequest<B>> {
        let mut prepped = PreparedRequest {
            url: self.url,
            method: self.method,
            body: self.body,
            headers: self.headers,
            base_settings: self.base_settings,
        };
        prepped.set_compression()?;
        let headers = &mut prepped.headers;

        header_insert(headers, CONNECTION, "close")?;
        match prepped.body.kind()? {
            BodyKind::Empty => (),
            BodyKind::KnownLength(len) => {
                header_insert(headers, CONTENT_LENGTH, len)?;
            }
            BodyKind::Chunked => {
                header_insert(headers, TRANSFER_ENCODING, "chunked")?;
            }
        }

        if let Some(typ) = prepped.body.content_type()? {
            header_insert(headers, CONTENT_TYPE, typ)?;
        }

        header_insert_if_missing(headers, ACCEPT, "*/*")?;
        header_insert_if_missing(headers, USER_AGENT, DEFAULT_USER_AGENT)?;

        Ok(prepped)
    }

    /// Send this request directly.
    pub fn send(self) -> Result<Response> {
        self.try_prepare()?.send()
    }
}

impl<B> RequestBuilder<B> {
    /// Inspect the properties of this request
    pub fn inspect(&mut self) -> RequestInspector<'_, B> {
        RequestInspector(self)
    }
}

/// Allows to inspect the properties of a request before preparing it.
#[derive(Debug)]
pub struct RequestInspector<'a, B>(&'a mut RequestBuilder<B>);

impl<B> RequestInspector<'_, B> {
    /// Access the current URL
    pub fn url(&self) -> &Url {
        &self.0.url
    }

    /// Access the current method
    pub fn method(&self) -> &Method {
        &self.0.method
    }

    /// Access the current body
    pub fn body(&mut self) -> &mut B {
        &mut self.0.body
    }

    /// Acess the current headers
    pub fn headers(&self) -> &HeaderMap {
        &self.0.headers
    }
}

#[test]
#[cfg(feature = "tls-native")]
fn test_accept_invalid_certs_disabled_by_default() {
    let builder = RequestBuilder::new(Method::GET, "https://localhost:7900");
    assert!(!builder.base_settings.accept_invalid_certs);
    assert!(!builder.base_settings.accept_invalid_hostnames);

    let prepped = builder.prepare();
    assert!(!prepped.base_settings.accept_invalid_certs);
    assert!(!prepped.base_settings.accept_invalid_hostnames);
}

#[cfg(test)]
mod tests {
    use super::*;
    use http::header::HeaderMap;

    #[test]
    fn test_header_insert_exists() {
        let mut headers = HeaderMap::new();
        headers.insert(USER_AGENT, HeaderValue::from_static("hello"));
        header_insert(&mut headers, USER_AGENT, "world").unwrap();
        assert_eq!(headers[USER_AGENT], "world");
    }

    #[test]
    fn test_header_insert_missing() {
        let mut headers = HeaderMap::new();
        header_insert(&mut headers, USER_AGENT, "world").unwrap();
        assert_eq!(headers[USER_AGENT], "world");
    }

    #[test]
    fn test_header_insert_if_missing_exists() {
        let mut headers = HeaderMap::new();
        headers.insert(USER_AGENT, HeaderValue::from_static("hello"));
        header_insert_if_missing(&mut headers, USER_AGENT, "world").unwrap();
        assert_eq!(headers[USER_AGENT], "hello");
    }

    #[test]
    fn test_header_insert_if_missing_missing() {
        let mut headers = HeaderMap::new();
        header_insert_if_missing(&mut headers, USER_AGENT, "world").unwrap();
        assert_eq!(headers[USER_AGENT], "world");
    }

    #[test]
    fn test_header_append() {
        let mut headers = HeaderMap::new();
        header_append(&mut headers, USER_AGENT, "hello").unwrap();
        header_append(&mut headers, USER_AGENT, "world").unwrap();

        let vals: Vec<_> = headers.get_all(USER_AGENT).into_iter().collect();
        assert_eq!(vals.len(), 2);
        for val in vals {
            assert!(val == "hello" || val == "world");
        }
    }

    #[test]
    fn test_request_builder_param() {
        let prepped = RequestBuilder::new(Method::GET, "http://localhost:1337/foo")
            .param("qux", "baz")
            .prepare();

        assert_eq!(prepped.url().as_str(), "http://localhost:1337/foo?qux=baz");
    }

    #[test]
    fn test_request_builder_params() {
        let prepped = RequestBuilder::new(Method::GET, "http://localhost:1337/foo")
            .params(&[("qux", "baz"), ("foo", "bar")])
            .prepare();

        assert_eq!(prepped.url().as_str(), "http://localhost:1337/foo?qux=baz&foo=bar");
    }

    #[test]
    fn test_request_builder_header_insert() {
        let prepped = RequestBuilder::new(Method::GET, "http://localhost:1337/foo")
            .header("hello", "world")
            .prepare();

        assert_eq!(prepped.headers()["hello"], "world");
    }

    #[test]
    fn test_request_builder_header_append() {
        let prepped = RequestBuilder::new(Method::GET, "http://localhost:1337/foo")
            .header_append("hello", "world")
            .header_append("hello", "!!!")
            .prepare();

        let vals: Vec<_> = prepped.headers().get_all("hello").into_iter().collect();
        assert_eq!(vals.len(), 2);
        for val in vals {
            assert!(val == "world" || val == "!!!");
        }
    }

    #[cfg(feature = "flate2")]
    fn assert_request_content(
        builder: RequestBuilder,
        status_line: &str,
        mut header_lines: Vec<&str>,
        body_lines: &[&str],
    ) {
        let mut buf = Vec::new();

        let mut prepped = builder.prepare();
        prepped
            .write_request(&mut buf, &prepped.url().clone(), None)
            .expect("error writing request");

        let text = std::str::from_utf8(&buf).expect("cannot decode request as utf-8");
        let lines: Vec<_> = text.lines().collect();

        let req_status_line = lines[0];

        let empty_line_pos = lines
            .iter()
            .position(|l| l.is_empty())
            .expect("no empty line in request");
        let mut req_header_lines = lines[1..empty_line_pos].to_vec();

        let req_body_lines = &lines[empty_line_pos + 1..];

        req_header_lines.sort_unstable();
        header_lines.sort_unstable();

        assert_eq!(req_status_line, status_line);
        assert_eq!(req_header_lines, header_lines);
        assert_eq!(req_body_lines, body_lines);
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_request_builder_write_request_no_query() {
        assert_request_content(
            RequestBuilder::new(Method::GET, "http://localhost:1337/foo"),
            "GET /foo HTTP/1.1",
            vec![
                "connection: close",
                "accept-encoding: gzip, deflate",
                "accept: */*",
                &format!("user-agent: {DEFAULT_USER_AGENT}"),
            ],
            &[],
        );
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_request_builder_write_request_with_query() {
        assert_request_content(
            RequestBuilder::new(Method::GET, "http://localhost:1337/foo").param("hello", "world"),
            "GET /foo?hello=world HTTP/1.1",
            vec![
                "connection: close",
                "accept-encoding: gzip, deflate",
                "accept: */*",
                &format!("user-agent: {DEFAULT_USER_AGENT}"),
            ],
            &[],
        );
    }

    #[test]
    fn test_prepare_default_headers() {
        let prepped = RequestBuilder::new(Method::GET, "http://localhost:1337/foo/qux/baz").prepare();
        assert_eq!(prepped.headers()[ACCEPT], "*/*");
        assert_eq!(prepped.headers()[USER_AGENT], DEFAULT_USER_AGENT);
    }

    #[test]
    fn test_prepare_custom_headers() {
        let prepped = RequestBuilder::new(Method::GET, "http://localhost:1337/foo/qux/baz")
            .header(USER_AGENT, "foobaz")
            .header("Accept", "nothing")
            .prepare();
        assert_eq!(prepped.headers()[ACCEPT], "nothing");
        assert_eq!(prepped.headers()[USER_AGENT], "foobaz");
    }
}
