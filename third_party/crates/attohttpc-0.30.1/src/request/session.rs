use std::convert::TryInto;
use std::sync::Arc;
use std::time::Duration;

use http::header::{HeaderValue, IntoHeaderName};
use http::Method;

#[cfg(feature = "charsets")]
use crate::charsets::Charset;
use crate::error::{Error, Result};
use crate::request::proxy::ProxySettings;
use crate::request::{BaseSettings, RequestBuilder};
use crate::tls::Certificate;

/// `Session` is a type that can carry settings over multiple requests. The settings applied to the
/// `Session` are applied to every request created from this `Session`.
///
/// `Session` can be cloned cheaply and sent to other threads as it uses [std::sync::Arc] internally.
#[derive(Clone, Debug, Default)]
pub struct Session {
    base_settings: Arc<BaseSettings>,
}

impl Session {
    /// Create a new `Session` with default settings.
    pub fn new() -> Session {
        Session {
            base_settings: Arc::new(BaseSettings::default()),
        }
    }

    /// Create a new `RequestBuilder` with the GET method and this Session's settings applied on it.
    pub fn get<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::GET, base_url, self.base_settings.clone())
    }

    /// Create a new `RequestBuilder` with the POST method and this Session's settings applied on it.
    pub fn post<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::POST, base_url, self.base_settings.clone())
    }

    /// Create a new `RequestBuilder` with the PUT method and this Session's settings applied on it.
    pub fn put<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::PUT, base_url, self.base_settings.clone())
    }

    /// Create a new `RequestBuilder` with the DELETE method and this Session's settings applied on it.
    pub fn delete<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::DELETE, base_url, self.base_settings.clone())
    }

    /// Create a new `RequestBuilder` with the HEAD method and this Session's settings applied on it.
    pub fn head<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::HEAD, base_url, self.base_settings.clone())
    }

    /// Create a new `RequestBuilder` with the OPTIONS method and this Session's settings applied on it.
    pub fn options<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::OPTIONS, base_url, self.base_settings.clone())
    }

    /// Create a new `RequestBuilder` with the PATCH method and this Session's settings applied on it.
    pub fn patch<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::PATCH, base_url, self.base_settings.clone())
    }

    /// Create a new `RequestBuilder` with the TRACE method and this Session's settings applied on it.
    pub fn trace<U>(&self, base_url: U) -> RequestBuilder
    where
        U: AsRef<str>,
    {
        RequestBuilder::with_settings(Method::TRACE, base_url, self.base_settings.clone())
    }

    //
    // Settings
    //

    /// Modify a header for this `Session`.
    ///
    /// If the header is already present, the value will be replaced. If you wish to append a new header,
    /// use `header_append`.
    ///
    /// # Panics
    /// This method will panic if the value is invalid.
    pub fn header<H, V>(&mut self, header: H, value: V)
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        self.try_header(header, value).expect("invalid header value");
    }

    /// Append a new header for this `Session`.
    ///
    /// The new header is always appended to the headers, even if the header already exists.
    ///
    /// # Panics
    /// This method will panic if the value is invalid.
    pub fn header_append<H, V>(&mut self, header: H, value: V)
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        self.try_header_append(header, value).expect("invalid header value");
    }

    /// Modify a header for this `Session`.
    ///
    /// If the header is already present, the value will be replaced. If you wish to append a new header,
    /// use `header_append`.
    pub fn try_header<H, V>(&mut self, header: H, value: V) -> Result<()>
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        self.base_settings.try_header(header, value)
    }

    /// Append a new header to this `Session`.
    ///
    /// The new header is always appended to the headers, even if the header already exists.
    pub fn try_header_append<H, V>(&mut self, header: H, value: V) -> Result<()>
    where
        H: IntoHeaderName,
        V: TryInto<HeaderValue>,
        Error: From<V::Error>,
    {
        self.base_settings.try_header_append(header, value)
    }

    /// Set the maximum number of headers accepted in responses to requests created from this `Session`.
    ///
    /// The default is 100.
    pub fn max_headers(&mut self, max_headers: usize) {
        self.base_settings.set_max_headers(max_headers);
    }

    /// Set the maximum number of redirections the requests created from this `Session` can perform.
    ///
    /// The default is 5.
    pub fn max_redirections(&mut self, max_redirections: u32) {
        self.base_settings.set_max_redirections(max_redirections);
    }

    /// Sets if requests created from this `Session` should follow redirects, 3xx codes.
    ///
    /// This value defaults to true.
    pub fn follow_redirects(&mut self, follow_redirects: bool) {
        self.base_settings.set_follow_redirects(follow_redirects);
    }

    /// Sets a connect timeout for requests created from this `Session`.
    ///
    /// The default is 30 seconds.
    pub fn connect_timeout(&mut self, connect_timeout: Duration) {
        self.base_settings.set_connect_timeout(connect_timeout);
    }

    /// Sets a read timeout for requests created from this `Session`.
    ///
    /// The default is 30 seconds.
    pub fn read_timeout(&mut self, read_timeout: Duration) {
        self.base_settings.set_read_tmeout(read_timeout);
    }

    /// Sets a timeout for the maximum duration of requests created from this `Session`.
    ///
    /// Applies after a TCP connection is established. Defaults to no timeout.
    pub fn timeout(&mut self, timeout: Duration) {
        self.base_settings.set_timeout(Some(timeout));
    }

    /// Sets the proxy settigns for requests created from this `Session`.
    ///
    /// If left untouched, the defaults are to use system proxy settings found in environment variables.
    pub fn proxy_settings(&mut self, proxy_settings: ProxySettings) {
        self.base_settings.set_proxy_settings(proxy_settings);
    }

    /// Set the default charset to use while parsing the responses of requests created from this `Session`.
    ///
    /// If the response does not say which charset it uses, this charset will be used to decode the requests.
    /// This value defaults to `None`, in which case ISO-8859-1 is used.
    #[cfg(feature = "charsets")]
    pub fn default_charset(&mut self, default_charset: Option<Charset>) {
        self.base_settings.set_default_charset(default_charset);
    }

    /// Sets if requests created from this `Session` will announce that they accept compression.
    ///
    /// This value defaults to true. Note that this only lets the browser know that the requests support
    /// compression, the server might choose not to compress the content.
    #[cfg(feature = "flate2")]
    pub fn allow_compression(&mut self, allow_compression: bool) {
        self.base_settings.set_allow_compression(allow_compression);
    }

    /// Sets if requests created from this `Session` will accept invalid TLS certificates.
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
    pub fn danger_accept_invalid_certs(&mut self, accept_invalid_certs: bool) {
        self.base_settings.set_accept_invalid_certs(accept_invalid_certs);
    }

    /// Sets if requests created from this `Session` will accept an invalid hostname in a TLS certificate.
    ///
    /// The default value is `false`.
    ///
    /// # Danger
    /// Use this setting with care. This will accept TLS certificates that do not match
    /// the hostname.
    pub fn danger_accept_invalid_hostnames(&mut self, accept_invalid_hostnames: bool) {
        self.base_settings
            .set_accept_invalid_hostnames(accept_invalid_hostnames);
    }

    /// Adds a root certificate that will be trusted by requests created from this `Session`.
    pub fn add_root_certificate(&mut self, cert: Certificate) {
        self.base_settings.add_root_certificate(cert);
    }
}
