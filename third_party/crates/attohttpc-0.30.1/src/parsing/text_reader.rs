use std::io::{self, Read};

use encoding_rs_io::{DecodeReaderBytes, DecodeReaderBytesBuilder};

use crate::charsets::Charset;

/// `TextReader` converts bytes in a specific charset to bytes in UTF-8.
///
/// It can be used to convert a stream of text in a specific charset into a stream
/// of UTF-8 encoded bytes. The `Read::read_to_string` method can be used to convert
/// the stream of UTF-8 bytes into a `String`.
#[derive(Debug)]
pub struct TextReader<R>(DecodeReaderBytes<R, Vec<u8>>);

impl<R> TextReader<R>
where
    R: Read,
{
    /// Create a new `TextReader` with the given charset.
    pub fn new(inner: R, charset: Charset) -> Self {
        Self(DecodeReaderBytesBuilder::new().encoding(Some(charset)).build(inner))
    }
}

impl<R> Read for TextReader<R>
where
    R: Read,
{
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.read(buf)
    }
}

#[test]
fn test_stream_decoder_utf8() {
    let mut reader = TextReader::new("québec".as_bytes(), crate::charsets::UTF_8);

    let mut text = String::new();
    assert_eq!(reader.read_to_string(&mut text).ok(), Some(7));

    assert_eq!(text, "québec");
}

#[test]
fn test_stream_decoder_latin1() {
    let mut reader = TextReader::new(&b"qu\xC9bec"[..], crate::charsets::WINDOWS_1252);

    let mut text = String::new();
    assert_eq!(reader.read_to_string(&mut text).ok(), Some(7));

    assert_eq!(text, "quÉbec");
}

#[test]
fn test_string_reader_large_buffer_latin1() {
    let buf = vec![201; 10_000];
    let mut reader = TextReader::new(&buf[..], crate::charsets::WINDOWS_1252);

    let mut text = String::new();
    assert_eq!(20_000, reader.read_to_string(&mut text).unwrap());
    assert_eq!(text.len(), 20_000);

    for c in text.chars() {
        assert_eq!(c, 'É');
    }
}
