use std::io::{self, Read};

#[cfg(feature = "flate2")]
use flate2::bufread::{DeflateDecoder, GzDecoder};
use http::header::HeaderMap;
#[cfg(feature = "flate2")]
use http::header::{CONTENT_ENCODING, TRANSFER_ENCODING};
#[cfg(feature = "flate2")]
use http::Method;

use crate::error::Result;
use crate::parsing::body_reader::BodyReader;
use crate::request::PreparedRequest;

#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub enum CompressedReader {
    Plain(BodyReader),
    #[cfg(feature = "flate2")]
    Deflate(DeflateDecoder<BodyReader>),
    #[cfg(feature = "flate2")]
    Gzip(GzDecoder<BodyReader>),
}

#[cfg(feature = "flate2")]
fn have_encoding_item(value: &str, enc: &str) -> bool {
    value.split(',').map(|s| s.trim()).any(|s| s.eq_ignore_ascii_case(enc))
}

#[cfg(feature = "flate2")]
fn have_encoding_content_encoding(headers: &HeaderMap, enc: &str) -> bool {
    headers
        .get_all(CONTENT_ENCODING)
        .into_iter()
        .filter_map(|val| val.to_str().ok())
        .any(|val| have_encoding_item(val, enc))
}

#[cfg(feature = "flate2")]
fn have_encoding_transfer_encoding(headers: &HeaderMap, enc: &str) -> bool {
    headers
        .get_all(TRANSFER_ENCODING)
        .into_iter()
        .filter_map(|val| val.to_str().ok())
        .any(|val| have_encoding_item(val, enc))
}

#[cfg(feature = "flate2")]
fn have_encoding(headers: &HeaderMap, enc: &str) -> bool {
    have_encoding_content_encoding(headers, enc) || have_encoding_transfer_encoding(headers, enc)
}

impl CompressedReader {
    #[cfg(feature = "flate2")]
    pub fn new<B>(headers: &HeaderMap, request: &PreparedRequest<B>, reader: BodyReader) -> Result<CompressedReader> {
        if request.method() != Method::HEAD {
            if have_encoding(headers, "gzip") {
                debug!("creating gzip decoder");
                return Ok(CompressedReader::Gzip(GzDecoder::new(reader)));
            }

            if have_encoding(headers, "deflate") {
                debug!("creating deflate decoder");
                return Ok(CompressedReader::Deflate(DeflateDecoder::new(reader)));
            }
        }
        debug!("creating plain reader");
        Ok(CompressedReader::Plain(reader))
    }

    #[cfg(not(feature = "flate2"))]
    pub fn new<B>(_: &HeaderMap, _: &PreparedRequest<B>, reader: BodyReader) -> Result<CompressedReader> {
        Ok(CompressedReader::Plain(reader))
    }
}

impl Read for CompressedReader {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        // TODO: gzip does not read until EOF, leaving some data in the buffer.
        match self {
            CompressedReader::Plain(s) => s.read(buf),
            #[cfg(feature = "flate2")]
            CompressedReader::Deflate(s) => s.read(buf),
            #[cfg(feature = "flate2")]
            CompressedReader::Gzip(s) => s.read(buf),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::prelude::*;

    #[cfg(feature = "flate2")]
    use flate2::{
        write::{DeflateEncoder, GzEncoder},
        Compression,
    };
    #[cfg(feature = "flate2")]
    use http::header::{HeaderMap, HeaderValue};
    use http::Method;

    #[cfg(feature = "flate2")]
    use super::have_encoding;
    use crate::parsing::response::parse_response;
    use crate::streams::BaseStream;
    use crate::PreparedRequest;

    #[test]
    #[cfg(feature = "flate2")]
    fn test_have_encoding_none() {
        let mut headers = HeaderMap::new();
        headers.insert("content-encoding", HeaderValue::from_static("gzip"));
        assert!(!have_encoding(&headers, "deflate"));
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_have_encoding_content_encoding_simple() {
        let mut headers = HeaderMap::new();
        headers.insert("content-encoding", HeaderValue::from_static("gzip"));
        assert!(have_encoding(&headers, "gzip"));
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_have_encoding_content_encoding_multi() {
        let mut headers = HeaderMap::new();
        headers.insert("content-encoding", HeaderValue::from_static("identity, deflate"));
        assert!(have_encoding(&headers, "deflate"));
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_have_encoding_transfer_encoding_simple() {
        let mut headers = HeaderMap::new();
        headers.insert("transfer-encoding", HeaderValue::from_static("deflate"));
        assert!(have_encoding(&headers, "deflate"));
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_have_encoding_transfer_encoding_multi() {
        let mut headers = HeaderMap::new();
        headers.insert("transfer-encoding", HeaderValue::from_static("gzip, chunked"));
        assert!(have_encoding(&headers, "gzip"));
    }

    #[test]
    fn test_stream_plain() {
        let payload = b"Hello world!!!!!!!!";

        let mut buf: Vec<u8> = Vec::new();
        let _ = write!(buf, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", payload.len());
        buf.extend(payload);

        let req = PreparedRequest::new(Method::GET, "http://google.ca");

        let sock = BaseStream::mock(buf);
        let response = parse_response(sock, &req, req.url()).unwrap();
        assert_eq!(response.text().unwrap(), "Hello world!!!!!!!!");
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_stream_deflate() {
        let mut payload = Vec::new();
        let mut enc = DeflateEncoder::new(&mut payload, Compression::default());
        enc.write_all(b"Hello world!!!!!!!!").unwrap();
        enc.finish().unwrap();

        let mut buf: Vec<u8> = Vec::new();
        let _ = write!(
            buf,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Encoding: deflate\r\n\r\n",
            payload.len()
        );
        buf.extend(payload);

        let req = PreparedRequest::new(Method::GET, "http://google.ca");

        let sock = BaseStream::mock(buf);
        let response = parse_response(sock, &req, req.url()).unwrap();
        assert_eq!(response.text().unwrap(), "Hello world!!!!!!!!");
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_stream_gzip() {
        let mut payload = Vec::new();
        let mut enc = GzEncoder::new(&mut payload, Compression::default());
        enc.write_all(b"Hello world!!!!!!!!").unwrap();
        enc.finish().unwrap();

        let mut buf: Vec<u8> = Vec::new();
        let _ = write!(
            buf,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Encoding: gzip\r\n\r\n",
            payload.len()
        );
        buf.extend(payload);

        let req = PreparedRequest::new(Method::GET, "http://google.ca");

        let sock = BaseStream::mock(buf);
        let response = parse_response(sock, &req, req.url()).unwrap();

        assert_eq!(response.text().unwrap(), "Hello world!!!!!!!!");
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_no_body_with_gzip() {
        let buf = b"HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\n\r\n";

        let req = PreparedRequest::new(Method::GET, "http://google.ca");
        let sock = BaseStream::mock(buf.to_vec());
        // Fixed by the move from libflate to flate2
        assert!(parse_response(sock, &req, req.url()).is_ok());
    }

    #[test]
    #[cfg(feature = "flate2")]
    fn test_no_body_with_gzip_head() {
        let buf = b"HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\n\r\n";

        let req = PreparedRequest::new(Method::HEAD, "http://google.ca");
        let sock = BaseStream::mock(buf.to_vec());
        assert!(parse_response(sock, &req, req.url()).is_ok());
    }
}
