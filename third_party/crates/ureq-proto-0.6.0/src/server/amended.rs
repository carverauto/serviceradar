use std::fmt;

use http::{HeaderName, HeaderValue, Response, StatusCode, Version, header};

use crate::Error;
use crate::body::BodyWriter;
use crate::util::compare_lowercase_ascii;

pub(crate) struct AmendedResponse {
    response: Response<()>,
    headers: Vec<(HeaderName, HeaderValue)>,
}

impl AmendedResponse {
    pub fn new(response: Response<()>) -> Self {
        AmendedResponse {
            response,
            headers: vec![],
        }
    }

    pub fn prelude(&self) -> (Version, StatusCode) {
        let r = &self.response;
        (r.version(), r.status())
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

    pub fn headers(&self) -> impl Iterator<Item = (&HeaderName, &HeaderValue)> {
        self.headers
            .iter()
            .map(|v| (&v.0, &v.1))
            .chain(self.response.headers().iter())
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

    pub fn analyze(&self, wanted_mode: BodyWriter) -> Result<ResponseInfo, Error> {
        let count_len = self.headers_get_all(header::CONTENT_LENGTH).count();
        if count_len > 1 {
            return Err(Error::TooManyContentLengthHeaders);
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

        let mut res_body_header = false;

        // https://datatracker.ietf.org/doc/html/rfc2616#section-4.4
        // Messages MUST NOT include both a Content-Length header field and a
        // non-identity transfer-coding. If the message does include a non-
        // identity transfer-coding, the Content-Length MUST be ignored.
        let body_mode = if has_chunked {
            // chunked "wins"
            res_body_header = true;
            BodyWriter::new_chunked()
        } else if let Some(n) = content_length {
            // user provided content-length second
            res_body_header = true;
            BodyWriter::new_sized(n)
        } else {
            wanted_mode
        };

        Ok(ResponseInfo {
            body_mode,
            res_body_header,
        })
    }
}

pub(crate) struct ResponseInfo {
    pub body_mode: BodyWriter,
    pub res_body_header: bool,
}

impl fmt::Debug for AmendedResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AmendedResponse")
            .field("status", &self.response.status())
            .field("headers", &self.headers)
            .finish()
    }
}
