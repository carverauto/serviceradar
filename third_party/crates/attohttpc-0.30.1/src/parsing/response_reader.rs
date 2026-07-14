#[cfg(any(feature = "charsets", feature = "json"))]
use std::io::BufReader;
use std::io::{self, Read, Write};

use http::header::HeaderMap;
#[cfg(feature = "json")]
use serde::de::DeserializeOwned;

use crate::error::Result;
use crate::parsing::compressed_reader::CompressedReader;
use crate::request::PreparedRequest;

#[cfg(feature = "charsets")]
use {
    crate::{
        charsets::{self, Charset},
        parsing::buffers::trim_byte,
        parsing::TextReader,
    },
    encoding_rs::Encoding,
    http::header::CONTENT_TYPE,
};

#[cfg(feature = "charsets")]
fn get_charset(headers: &HeaderMap, default_charset: Option<Charset>) -> Charset {
    if let Some(value) = headers.get(CONTENT_TYPE) {
        let bytes = value.as_bytes();
        if let Some(scol) = bytes.iter().position(|&b| b == b';') {
            let rhs = trim_byte(b' ', &bytes[scol + 1..]);
            if rhs.starts_with(b"charset=") {
                if let Some(enc) = Encoding::for_label(&rhs[8..]) {
                    return enc;
                }
            }
        }
    }
    default_charset.unwrap_or(charsets::WINDOWS_1252)
}

/// The `ResponseReader` is used to read the body of a response.
///
/// The `ResponseReader` implements `Read` and can be used like any other stream,
/// but the data returned by `Read` are untouched bytes from the socket. This means
/// that if a string is expected back, it could be in a different encoding than the
/// expected one. In order to properly read text, use the `charsets` feature and the
/// `text` or `text_reader` methods.
///
/// In general it's best to avoid `Read`ing directly from this object. Instead use the
/// helper methods, they process the data stream properly.
#[derive(Debug)]
pub struct ResponseReader {
    inner: CompressedReader,
    #[cfg(feature = "charsets")]
    charset: Charset,
}

impl ResponseReader {
    #[cfg(feature = "charsets")]
    pub(crate) fn new<B>(
        headers: &HeaderMap,
        request: &PreparedRequest<B>,
        reader: CompressedReader,
    ) -> ResponseReader {
        ResponseReader {
            inner: reader,
            charset: get_charset(headers, request.base_settings.default_charset),
        }
    }

    #[cfg(not(feature = "charsets"))]
    pub(crate) fn new<B>(_: &HeaderMap, _: &PreparedRequest<B>, reader: CompressedReader) -> ResponseReader {
        ResponseReader { inner: reader }
    }

    /// Write the response to any object that implements `Write`.
    pub fn write_to<W>(mut self, mut writer: W) -> Result<u64>
    where
        W: Write,
    {
        let n = io::copy(&mut self.inner, &mut writer)?;
        Ok(n)
    }

    /// Read the response to a `Vec` of bytes.
    pub fn bytes(self) -> Result<Vec<u8>> {
        let mut buf = Vec::new();
        self.write_to(&mut buf)?;
        Ok(buf)
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
    #[cfg(not(feature = "charsets"))]
    pub fn text(self) -> Result<String> {
        self.text_utf8()
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
    #[cfg(feature = "charsets")]
    pub fn text(self) -> Result<String> {
        let charset = self.charset;
        self.text_with(charset)
    }

    /// Read the response to a `String`, decoding with the given `Charset`.
    ///
    /// This will ignore the encoding from the response headers and the default encoding, if any.
    ///
    /// This method only exists when the `charsets` feature is enabled.
    #[cfg(feature = "charsets")]
    pub fn text_with(self, charset: Charset) -> Result<String> {
        let mut reader = self.text_reader_with(charset);
        let mut text = String::new();
        reader.read_to_string(&mut text)?;
        Ok(text)
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
        let charset = self.charset;
        self.text_reader_with(charset)
    }

    /// Create a `TextReader` from this `ResponseReader`, decoding with the given `Charset`.
    ///
    /// This will ignore the encoding from the response headers and the default encoding, if any.
    ///
    /// This method only exists when the `charsets` feature is enabled.
    #[cfg(feature = "charsets")]
    pub fn text_reader_with(self, charset: Charset) -> TextReader<BufReader<ResponseReader>> {
        TextReader::new(BufReader::new(self), charset)
    }

    /// Read the response body to a String using the UTF-8 encoding.
    ///
    /// This method ignores headers and the default encoding.
    ///
    /// Note that this is lossy, i.e. it will not raise errors when
    /// invalid data is encountered but output replacement characters instead.
    pub fn text_utf8(mut self) -> Result<String> {
        let mut buf = Vec::new();
        self.inner.read_to_end(&mut buf)?;

        let text = String::from_utf8(buf).unwrap_or_else(|err| String::from_utf8_lossy(err.as_bytes()).into_owned());

        Ok(text)
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
    #[cfg(feature = "charsets")]
    pub fn json<T>(self) -> Result<T>
    where
        T: DeserializeOwned,
    {
        let reader = BufReader::new(self.text_reader());
        let obj = serde_json::from_reader(reader)?;
        Ok(obj)
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
    #[cfg(not(feature = "charsets"))]
    pub fn json<T>(self) -> Result<T>
    where
        T: DeserializeOwned,
    {
        self.json_utf8()
    }

    /// Parse the response as a JSON object encoded in UTF-8.
    ///
    /// This method ignores headers and the default encoding.
    ///
    /// This method only exists when the `json` feature is enabled.
    #[cfg(feature = "json")]
    pub fn json_utf8<T>(self) -> Result<T>
    where
        T: DeserializeOwned,
    {
        let reader = BufReader::new(self);
        let obj = serde_json::from_reader(reader)?;
        Ok(obj)
    }
}

impl Read for ResponseReader {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.inner.read(buf)
    }
}

#[cfg(test)]
#[cfg(feature = "charsets")]
mod tests {
    use http::header::{HeaderMap, HeaderValue, CONTENT_TYPE};

    use super::get_charset;
    use crate::charsets;

    #[test]
    fn test_get_charset_from_header() {
        let mut headers = HeaderMap::new();
        headers.insert(
            CONTENT_TYPE,
            HeaderValue::from_bytes(&b"text/html; charset=UTF-8"[..]).unwrap(),
        );
        assert_eq!(get_charset(&headers, None), charsets::UTF_8);
    }

    #[test]
    fn test_get_charset_from_header_lowercase() {
        let mut headers = HeaderMap::new();
        headers.insert(
            CONTENT_TYPE,
            HeaderValue::from_bytes(&b"text/html; charset=utf8"[..]).unwrap(),
        );
        assert_eq!(get_charset(&headers, None), charsets::UTF_8);
    }

    #[test]
    fn test_get_charset_from_default() {
        let headers = HeaderMap::new();
        assert_eq!(get_charset(&headers, Some(charsets::UTF_8)), charsets::UTF_8);
    }

    #[test]
    fn test_get_charset_standard() {
        let headers = HeaderMap::new();
        assert_eq!(get_charset(&headers, None), charsets::WINDOWS_1252);
    }
}
