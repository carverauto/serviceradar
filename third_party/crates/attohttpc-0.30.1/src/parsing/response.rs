use std::io::{self, BufReader, Read, Write};
use std::str;

use http::{
    header::{HeaderName, HeaderValue, TRANSFER_ENCODING},
    HeaderMap, StatusCode,
};
use url::Url;

use crate::error::{ErrorKind, InvalidResponseKind, Result};
use crate::parsing::buffers::{self, trim_byte};
use crate::parsing::{body_reader::BodyReader, compressed_reader::CompressedReader, ResponseReader};
use crate::request::PreparedRequest;
use crate::streams::BaseStream;

#[cfg(feature = "charsets")]
use crate::{charsets::Charset, parsing::TextReader};

#[cfg(feature = "json")]
use serde::de::DeserializeOwned;

pub fn parse_response_head<R>(reader: &mut BufReader<R>, max_headers: usize) -> Result<(StatusCode, HeaderMap)>
where
    R: Read,
{
    const MAX_LINE_LEN: u64 = 16 * 1024;

    let mut line = Vec::new();
    let mut headers = HeaderMap::new();

    // status line
    let status: StatusCode = {
        buffers::read_line(reader, &mut line, MAX_LINE_LEN)?;
        let mut parts = line.split(|&b| b == b' ').filter(|x| !x.is_empty());

        let _ = parts.next().ok_or(InvalidResponseKind::StatusLine)?;
        let code = parts.next().ok_or(InvalidResponseKind::StatusLine)?;

        str::from_utf8(code)
            .map_err(|_| InvalidResponseKind::StatusCode)?
            .parse()
            .map_err(|_| InvalidResponseKind::StatusCode)?
    };

    // headers
    loop {
        buffers::read_line_strict(reader, &mut line, MAX_LINE_LEN)?;
        if line.is_empty() {
            break;
        } else if headers.len() == max_headers {
            return Err(InvalidResponseKind::Header.into());
        }

        let col = line
            .iter()
            .position(|&c| c == b':')
            .ok_or(InvalidResponseKind::Header)?;

        buffers::replace_byte(b'\n', b' ', &mut line[col + 1..]);

        let header = trim_byte(b' ', &line[..col]);
        let value = trim_byte(b' ', &line[col + 1..]);

        let header = match HeaderName::from_bytes(header) {
            Ok(val) => val,
            Err(err) => {
                warn!("Dropped invalid response header: {}", err);
                continue;
            }
        };

        headers.append(header, HeaderValue::from_bytes(value).map_err(http::Error::from)?);
    }

    Ok((status, headers))
}

pub fn parse_response<B>(reader: BaseStream, request: &PreparedRequest<B>, url: &Url) -> Result<Response> {
    let mut reader = BufReader::new(reader);
    let (status, mut headers) = parse_response_head(&mut reader, request.base_settings.max_headers)?;
    let body_reader = BodyReader::new(&headers, reader)?;
    let compressed_reader = CompressedReader::new(&headers, request, body_reader)?;
    let response_reader = ResponseReader::new(&headers, request, compressed_reader);

    // Remove HOP-BY-HOP headers
    headers.remove(TRANSFER_ENCODING);

    Ok(Response {
        url: url.clone(),
        status,
        headers,
        reader: response_reader,
    })
}

/// `Response` represents a response returned by a server.
#[derive(Debug)]
pub struct Response {
    url: Url,
    status: StatusCode,
    headers: HeaderMap,
    reader: ResponseReader,
}

impl Response {
    /// Get the final URL of this `Response`.
    #[inline]
    pub fn url(&self) -> &Url {
        &self.url
    }

    /// Get the status code of this `Response`.
    #[inline]
    pub fn status(&self) -> StatusCode {
        self.status
    }

    /// Get the headers of this `Response`.
    #[inline]
    pub fn headers(&self) -> &HeaderMap {
        &self.headers
    }

    /// Checks if the status code of this `Response` was a success code.
    #[inline]
    pub fn is_success(&self) -> bool {
        self.status.is_success()
    }

    /// Returns error variant if the status code was not a success code.
    pub fn error_for_status(self) -> Result<Self> {
        if self.is_success() {
            Ok(self)
        } else {
            Err(ErrorKind::StatusCode(self.status).into())
        }
    }

    /// Split this `Response` into a tuple of `StatusCode`, `HeaderMap`, `ResponseReader`.
    ///
    /// This method is useful to read the status code or headers after consuming the response.
    #[inline]
    pub fn split(self) -> (StatusCode, HeaderMap, ResponseReader) {
        (self.status, self.headers, self.reader)
    }

    /// Write the response to any object that implements `Write`.
    #[inline]
    pub fn write_to<W>(self, writer: W) -> Result<u64>
    where
        W: Write,
    {
        self.reader.write_to(writer)
    }

    /// Read the response to a `Vec` of bytes.
    #[inline]
    pub fn bytes(self) -> Result<Vec<u8>> {
        self.reader.bytes()
    }

    /// Read the response to a `String`.
    ///
    /// If the `charsets` feature is enabled, it will try to decode the response using
    /// the encoding in the headers. If there's no encoding specified in the headers,
    /// it will fall back to the default encoding, and if that's also not specified,
    /// it will fall back to the default of ISO-8859-1.
    ///
    /// If the `charsets` feature is disabled, this method is the same as calling
    /// `text_utf8`.
    ///
    /// Note that both conversions are lossy, i.e. they will not raise errors when
    /// invalid data is encountered but output replacement characters instead.
    #[inline]
    pub fn text(self) -> Result<String> {
        self.reader.text()
    }

    /// Read the response to a `String`, decoding with the given `Charset`.
    ///
    /// This will ignore the encoding from the response headers and the default encoding, if any.
    ///
    /// This method only exists when the `charsets` feature is enabled.
    #[cfg(feature = "charsets")]
    #[inline]
    pub fn text_with(self, charset: Charset) -> Result<String> {
        self.reader.text_with(charset)
    }

    /// Create a `TextReader` from this `ResponseReader`.
    ///
    /// If the response headers contain charset information, that charset will be used to decode the body.
    /// Otherwise, if a default encoding is set it will be used. If there is no default encoding, ISO-8859-1
    /// will be used.
    ///
    /// This method only exists when the `charsets` feature is enabled.
    #[cfg(feature = "charsets")]
    pub fn text_reader(self) -> TextReader<BufReader<ResponseReader>> {
        self.reader.text_reader()
    }

    /// Create a `TextReader` from this `ResponseReader`, decoding with the given `Charset`.
    ///
    /// This will ignore the encoding from the response headers and the default encoding, if any.
    ///
    /// This method only exists when the `charsets` feature is enabled.
    #[cfg(feature = "charsets")]
    #[inline]
    pub fn text_reader_with(self, charset: Charset) -> TextReader<BufReader<ResponseReader>> {
        self.reader.text_reader_with(charset)
    }

    /// Read the response body to a String using the UTF-8 encoding.
    ///
    /// This method ignores headers and the default encoding.
    ///
    /// Note that is lossy, i.e. it will not raise errors when
    /// invalid data is encountered but output replacement characters instead.
    #[inline]
    pub fn text_utf8(self) -> Result<String> {
        self.reader.text_utf8()
    }

    /// Parse the response as a JSON object and return it.
    ///
    /// If the `charsets` feature is enabled, it will try to decode the response using
    /// the encoding in the headers. If there's no encoding specified in the headers,
    /// it will fall back to the default encoding, and if that's also not specified,
    /// it will fall back to the default of ISO-8859-1.
    ///
    /// If the `charsets` feature is disabled, this method is the same as calling
    /// `json_utf8`.
    #[cfg(feature = "json")]
    #[inline]
    pub fn json<T>(self) -> Result<T>
    where
        T: DeserializeOwned,
    {
        self.reader.json()
    }

    /// Parse the response as a JSON object encoded in UTF-8.
    ///
    /// This method ignores headers and the default encoding.
    ///
    /// This method only exists when the `json` feature is enabled.
    #[cfg(feature = "json")]
    #[inline]
    pub fn json_utf8<T>(self) -> Result<T>
    where
        T: DeserializeOwned,
    {
        self.reader.json_utf8()
    }
}

impl Read for Response {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.reader.read(buf)
    }
}

#[test]
fn test_read_request_head() {
    let response = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello";
    let mut reader = BufReader::new(&response[..]);
    let (status, headers) = parse_response_head(&mut reader, 100).unwrap();
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers.len(), 2);
    assert_eq!(headers[http::header::CONTENT_LENGTH], "5");
    assert_eq!(headers[http::header::CONTENT_TYPE], "text/plain");
}

#[test]
fn test_line_folded_header() {
    let response = b"HTTP/1.1 200 OK\r\nheader-of-great-many-lines: foo\nbar\nbaz\nqux\r\nthe-other-kind-of-header: foobar\r\n\r\n";
    let mut reader = BufReader::new(&response[..]);
    let (status, headers) = parse_response_head(&mut reader, 100).unwrap();
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers.len(), 2);
    assert_eq!(headers["header-of-great-many-lines"], "foo bar baz qux");
    assert_eq!(headers["the-other-kind-of-header"], "foobar");
}

#[test]
fn test_max_headers_limit() {
    let response = b"HTTP/1.1 200 OK\r\nfirst-header: foo\r\nsecond-header: bar\r\none-header-too-many: baz\r\n\r\n";
    let mut reader = BufReader::new(&response[..]);
    let err = parse_response_head(&mut reader, 2).unwrap_err();
    assert!(matches!(
        err.kind(),
        ErrorKind::InvalidResponse(InvalidResponseKind::Header)
    ));
}
