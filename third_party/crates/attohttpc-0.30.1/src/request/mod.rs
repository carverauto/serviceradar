use std::convert::{From, TryInto};
use std::io::{prelude::*, BufWriter};
use std::str;
use std::sync::Arc;
use std::time::Instant;

#[cfg(feature = "flate2")]
use http::header::ACCEPT_ENCODING;
use http::{
    header::{HeaderValue, IntoHeaderName, HOST},
    HeaderMap, Method, StatusCode, Version,
};
use url::Url;

use crate::error::{Error, ErrorKind, InvalidResponseKind, Result};
use crate::parsing::{parse_response, Response};
use crate::streams::{BaseStream, ConnectInfo};

/// Contains types to describe request bodies
pub mod body;
mod builder;
pub mod proxy;
mod session;
mod settings;

use body::{Body, BodyKind};
pub use builder::{RequestBuilder, RequestInspector};
pub use session::Session;
pub(crate) use settings::BaseSettings;

fn header_insert<H, V>(headers: &mut HeaderMap, header: H, value: V) -> Result
where
    H: IntoHeaderName,
    V: TryInto<HeaderValue>,
    Error: From<V::Error>,
{
    let value = value.try_into()?;
    headers.insert(header, value);
    Ok(())
}

fn header_insert_if_missing<H, V>(headers: &mut HeaderMap, header: H, value: V) -> Result
where
    H: IntoHeaderName,
    V: TryInto<HeaderValue>,
    Error: From<V::Error>,
{
    let value = value.try_into()?;
    headers.entry(header).or_insert(value);
    Ok(())
}

fn header_append<H, V>(headers: &mut HeaderMap, header: H, value: V) -> Result
where
    H: IntoHeaderName,
    V: TryInto<HeaderValue>,
    Error: From<V::Error>,
{
    let value = value.try_into()?;
    headers.append(header, value);
    Ok(())
}

/// Represents a request that's ready to be sent. You can inspect this object for information about the request.
#[derive(Debug)]
pub struct PreparedRequest<B> {
    url: Url,
    method: Method,
    body: B,
    headers: HeaderMap,
    pub(crate) base_settings: Arc<BaseSettings>,
}

#[cfg(test)]
impl PreparedRequest<body::Empty> {
    pub(crate) fn new<U>(method: Method, base_url: U) -> Self
    where
        U: AsRef<str>,
    {
        PreparedRequest {
            url: Url::parse(base_url.as_ref()).unwrap(),
            method,
            body: body::Empty,
            headers: HeaderMap::new(),
            base_settings: Arc::new(BaseSettings::default()),
        }
    }
}

impl<B> PreparedRequest<B> {
    #[cfg(not(feature = "flate2"))]
    fn set_compression(&mut self) -> Result {
        Ok(())
    }

    #[cfg(feature = "flate2")]
    fn set_compression(&mut self) -> Result {
        if self.base_settings.allow_compression {
            header_insert(&mut self.headers, ACCEPT_ENCODING, "gzip, deflate")?;
        }
        Ok(())
    }

    fn base_redirect_url(&self, location: &str, previous_url: &Url) -> Result<Url> {
        match Url::parse(location) {
            Ok(url) => Ok(url),
            Err(url::ParseError::RelativeUrlWithoutBase) => {
                let joined_url = previous_url
                    .join(location)
                    .map_err(|_| InvalidResponseKind::RedirectionUrl)?;

                Ok(joined_url)
            }
            Err(_) => Err(InvalidResponseKind::RedirectionUrl.into()),
        }
    }

    fn write_headers<W>(&self, writer: &mut W) -> Result
    where
        W: Write,
    {
        for (key, value) in self.headers.iter() {
            write!(writer, "{}: ", key.as_str())?;
            writer.write_all(value.as_bytes())?;
            write!(writer, "\r\n")?;
        }
        write!(writer, "\r\n")?;
        Ok(())
    }

    /// Get the URL of this request.
    pub fn url(&self) -> &Url {
        &self.url
    }

    /// Get the method of this request.
    pub fn method(&self) -> &Method {
        &self.method
    }

    /// Get the body of the request.
    pub fn body(&self) -> &B {
        &self.body
    }

    /// Get the headers of this request.
    pub fn headers(&self) -> &HeaderMap {
        &self.headers
    }
}

impl<B: Body> PreparedRequest<B> {
    fn write_request<W>(&mut self, writer: W, url: &Url, proxy: Option<&Url>) -> Result
    where
        W: Write,
    {
        let mut writer = BufWriter::new(writer);
        let version = Version::HTTP_11;

        if proxy.is_some() && url.scheme() == "http" {
            debug!("{} {} {:?}", self.method.as_str(), url, version);

            write!(writer, "{} {} {:?}\r\n", self.method.as_str(), url, version)?;
        } else if let Some(query) = url.query() {
            debug!("{} {}?{} {:?}", self.method.as_str(), url.path(), query, version);

            write!(
                writer,
                "{} {}?{} {:?}\r\n",
                self.method.as_str(),
                url.path(),
                query,
                version,
            )?;
        } else {
            debug!("{} {} {:?}", self.method.as_str(), url.path(), version);

            write!(writer, "{} {} {:?}\r\n", self.method.as_str(), url.path(), version)?;
        }

        self.write_headers(&mut writer)?;

        match self.body.kind()? {
            BodyKind::Empty => (),
            BodyKind::KnownLength(len) => {
                debug!("writing out body of length {}", len);
                self.body.write(&mut writer)?;
            }
            BodyKind::Chunked => {
                debug!("writing out chunked body");
                let mut writer = body::ChunkedWriter(&mut writer);
                self.body.write(&mut writer)?;
                writer.close()?;
            }
        }

        writer.flush()?;

        Ok(())
    }

    /// Send this request and wait for the result.
    pub fn send(&mut self) -> Result<Response> {
        let mut url = self.url.clone();

        let deadline = self.base_settings.timeout.map(|timeout| Instant::now() + timeout);
        let mut redirections = 0;

        loop {
            // If a proxy is set and the url is using http, we must connect to the proxy and send
            // a request with an authority instead of a path.
            //
            // If a proxy is set and the url is using https, we must connect to the proxy using
            // the CONNECT method, and then send https traffic on the socket after the CONNECT
            // handshake.

            let proxy = self.base_settings.proxy_settings.for_url(&url).cloned();

            // If there is a proxy and the protocol is HTTP, the Host header will be the proxy's host name.
            match (url.scheme(), &proxy) {
                ("http", Some(proxy)) => set_host(&mut self.headers, proxy)?,
                _ => set_host(&mut self.headers, &url)?,
            };

            let info = ConnectInfo {
                url: &url,
                proxy: proxy.as_ref(),
                base_settings: &self.base_settings,
                deadline,
            };
            let mut stream = BaseStream::connect(&info)?;

            self.write_request(&mut stream, &url, proxy.as_ref())?;
            let resp = parse_response(stream, self, &url)?;

            debug!("status code {}", resp.status().as_u16());

            let is_redirect = matches!(
                resp.status(),
                StatusCode::MOVED_PERMANENTLY
                    | StatusCode::FOUND
                    | StatusCode::SEE_OTHER
                    | StatusCode::TEMPORARY_REDIRECT
                    | StatusCode::PERMANENT_REDIRECT
            );
            if !self.base_settings.follow_redirects || !is_redirect {
                return Ok(resp);
            }

            redirections += 1;
            if redirections > self.base_settings.max_redirections {
                return Err(ErrorKind::TooManyRedirections.into());
            }

            // Handle redirect
            let location = resp
                .headers()
                .get(http::header::LOCATION)
                .ok_or(InvalidResponseKind::LocationHeader)?;

            let location = String::from_utf8_lossy(location.as_bytes());

            url = self.base_redirect_url(&location, &url)?;

            debug!("redirected to {} giving url {}", location, url);
        }
    }
}

fn set_host(headers: &mut HeaderMap, url: &Url) -> Result {
    let host = url.host_str().ok_or(ErrorKind::InvalidUrlHost)?;
    if let Some(port) = url.port() {
        header_insert(headers, HOST, format!("{host}:{port}"))?;
    } else {
        header_insert(headers, HOST, host)?;
    }
    Ok(())
}

#[cfg(test)]
mod test {
    use std::sync::Arc;

    use http::header::{HeaderMap, HeaderValue, USER_AGENT};
    use http::Method;
    use url::Url;

    use super::BaseSettings;
    use super::{header_append, header_insert, header_insert_if_missing, PreparedRequest};
    use crate::body::Empty;

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
    fn test_http_url_with_http_proxy() {
        let mut req = PreparedRequest {
            method: Method::GET,
            url: Url::parse("http://reddit.com/r/rust").unwrap(),
            body: Empty,
            headers: HeaderMap::new(),
            base_settings: Arc::new(BaseSettings::default()),
        };

        let proxy = Url::parse("http://proxy:3128").unwrap();
        let mut buf: Vec<u8> = vec![];
        req.write_request(&mut buf, &req.url.clone(), Some(&proxy)).unwrap();

        let text = std::str::from_utf8(&buf).unwrap();
        let lines: Vec<_> = text.split("\r\n").collect();

        assert_eq!(lines[0], "GET http://reddit.com/r/rust HTTP/1.1");
    }

    #[test]
    fn test_http_url_with_https_proxy() {
        let mut req = PreparedRequest {
            method: Method::GET,
            url: Url::parse("http://reddit.com/r/rust").unwrap(),
            body: Empty,
            headers: HeaderMap::new(),
            base_settings: Arc::new(BaseSettings::default()),
        };

        let proxy = Url::parse("http://proxy:3128").unwrap();
        let mut buf: Vec<u8> = vec![];
        req.write_request(&mut buf, &req.url.clone(), Some(&proxy)).unwrap();

        let text = std::str::from_utf8(&buf).unwrap();
        let lines: Vec<_> = text.split("\r\n").collect();

        assert_eq!(lines[0], "GET http://reddit.com/r/rust HTTP/1.1");
    }
}
