use std::io::{self, BufRead, BufReader, Read, Take};

use http::header::{HeaderMap, HeaderValue, CONTENT_LENGTH, TRANSFER_ENCODING};

use crate::error::{InvalidResponseKind, Result};
use crate::parsing::chunked_reader::ChunkedReader;
use crate::streams::BaseStream;

#[derive(Debug)]
pub enum BodyReader {
    Chunked(ChunkedReader<BaseStream>),
    Length(Take<BufReader<BaseStream>>),
    Close(BufReader<BaseStream>),
}

impl Read for BodyReader {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            BodyReader::Chunked(r) => r.read(buf),
            BodyReader::Length(r) => r.read(buf),
            BodyReader::Close(r) => r.read(buf),
        }
    }
}

impl BufRead for BodyReader {
    #[inline]
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        match self {
            BodyReader::Chunked(r) => r.fill_buf(),
            BodyReader::Length(r) => r.fill_buf(),
            BodyReader::Close(r) => r.fill_buf(),
        }
    }

    #[inline]
    fn consume(&mut self, amt: usize) {
        match self {
            BodyReader::Chunked(r) => r.consume(amt),
            BodyReader::Length(r) => r.consume(amt),
            BodyReader::Close(r) => r.consume(amt),
        }
    }
}

fn is_chunked(headers: &HeaderMap) -> bool {
    headers
        .get_all(TRANSFER_ENCODING)
        .into_iter()
        .filter_map(|val| val.to_str().ok())
        .any(|val| {
            val.split(',')
                .map(|s| s.trim())
                .any(|s| s.eq_ignore_ascii_case("chunked"))
        })
}

fn parse_content_length(val: &HeaderValue) -> Result<u64> {
    let val = val.to_str().map_err(|_| InvalidResponseKind::ContentLength)?;
    let val = val.parse::<u64>().map_err(|_| InvalidResponseKind::ContentLength)?;
    Ok(val)
}

fn is_content_length(headers: &HeaderMap) -> Result<Option<u64>> {
    let mut last = None;
    for val in headers.get_all(CONTENT_LENGTH) {
        let val = parse_content_length(val)?;
        last = Some(match last {
            None => val,
            Some(last) if last == val => val,
            _ => {
                return Err(InvalidResponseKind::ContentLength.into());
            }
        });
    }
    Ok(last)
}

impl BodyReader {
    pub fn new(headers: &HeaderMap, reader: BufReader<BaseStream>) -> Result<BodyReader> {
        if is_chunked(headers) {
            debug!("creating a chunked body reader");
            Ok(BodyReader::Chunked(ChunkedReader::new(reader)))
        } else if let Some(val) = is_content_length(headers)? {
            debug!("creating a length body reader");
            Ok(BodyReader::Length(reader.take(val)))
        } else {
            debug!("creating close reader");
            Ok(BodyReader::Close(reader))
        }
    }
}

#[test]
fn test_is_chunked_false() {
    let mut headers = HeaderMap::new();
    headers.insert("content-encoding", HeaderValue::from_static("gzip"));
    assert!(!is_chunked(&headers));
}

#[test]
fn test_is_chunked_simple() {
    let mut headers = HeaderMap::new();
    headers.insert("transfer-encoding", HeaderValue::from_static("chunked"));
    assert!(is_chunked(&headers));
}

#[test]
fn test_is_chunked_multi() {
    let mut headers = HeaderMap::new();
    headers.insert("transfer-encoding", HeaderValue::from_static("gzip, chunked"));
    assert!(is_chunked(&headers));
}

#[test]
fn test_parse_content_length_ok() {
    assert_eq!(parse_content_length(&HeaderValue::from_static("17")).ok(), Some(17));
}

#[test]
fn test_parse_content_length_err() {
    assert!(parse_content_length(&HeaderValue::from_static("XD")).is_err());
}

#[test]
fn test_is_content_length_none() {
    let headers = HeaderMap::new();
    assert_eq!(is_content_length(&headers).ok(), Some(None));
}

#[test]
fn test_is_content_length_one() {
    let mut headers = HeaderMap::new();
    headers.insert("content-length", HeaderValue::from_static("88"));
    assert_eq!(is_content_length(&headers).ok(), Some(Some(88)));
}

#[test]
fn test_is_content_length_many_ok() {
    let mut headers = HeaderMap::new();
    headers.append("content-length", HeaderValue::from_static("88"));
    headers.append("content-length", HeaderValue::from_static("88"));

    assert_eq!(headers.get_all("content-length").iter().count(), 2);
    assert_eq!(is_content_length(&headers).ok(), Some(Some(88)));
}

#[test]
fn test_is_content_length_many_err() {
    let mut headers = HeaderMap::new();
    headers.append("content-length", HeaderValue::from_static("88"));
    headers.append("content-length", HeaderValue::from_static("90"));

    assert_eq!(headers.get_all("content-length").iter().count(), 2);
    assert!(is_content_length(&headers).is_err());
}
