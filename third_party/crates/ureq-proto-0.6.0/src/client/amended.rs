use std::{fmt, mem};

use http::uri::PathAndQuery;
use http::{HeaderMap, HeaderName, HeaderValue, Method, Request, Uri, Version, header};

use crate::Error;
use crate::body::BodyWriter;
use crate::ext::MethodExt;
use crate::util::compare_lowercase_ascii;

/// `Request` with amends.
///
/// The user provides the `Request<()>`, which we consider an immutable object.
/// When executing a request there are a couple of changes/overrides required to
/// that immutable object. The `AmendedRequest` encapsulates the original request
/// and the amends.
///
/// The expected amends are:
///
/// 1.  Cookie headers. Cookie jar functionality is out of scope, but the
///     `headers from such a jar should be possible to add.
/// 2.  `Host` header. Taken from the Request URI unless already set.
/// 3.  `Content-Type` header. The actual request body handling is out of scope,
///     but an implementation must be able to autodetect the content type for a given body
///     and provide that on the request.
/// 4.  `Content-Length` header. When sending non chunked transfer bodies (and not HTTP/1.0
///     which closes the connection).
/// 5.  `Transfer-Encoding: chunked` header when the content length for a body is unknown.
/// 6.  `Content-Encoding` header to indicate on-the-wire compression. The compression itself
///     is out of scope, but the user must be able to set it.
/// 7.  `User-Agent` header.
/// 8.  `Accept` header.
///
pub(crate) struct AmendedRequest {
    request: Request<()>,
    headers: Vec<(HeaderName, HeaderValue)>,
}

impl AmendedRequest {
    pub fn new(request: Request<()>) -> Self {
        AmendedRequest {
            request,
            headers: vec![],
        }
    }

    pub fn take_request(&mut self) -> Request<()> {
        let empty = http::Request::new(());
        mem::replace(&mut self.request, empty)
    }

    pub fn uri(&self) -> &Uri {
        self.request.uri()
    }

    pub fn prelude(&self) -> (&Method, &str, Version) {
        let r = &self.request;

        let target = if r.method() == Method::CONNECT {
            // unwrap allowed as previous code returns error if no authority exists for CONNECT request
            self.uri().authority().unwrap().as_str()
        } else {
            self.uri()
                .path_and_query()
                .map(|p| p.as_str())
                .unwrap_or("/")
        };

        (r.method(), target, r.version())
    }

    pub fn set_header<K, V>(&mut self, name: K, value: V) -> Result<(), Error>
    where
        HeaderName: TryFrom<K>,
        <HeaderName as TryFrom<K>>::Error: Into<http::Error>,
        HeaderValue: TryFrom<V>,
        <HeaderValue as TryFrom<V>>::Error: Into<http::Error>,
    {
        let name = <HeaderName as TryFrom<K>>::try_from(name)
            .map_err(Into::into)
            .map_err(|e| Error::BadHeader(e.to_string()))?;
        let value = <HeaderValue as TryFrom<V>>::try_from(value)
            .map_err(Into::into)
            .map_err(|e| Error::BadHeader(e.to_string()))?;
        self.headers.push((name, value));
        Ok(())
    }

    pub fn original_request_headers(&self) -> &HeaderMap {
        self.request.headers()
    }

    pub fn headers(&self) -> impl Iterator<Item = (&HeaderName, &HeaderValue)> {
        self.headers
            .iter()
            .map(|v| (&v.0, &v.1))
            .chain(self.request.headers().iter())
    }

    fn headers_get_all(&self, key: HeaderName) -> impl Iterator<Item = &HeaderValue> {
        self.headers()
            .filter(move |(k, _)| *k == key)
            .map(|(_, v)| v)
    }

    fn headers_get(&self, key: HeaderName) -> Option<&HeaderValue> {
        self.headers_get_all(key).next()
    }

    pub fn headers_len(&self) -> usize {
        self.headers().count()
    }

    #[cfg(test)]
    pub fn headers_vec(&self) -> Vec<(&str, &str)> {
        self.headers()
            // unwrap here is ok because the tests using this method should
            // only use header values representable as utf-8.
            // If we want to test non-utf8 header values, use .headers()
            // iterator instead.
            .map(|(k, v)| (k.as_str(), v.to_str().unwrap()))
            .collect()
    }

    pub fn method(&self) -> &Method {
        self.request.method()
    }

    pub(crate) fn version(&self) -> Version {
        self.request.version()
    }

    pub fn new_uri_from_location(&self, location: &str) -> Result<Uri, Error> {
        let base = self.uri().clone();
        join(base, location)
    }

    pub fn analyze(
        &self,
        wanted_mode: BodyWriter,
        allow_non_standard_methods: bool,
    ) -> Result<RequestInfo, Error> {
        let v = self.request.version();
        let m = self.method();

        if !allow_non_standard_methods {
            m.verify_version(v)?;
        }

        let count_host = self.headers_get_all(header::HOST).count();
        if count_host > 1 {
            return Err(Error::TooManyHostHeaders);
        }

        let count_len = self.headers_get_all(header::CONTENT_LENGTH).count();
        if count_len > 1 {
            return Err(Error::TooManyContentLengthHeaders);
        }

        let mut req_host_header = false;
        if let Some(h) = self.headers_get(header::HOST) {
            h.to_str().map_err(|_| Error::BadHostHeader)?;
            req_host_header = true;
        }

        let mut req_auth_header = false;
        if let Some(h) = self.headers_get(header::AUTHORIZATION) {
            h.to_str().map_err(|_| Error::BadAuthorizationHeader)?;
            req_auth_header = true;
        }

        let mut content_length: Option<u64> = None;
        if let Some(h) = self.headers_get(header::CONTENT_LENGTH) {
            let n = h
                .to_str()
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .ok_or(Error::BadContentLengthHeader)?;
            content_length = Some(n);
        }

        let has_chunked = self
            .headers_get_all(header::TRANSFER_ENCODING)
            .filter_map(|v| v.to_str().ok())
            .any(|v| compare_lowercase_ascii(v, "chunked"));

        let req_body_header = has_chunked || content_length.is_some();

        // https://datatracker.ietf.org/doc/html/rfc2616#section-4.4
        // Messages MUST NOT include both a Content-Length header field and a
        // non-identity transfer-coding. If the message does include a non-
        // identity transfer-coding, the Content-Length MUST be ignored.
        let body_mode = if has_chunked {
            // chunked "wins"
            BodyWriter::new_chunked()
        } else if let Some(n) = content_length {
            // user provided content-length second
            BodyWriter::new_sized(n)
        } else {
            wanted_mode
        };

        Ok(RequestInfo {
            body_mode,
            req_host_header,
            req_auth_header,
            req_body_header,
        })
    }
}

fn join(base: Uri, location: &str) -> Result<Uri, Error> {
    let mut parts = base.into_parts();

    let maybe = location.parse::<Uri>();
    let has_scheme = maybe
        .as_ref()
        .ok()
        .map(|u| u.scheme().is_some())
        .unwrap_or(false);

    if has_scheme {
        // Location is a complete Uri.
        // unwrap is ok beause has_scheme cannot be true if parsing failed.
        return Ok(maybe.unwrap());
    }

    if location.starts_with("/") {
        // Location is root-relative, i.e. we keep the
        // authority of the base uri but replace the path

        let pq: PathAndQuery = location
            .parse()
            .map_err(|_| Error::BadLocationHeader(location.to_string()))?;

        parts.path_and_query = Some(pq);
    } else {
        // Location is relative, i.e. y/foo.html, ../ or ./ which means
        // we should interpret it against the base uri path.
        let base_path = parts
            .path_and_query
            .as_ref()
            .map(|p| p.path())
            .unwrap_or("/");

        let total_path = join_relative(base_path, location)?;

        let pq: PathAndQuery = total_path
            .parse()
            .map_err(|_| Error::BadLocationHeader(location.to_string()))?;

        parts.path_and_query = Some(pq);
    }

    let uri = Uri::from_parts(parts).map_err(|_| Error::BadLocationHeader(location.to_string()))?;

    Ok(uri)
}

fn join_relative(base_path: &str, location: &str) -> Result<String, Error> {
    // base_path should be at least "/".
    assert!(!base_path.is_empty());
    // we should not attempt to join relative if location starts with "/"
    assert!(!location.starts_with("/"));

    let mut joiner: Vec<&str> = base_path.split('/').collect();

    // "" => [""]
    // "/" => ["", ""]
    // "/foo" => ["", "foo"]
    // "/foo/" => ["", "foo", ""]
    if joiner.len() > 1 {
        joiner.pop();
    }

    for segment in location.split('/') {
        if segment == "." {
            // do nothing
        } else if segment == ".." {
            if joiner.len() == 1 {
                trace!("Location is relative above root");
                return Err(Error::BadLocationHeader(location.to_string()));
            }
            joiner.pop();
        } else {
            joiner.push(segment);
        }
    }

    Ok(joiner.join("/"))
}

pub(crate) struct RequestInfo {
    pub body_mode: BodyWriter,
    pub req_host_header: bool,
    pub req_auth_header: bool,
    pub req_body_header: bool,
}

impl fmt::Debug for AmendedRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AmendedRequest")
            .field("method", &self.request.method())
            .field("headers", &self.headers)
            .finish()
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn join_things() {
        let uri: Uri = "foo.html".parse().unwrap();
        println!("{:?}", uri.into_parts());
    }
}
