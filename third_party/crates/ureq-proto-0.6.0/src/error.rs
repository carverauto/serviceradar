use std::fmt;

use http::{Method, StatusCode, Version};

/// Error type for ureq-proto
#[derive(Debug, PartialEq, Eq)]
#[allow(missing_docs)]
#[non_exhaustive]
pub enum Error {
    BadHeader(String),
    UnsupportedVersion,
    MethodVersionMismatch(Method, Version),
    TooManyHostHeaders,
    TooManyContentLengthHeaders,
    BadHostHeader,
    BadAuthorizationHeader,
    BadContentLengthHeader,
    OutputOverflow,
    ChunkLenNotAscii,
    ChunkLenNotANumber,
    ChunkExpectedCrLf,
    BodyContentAfterFinish,
    BodyLargerThanContentLength,
    BodyNotAllowed,
    HttpParseFail(String),
    HttpParseTooManyHeaders,
    NoLocationHeader,
    BadLocationHeader(String),
    HeadersWith100,
    BodyIsChunked,
    BadReject100Status(StatusCode),
}

impl From<httparse::Error> for Error {
    fn from(value: httparse::Error) -> Self {
        Error::HttpParseFail(value.to_string())
    }
}

impl std::error::Error for Error {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::BadHeader(v) => write!(f, "bad header: {}", v),
            Error::UnsupportedVersion => write!(f, "unsupported http version"),
            Error::MethodVersionMismatch(m, v) => {
                write!(f, "{} not valid for HTTP version {:?}", m, v)
            }
            Error::TooManyHostHeaders => write!(f, "more than one host header"),
            Error::TooManyContentLengthHeaders => write!(f, "more than one content-length header"),
            Error::BadHostHeader => write!(f, "host header is not a string"),
            Error::BadAuthorizationHeader => write!(f, "authorization header is not a string"),
            Error::BadContentLengthHeader => write!(f, "content-length header not a number"),
            Error::OutputOverflow => write!(f, "output too small to write output"),
            Error::ChunkLenNotAscii => write!(f, "chunk length is not ascii"),
            Error::ChunkLenNotANumber => write!(f, "chunk length cannot be read as a number"),
            Error::ChunkExpectedCrLf => write!(f, "chunk expected crlf as next character"),
            Error::BodyContentAfterFinish => {
                write!(f, "attempt to stream body after sending finish (&[])")
            }
            Error::BodyLargerThanContentLength => {
                write!(f, "attempt to write larger body than content-length")
            }
            Error::BodyNotAllowed => {
                write!(f, "body not allowed by method")
            }
            Error::HttpParseFail(v) => write!(f, "http parse fail: {}", v),
            Error::HttpParseTooManyHeaders => write!(f, "http parse resulted in too many headers"),
            Error::NoLocationHeader => write!(f, "missing a location header"),
            Error::BadLocationHeader(v) => write!(f, "location header is malformed: {}", v),
            Error::HeadersWith100 => write!(f, "received headers with 100-continue response"),
            Error::BodyIsChunked => write!(f, "body is chunked"),
            Error::BadReject100Status(v) => {
                write!(f, "expect-100 must be rejected with 4xx or 5xx: {}", v)
            }
        }
    }
}

#[cfg(test)]
#[cfg(feature = "client")]
mod tests_client {
    use super::*;
    use crate::client::{
        Call, RecvResponseResult, RedirectAuthHeaders, SendRequestResult,
        state::{RecvResponse, Redirect, SendBody, SendRequest},
    };
    use http::{HeaderValue, Method, Request, Version};

    // Helper methods to reduce test verbosity

    /// Creates a Call object from a request and proceeds to the initial state
    fn setup_call(req: Request<()>) -> (Call<SendRequest>, Vec<u8>) {
        let call = Call::new(req).unwrap();
        let call = call.proceed();
        let output = vec![0; 1024];
        (call, output)
    }

    /// Creates a Call object and proceeds to the RecvResponse state
    fn setup_recv_response_call() -> (Call<RecvResponse>, Vec<u8>) {
        let req = Request::get("http://example.com").body(()).unwrap();
        let (mut call, mut output) = setup_call(req);

        // Write the request headers
        call.write(&mut output).unwrap();

        // Proceed to RecvResponse
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::RecvResponse(call) = call else {
            panic!("Expected SendRequestResult::RecvResponse");
        };

        (call, output)
    }

    /// Creates a Call object and proceeds to the SendBody state
    fn setup_send_body_call(req: Request<()>) -> (Call<SendBody>, Vec<u8>, usize) {
        let (mut call, mut output) = setup_call(req);

        // Write the request headers
        let n = call.write(&mut output).unwrap();

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(call) = call else {
            panic!("Expected SendBody");
        };

        (call, output, n)
    }

    /// Creates a Call object and proceeds to the Redirect state with the given response
    fn setup_redirect_call(response: &[u8]) -> Result<(Call<Redirect>, Vec<u8>), Error> {
        let (mut call, output) = setup_recv_response_call();

        // Try to parse the response
        let (_, _) = call.try_response(response, false)?;

        // Proceed to Redirect state
        let RecvResponseResult::Redirect(call) = call.proceed().unwrap() else {
            panic!("Expected RecvResponseResult::Redirect");
        };

        Ok((call, output))
    }

    // BadHeader
    #[test]
    fn test_bad_header() {
        // Create a request
        let req = Request::get("http://example.com").body(()).unwrap();
        let mut call = Call::new(req).unwrap();

        // Try to set an invalid header using the Call API
        let result = call.header("Invalid\0Header", "value");

        // Verify that it returns a BadHeader error
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, Error::BadHeader(_)));
    }

    // UnsupportedVersion
    #[test]
    fn test_unsupported_version() {
        // Create a request with HTTP/2.0 which is not supported by the Call API
        let req = Request::builder()
            .uri("http://example.com")
            .version(Version::HTTP_2)
            .body(())
            .unwrap();

        let (mut call, mut output) = setup_call(req);

        // Try to write the request headers
        let err = call.write(&mut output).unwrap_err();

        assert!(matches!(err, Error::UnsupportedVersion));
    }

    // MethodVersionMismatch
    #[test]
    fn test_method_version_mismatch() {
        // TRACE method is not valid for HTTP/1.0
        let m = Method::from_bytes(b"TRACE").unwrap();
        let req = Request::builder()
            .method(m.clone())
            .uri("http://example.com")
            .version(Version::HTTP_10)
            .body(())
            .unwrap();

        let (mut call, mut output) = setup_call(req);

        // Try to write the request headers
        let err = call.write(&mut output).unwrap_err();

        assert!(matches!(err, Error::MethodVersionMismatch(_, _)));
        if let Error::MethodVersionMismatch(method, version) = err {
            assert_eq!(method, m);
            assert_eq!(version, Version::HTTP_10);
        }
    }

    // TooManyHostHeaders
    #[test]
    fn test_too_many_host_headers() {
        // Create a request with two Host headers
        let req = Request::builder()
            .uri("http://example.com")
            .header("Host", "example.com")
            .header("Host", "another-example.com")
            .body(())
            .unwrap();

        let (mut call, mut output) = setup_call(req);

        // Try to write the request headers
        let err = call.write(&mut output).unwrap_err();

        // Verify that it returns a TooManyHostHeaders error
        assert!(matches!(err, Error::TooManyHostHeaders));
    }

    // TooManyContentLengthHeaders
    #[test]
    fn test_too_many_content_length_headers() {
        // Create a request with two Content-Length headers
        let req = Request::builder()
            .uri("http://example.com")
            .header("Content-Length", "10")
            .header("Content-Length", "20")
            .body(())
            .unwrap();

        let (mut call, mut output) = setup_call(req);

        // Try to write the request headers
        let err = call.write(&mut output).unwrap_err();

        // Verify that it returns a TooManyContentLengthHeaders error
        assert!(matches!(err, Error::TooManyContentLengthHeaders));
    }

    // BadHostHeader
    #[test]
    fn test_bad_host_header() {
        // Create a request with an invalid Host header value (non-UTF8 bytes)
        let req = Request::builder()
            .uri("http://example.com")
            .header("Host", HeaderValue::from_bytes(&[0xFF, 0xFE]).unwrap())
            .body(())
            .unwrap();

        let (mut call, mut output) = setup_call(req);

        // Try to write the request headers
        let err = call.write(&mut output).unwrap_err();

        // Verify that it returns a BadHostHeader error
        assert!(matches!(err, Error::BadHostHeader));
    }

    // BadAuthorizationHeader
    #[test]
    fn test_bad_authorization_header() {
        // Create a request with an invalid Authorization header value (non-UTF8 bytes)
        let req = Request::builder()
            .uri("http://example.com")
            .header(
                "Authorization",
                HeaderValue::from_bytes(&[0xFF, 0xFE]).unwrap(),
            )
            .body(())
            .unwrap();

        let (mut call, mut output) = setup_call(req);

        // Try to write the request headers
        let err = call.write(&mut output).unwrap_err();

        // Verify that it returns a BadAuthorizationHeader error
        assert!(matches!(err, Error::BadAuthorizationHeader));
    }

    // BadContentLengthHeader
    #[test]
    fn test_bad_content_length_header() {
        // Create a request with an invalid Content-Length header value (not a number)
        let req = Request::builder()
            .uri("http://example.com")
            .header("Content-Length", "not-a-number")
            .body(())
            .unwrap();

        let (mut call, mut output) = setup_call(req);

        // Try to write the request headers
        let err = call.write(&mut output).unwrap_err();

        // Verify that it returns a BadContentLengthHeader error
        assert!(matches!(err, Error::BadContentLengthHeader));
    }

    // OutputOverflow
    #[test]
    fn test_output_overflow() {
        // Create a request with a long header
        let req = Request::builder()
            .uri("http://example.com")
            .header("x-long-header", "a".repeat(100))
            .body(())
            .unwrap();

        let (mut call, _) = setup_call(req);

        // Try to write to a very small output buffer
        let mut tiny_output = vec![0; 10];
        let err = call.write(&mut tiny_output).unwrap_err();

        assert!(matches!(err, Error::OutputOverflow));
    }

    /// Tests a chunked encoding error with the given chunk data
    fn test_chunk_error(chunk_data: &[u8]) -> Error {
        let (mut call, mut output) = setup_recv_response_call();

        const RES_PREFIX: &[u8] = b"HTTP/1.1 200 OK\r\n\
                Transfer-Encoding: chunked\r\n\
                \r\n";

        call.try_response(RES_PREFIX, false).unwrap();

        let RecvResponseResult::RecvBody(mut call) = call.proceed().unwrap() else {
            panic!("Expected RecvResponseResult::RecvBody");
        };

        call.read(chunk_data, &mut output).unwrap_err()
    }

    // ChunkLenNotAscii
    #[test]
    fn test_chunk_len_not_ascii() {
        let err = test_chunk_error(b"\xFF\r\ndata\r\n");
        assert!(matches!(err, Error::ChunkLenNotAscii));
    }

    // ChunkLenNotANumber
    #[test]
    fn test_chunk_len_not_a_number() {
        let err = test_chunk_error(b"xyz\r\ndata\r\n");
        assert!(matches!(err, Error::ChunkLenNotANumber));
    }

    // ChunkExpectedCrLf
    #[test]
    fn test_chunk_expected_crlf() {
        let err = test_chunk_error(b"5abcdefghijabcdefghijabcdefghij\r\n");
        assert!(matches!(err, Error::ChunkExpectedCrLf));
    }

    // BodyContentAfterFinish
    #[test]
    fn test_body_content_after_finish() {
        // Create a POST request
        let req = Request::post("http://example.com").body(()).unwrap();

        let (mut call, mut output, n) = setup_send_body_call(req);

        // Write some data
        let (_, n2) = call.write(b"data", &mut output[n..]).unwrap();

        // Finish the body
        let (_, n3) = call.write(&[], &mut output[n + n2..]).unwrap();

        // Try to write more data after finishing
        let err = call
            .write(b"more data", &mut output[n + n2 + n3..])
            .unwrap_err();
        assert!(matches!(err, Error::BodyContentAfterFinish));
    }

    // BodyLargerThanContentLength
    #[test]
    fn test_body_larger_than_content_length() {
        // Create a request with a content-length header
        let req = Request::post("http://example.com")
            .header("content-length", "5")
            .body(())
            .unwrap();

        let (mut call, mut output, n) = setup_send_body_call(req);

        // Try to write more data than specified in content-length
        let err = call.write(b"too much data", &mut output[n..]).unwrap_err();
        assert!(matches!(err, Error::BodyLargerThanContentLength));
    }

    // HttpParseFail
    #[test]
    fn test_http_parse_fail() {
        let (mut call, _) = setup_recv_response_call();

        // Invalid HTTP response (missing space after HTTP/1.1)
        const RES: &[u8] = b"HTTP/1.1200 OK\r\n\r\n";

        let err = call.try_response(RES, false).unwrap_err();

        assert!(matches!(err, Error::HttpParseFail(_)));
    }

    // HttpParseTooManyHeaders
    #[test]
    fn test_http_parse_too_many_headers() {
        let (mut call, _) = setup_recv_response_call();

        // Create a response with many headers (more than the parser can handle)
        let mut res = String::from("HTTP/1.1 200 OK\r\n");
        for i in 0..1000 {
            res.push_str(&format!("X-Header-{}: value\r\n", i));
        }
        res.push_str("\r\n");

        let err = call.try_response(res.as_bytes(), false).unwrap_err();

        assert!(matches!(err, Error::HttpParseTooManyHeaders));
    }

    // NoLocationHeader
    #[test]
    fn test_no_location_header() {
        // Redirect response without a Location header
        const RES: &[u8] = b"HTTP/1.1 302 Found\r\n\
            \r\n";

        let (mut call, _) = setup_redirect_call(RES).unwrap();

        // Try to create a new Call, which should fail due to missing Location header
        let err = call.as_new_call(RedirectAuthHeaders::Never).unwrap_err();

        assert!(matches!(err, Error::NoLocationHeader));
    }

    // BadLocationHeader
    #[test]
    fn test_bad_location_header() {
        // Redirect response with a malformed Location header
        const RES: &[u8] = b"HTTP/1.1 302 Found\r\n\
            Location: \xFF\r\n\
            \r\n";

        let (mut call, _) = setup_redirect_call(RES).unwrap();

        // Try to create a new Call, which should fail due to malformed Location header
        let err = call.as_new_call(RedirectAuthHeaders::Never).unwrap_err();

        assert!(matches!(err, Error::BadLocationHeader(_)));
    }

    // HeadersWith100
    #[test]
    fn test_headers_with_100() {
        let (mut call, _) = setup_recv_response_call();

        // 100 Continue response with headers
        const RES: &[u8] = b"HTTP/1.1 100 Continue\r\n\
            Content-Type: text/plain\r\n\
            \r\n";

        let err = call.try_response(RES, false).unwrap_err();

        assert!(matches!(err, Error::HeadersWith100));
    }

    // BodyIsChunked
    #[test]
    fn test_body_is_chunked() {
        // Create a request with chunked transfer encoding
        let req = Request::post("http://example.com")
            .header("transfer-encoding", "chunked")
            .body(())
            .unwrap();

        let (mut call, _, _) = setup_send_body_call(req);

        // Try to use consume_direct_write which doesn't work with chunked encoding
        let err = call.consume_direct_write(5).unwrap_err();
        assert!(matches!(err, Error::BodyIsChunked));
    }

    // Test the From<httparse::Error> implementation
    #[test]
    fn test_from_httparse_error() {
        let httparse_error = httparse::Error::HeaderName;
        let error: Error = httparse_error.into();
        assert!(matches!(error, Error::HttpParseFail(_)));
        let Error::HttpParseFail(_) = error else {
            panic!("Not Error::HttpParseFail");
        };
    }
}
