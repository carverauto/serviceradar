use std::fmt;
use std::io::Write;

use http::{HeaderName, HeaderValue, Method, header};

use crate::Error;
use crate::chunk::Dechunker;
use crate::util::{Writer, compare_lowercase_ascii, log_data};

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct BodyWriter {
    mode: SenderMode,
    ended: bool,
}

#[derive(Debug, Clone, Copy, Default)]
enum SenderMode {
    #[default]
    None,
    Sized(u64),
    Chunked,
}

// This is 0x2800 in hex.
pub(crate) const DEFAULT_CHUNK_SIZE: usize = 10 * 1024;
// 4 is 0x2800 and the other + 4 is for the \r\n\r\n overhead.
pub(crate) const DEFAULT_CHUNK_OVERHEAD: usize = 4 + 4;
pub(crate) const DEFAULT_CHUNK_AND_OVERHEAD: usize = DEFAULT_CHUNK_SIZE + DEFAULT_CHUNK_OVERHEAD;

impl BodyWriter {
    pub fn new_none() -> Self {
        BodyWriter {
            mode: SenderMode::None,
            ended: true,
        }
    }

    pub fn new_chunked() -> Self {
        BodyWriter {
            mode: SenderMode::Chunked,
            ended: false,
        }
    }

    pub fn new_sized(size: u64) -> Self {
        BodyWriter {
            mode: SenderMode::Sized(size),
            ended: false,
        }
    }

    #[cfg(feature = "server")]
    pub fn body_mode(&self) -> BodyMode {
        match self.mode {
            SenderMode::None => BodyMode::NoBody,
            SenderMode::Sized(n) => BodyMode::LengthDelimited(n),
            SenderMode::Chunked => BodyMode::Chunked,
        }
    }

    pub fn has_body(&self) -> bool {
        match self.mode {
            SenderMode::Sized(n) => n > 0,
            SenderMode::Chunked => true,
            SenderMode::None => false,
        }
    }

    pub fn is_chunked(&self) -> bool {
        matches!(self.mode, SenderMode::Chunked)
    }

    pub fn write(&mut self, input: &[u8], w: &mut Writer) -> usize {
        match &mut self.mode {
            SenderMode::None => unreachable!(),
            SenderMode::Sized(left) => {
                let left_usize = (*left).min(usize::MAX as u64) as usize;
                let to_write = w.available().min(input.len()).min(left_usize);

                let success = w.try_write(|w| w.write_all(&input[..to_write]));
                assert!(success);

                *left -= to_write as u64;

                if *left == 0 {
                    self.ended = true;
                }

                to_write
            }
            SenderMode::Chunked => {
                let mut input_used = 0;

                if input.is_empty() {
                    self.finish(w);
                    self.ended = true;
                } else {
                    // The chunk size might be smaller than the entire input, in which case
                    // we continue to send chunks frome the same input.
                    while write_chunk(
                        //
                        &input[input_used..],
                        &mut input_used,
                        w,
                        DEFAULT_CHUNK_SIZE,
                    ) {}
                }

                input_used
            }
        }
    }

    fn finish(&self, w: &mut Writer) -> bool {
        if self.is_chunked() {
            let success = w.try_write(|w| w.write_all(b"0\r\n\r\n"));
            if !success {
                return false;
            }
        }
        true
    }

    pub(crate) fn body_header(&self) -> (HeaderName, HeaderValue) {
        match self.mode {
            SenderMode::None => unreachable!(),
            SenderMode::Sized(size) => (
                header::CONTENT_LENGTH,
                // TODO(martin): avoid allocation here
                HeaderValue::from_str(&size.to_string()).unwrap(),
            ),
            SenderMode::Chunked => (
                header::TRANSFER_ENCODING,
                HeaderValue::from_static("chunked"),
            ),
        }
    }

    pub(crate) fn is_ended(&self) -> bool {
        self.ended
    }

    pub(crate) fn left_to_send(&self) -> Option<u64> {
        match self.mode {
            SenderMode::Sized(v) => Some(v),
            _ => None,
        }
    }

    pub(crate) fn consume_direct_write(&mut self, amount: usize) {
        match &mut self.mode {
            SenderMode::None => unreachable!(),
            SenderMode::Sized(left) => {
                *left -= amount as u64;

                if *left == 0 {
                    self.ended = true;
                }
            }
            SenderMode::Chunked => unreachable!(),
        }
    }
}

#[allow(unused)]
pub(crate) fn calculate_chunk_overhead(output_len: usize) -> usize {
    // The + 1 and floor() is to make even powers of 16 right.
    // The + 4 is for the \r\n overhead.
    //
    // A chunk is with length is:
    // <digits_in_hex>\r\n
    // <chunk>\r\n
    //
    // And an end/0-sized chunk is:
    // 0\r\n
    // \r\n
    ((output_len as f64).log(16.0) + 1.0).floor() as usize + 4
}

pub(crate) fn calculate_max_input(output_len: usize) -> usize {
    let chunks = output_len / DEFAULT_CHUNK_AND_OVERHEAD;
    let remaining = output_len % DEFAULT_CHUNK_AND_OVERHEAD;

    // We can safely assume remaining is < DEFAULT_CHUNK_AND_OVERHEAD which requires
    // DEFAULT_CHUNK_HEX number of chars to write. Thus whatever the remaining length is,
    // it will fit into DEFAULT_CHUNK_HEX + 4 (for the \r\n overhead)
    let tail = remaining.saturating_sub(DEFAULT_CHUNK_OVERHEAD);

    chunks * DEFAULT_CHUNK_SIZE + tail
}

fn write_chunk(input: &[u8], input_used: &mut usize, w: &mut Writer, max_chunk: usize) -> bool {
    // TODO(martin): Redo this to  try and calculate a perfect fit of the
    // input into the output.

    // 5 is the smallest possible overhead
    let available = w.available().saturating_sub(5);

    let to_write = input.len().min(max_chunk).min(available);

    let success = w.try_write(|w| {
        // chunk length
        write!(w, "{:0x?}\r\n", to_write)?;

        // chunk
        w.write_all(&input[..to_write])?;

        // chunk end
        write!(w, "\r\n")
    });

    if success {
        *input_used += to_write;
    }

    // write another chunk?
    success && input.len() > to_write
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum BodyReader {
    /// No body is expected either due to the status or method.
    NoBody,
    /// Delimited by content-length.
    /// The value is what's left to receive.
    LengthDelimited(u64),
    /// Chunked transfer encoding
    Chunked(Dechunker),
    /// Expect remote to close at end of body.
    #[cfg(feature = "client")]
    CloseDelimited,
}

/// Kind of body
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BodyMode {
    /// No body is expected either due to the status or method.
    NoBody,
    /// Delimited by content-length.
    /// The value is what's left to receive.
    LengthDelimited(u64),
    /// Chunked transfer encoding
    Chunked,
    /// Expect remote to close at end of body.
    CloseDelimited,
}

impl BodyReader {
    pub fn body_mode(&self) -> BodyMode {
        match self {
            BodyReader::NoBody => BodyMode::NoBody,
            // TODO(martin): if we read body_mode at the wrong time, this v is
            // not the total length, but the the remaining.
            BodyReader::LengthDelimited(v) => BodyMode::LengthDelimited(*v),
            BodyReader::Chunked(_) => BodyMode::Chunked,
            #[cfg(feature = "client")]
            BodyReader::CloseDelimited => BodyMode::CloseDelimited,
        }
    }

    #[cfg(feature = "server")]
    pub fn has_body(&self) -> bool {
        match self {
            BodyReader::NoBody => false,
            BodyReader::LengthDelimited(v) if *v == 0 => false,
            _ => true,
        }
    }

    #[cfg(feature = "server")]
    pub fn for_request<'a>(
        http10: bool,
        method: &Method,
        force_send: bool,
        header_lookup: &'a dyn Fn(http::HeaderName) -> Option<&'a str>,
    ) -> Result<Self, Error> {
        use crate::ext::MethodExt;

        if !method.allow_request_body() && !force_send {
            return Ok(Self::NoBody);
        }

        let ret = Self::header_defined(http10, header_lookup)?.unwrap_or_else(|| {
            if !http10 && method.need_request_body() {
                Self::Chunked(Dechunker::new())
            } else {
                Self::NoBody
            }
        });

        Ok(ret)
    }

    #[cfg(feature = "client")]
    // https://datatracker.ietf.org/doc/html/rfc2616#section-4.3
    pub fn for_response<'a>(
        http10: bool,
        method: &Method,
        status_code: u16,
        force_recv: bool,
        header_lookup: &'a dyn Fn(HeaderName) -> Option<&'a str>,
    ) -> Result<Self, Error> {
        let header_defined =
            Self::header_defined(http10, header_lookup)?.unwrap_or(Self::CloseDelimited);

        // Is body mode being defined in headers?
        let body_mode_defined = header_defined.body_mode() != BodyMode::CloseDelimited;

        // Are we allowed to receive a body?
        let body_allowed = response_body_allowed(method, status_code, header_defined.body_mode());

        if body_mode_defined && (body_allowed || force_recv) {
            // Response contains a body header (even Content-Length: 0)
            // and expects a body or is forcing a body.
            Ok(header_defined)
        } else if !body_mode_defined && body_allowed {
            // Response has no body header but a body might follow.
            // Assume close-delimited body.
            Ok(header_defined)
        } else {
            Ok(Self::NoBody)
        }
    }

    fn header_defined<'a>(
        http10: bool,
        header_lookup: &'a dyn Fn(HeaderName) -> Option<&'a str>,
    ) -> Result<Option<Self>, Error> {
        let mut content_length: Option<u64> = None;
        let mut chunked = false;

        // for head in headers {
        if let Some(value) = header_lookup(header::CONTENT_LENGTH) {
            let v = value
                .parse::<u64>()
                .map_err(|_| Error::BadContentLengthHeader)?;
            if content_length.is_some() {
                return Err(Error::TooManyContentLengthHeaders);
            }
            content_length = Some(v);
        }

        if let Some(value) = header_lookup(header::TRANSFER_ENCODING) {
            // Header can repeat, stop looking if we found "chunked"
            chunked = value
                .split(',')
                .map(|v| v.trim())
                .any(|v| compare_lowercase_ascii(v, "chunked"));
        }

        if chunked && !http10 {
            // https://datatracker.ietf.org/doc/html/rfc2616#section-4.4
            // Messages MUST NOT include both a Content-Length header field and a
            // non-identity transfer-coding. If the message does include a non-
            // identity transfer-coding, the Content-Length MUST be ignored.
            return Ok(Some(Self::Chunked(Dechunker::new())));
        }

        if let Some(len) = content_length {
            return Ok(Some(Self::LengthDelimited(len)));
        }

        Ok(None)
    }

    /// A request is allowed to have a body based solely upon it's method. A response,
    /// however, requires a number of factors to be examined. This function checks these
    /// factors.
    pub fn read(
        &mut self,
        src: &[u8],
        dst: &mut [u8],
        stop_on_chunk_boundary: bool,
    ) -> Result<(usize, usize), Error> {
        // unwrap is ok because we can't be in state RECV_BODY without setting it.
        let part = match self {
            BodyReader::LengthDelimited(_) => self.read_limit(src, dst),
            BodyReader::Chunked(_) => self.read_chunked(src, dst, stop_on_chunk_boundary),
            BodyReader::NoBody => return Ok((0, 0)),
            #[cfg(feature = "client")]
            BodyReader::CloseDelimited => self.read_unlimit(src, dst),
        }?;

        log_data(&src[..part.0]);

        Ok(part)
    }

    fn read_limit(&mut self, src: &[u8], dst: &mut [u8]) -> Result<(usize, usize), Error> {
        let left = match self {
            BodyReader::LengthDelimited(v) => v,
            _ => unreachable!(),
        };
        let left_usize = (*left).min(usize::MAX as u64) as usize;

        let to_read = src.len().min(dst.len()).min(left_usize);

        dst[..to_read].copy_from_slice(&src[..to_read]);

        *left -= to_read as u64;

        Ok((to_read, to_read))
    }

    fn read_chunked(
        &mut self,
        src: &[u8],
        dst: &mut [u8],
        stop_on_chunk_boundary: bool,
    ) -> Result<(usize, usize), Error> {
        let dechunker = match self {
            BodyReader::Chunked(v) => v,
            _ => unreachable!(),
        };

        let mut input_used = 0;
        let mut output_used = 0;

        loop {
            let (i, o) = dechunker.parse_input(&src[input_used..], &mut dst[output_used..])?;

            input_used += i;
            output_used += o;

            if i == 0 || input_used == src.len() || output_used == dst.len() {
                break;
            }

            if dechunker.is_ended() {
                break;
            }

            if stop_on_chunk_boundary && dechunker.is_on_chunk_boundary() {
                break;
            }
        }

        Ok((input_used, output_used))
    }

    #[cfg(feature = "client")]
    fn read_unlimit(&mut self, src: &[u8], dst: &mut [u8]) -> Result<(usize, usize), Error> {
        let to_read = src.len().min(dst.len());

        dst[..to_read].copy_from_slice(&src[..to_read]);

        Ok((to_read, to_read))
    }

    pub fn is_ended(&self) -> bool {
        match self {
            BodyReader::NoBody => true,
            BodyReader::LengthDelimited(v) => *v == 0,
            BodyReader::Chunked(v) => v.is_ended(),
            #[cfg(feature = "client")]
            BodyReader::CloseDelimited => false,
        }
    }

    #[cfg(feature = "client")]
    pub fn is_ended_chunked(&self) -> bool {
        match self {
            BodyReader::Chunked(v) => v.is_ending() || v.is_ended(),
            _ => false,
        }
    }

    pub(crate) fn is_on_chunk_boundary(&self) -> bool {
        match self {
            BodyReader::NoBody => false,
            BodyReader::LengthDelimited(_) => false,
            BodyReader::Chunked(v) => v.is_on_chunk_boundary(),
            #[cfg(feature = "client")]
            BodyReader::CloseDelimited => false,
        }
    }
}

/// A request is allowed to have a body based solely upon it's method. A response,
/// however, requires a number of factors to be examined. This function checks these
/// factors.
pub fn response_body_allowed(method: &Method, status_code: u16, body_mode: BodyMode) -> bool {
    let is_success = (200..=299).contains(&status_code);
    let is_informational = (100..=199).contains(&status_code);
    let is_redirect = (300..=399).contains(&status_code) && status_code != 304;

    // Implicitly we know that CloseDelimited means no header indicated that
    // there was a body.
    let has_body_header = body_mode != BodyMode::CloseDelimited;

    // https://datatracker.ietf.org/doc/html/rfc2616#section-4.3
    // All responses to the HEAD request method
    // MUST NOT include a message-body, even though the presence of entity-
    // header fields might lead one to believe they do.
    let body_not_allowed = method == Method::HEAD ||
            // A client MUST ignore any Content-Length or Transfer-Encoding
            // header fields received in a successful response to CONNECT.
            is_success && method == Method::CONNECT ||
            // All 1xx (informational), 204 (no content), and 304 (not modified) responses
            // MUST NOT include a message-body.
            is_informational ||
            matches!(status_code, 204 | 304) ||
            // Surprisingly, redirects may have a body. Whether they do we need to
            // check the existence of content-length or transfer-encoding headers.
            is_redirect && !has_body_header;

    !body_not_allowed
}

impl fmt::Debug for BodyReader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoBody => write!(f, "NoBody"),
            Self::LengthDelimited(arg0) => f.debug_tuple("LengthDelimited").field(arg0).finish(),
            Self::Chunked(_) => write!(f, "Chunked"),
            #[cfg(feature = "client")]
            Self::CloseDelimited => write!(f, "CloseDelimited"),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_calculate_max_input() {
        assert_eq!(calculate_max_input(0), 0);
        assert_eq!(calculate_max_input(1), 0);
        assert_eq!(calculate_max_input(2), 0);
        assert_eq!(calculate_max_input(9), 1);
        assert_eq!(calculate_max_input(10), 2);
        assert_eq!(calculate_max_input(11), 3);

        assert_eq!(calculate_max_input(10247), 10239);
        assert_eq!(calculate_max_input(10248), 10240);
        assert_eq!(calculate_max_input(10249), 10240);
        assert_eq!(calculate_max_input(10250), 10240);

        assert_eq!(calculate_max_input(10257), 10241);
        assert_eq!(calculate_max_input(10258), 10242);
        assert_eq!(calculate_max_input(10259), 10243);
    }
}
