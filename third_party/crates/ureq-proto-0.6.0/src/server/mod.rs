//! HTTP/1.1 server protocol
//!
//! Sans-IO protocol impl, which means "writing" and "reading" are made via buffers
//! rather than the Write/Read std traits.
//!
//! The [`Reply`] object attempts to encode correct HTTP/1.1 handling using
//! state variables, for example `Reply<RecvRequest>` to represent the
//! lifecycle stage where we are to receive a request.
//!
//! The states are:
//!
//! * **RecvRequest** - Receive the request, which is the method, path,
//!   version and the request headers
//! * **Send100** - If there is an `Expect: 100-continue` header, the
//!   server should send a 100 Continue response before receiving the body
//! * **RecvBody** - Receive the request body
//! * **ProvideResponse** - Prepare a response to the request
//! * **SendResponse** - Send the response status and headers
//! * **SendBody** - Send the response body
//! * **Cleanup** - Close the connection or prepare for the next request
//!
//! ```text
//!        ┌──────────────────┐
//!     ┌──│   RecvRequest    │───────────────┐
//!     │  └──────────────────┘               │
//!     │            │                        │
//!     │            │                        │
//!     │            ▼                        ▼
//!     │  ┌──────────────────┐     ┌──────────────────┐
//!     │  │     RecvBody     │◀────│     Send100      │
//!     │  └──────────────────┘     └──────────────────┘
//!     │            │                        │
//!     │            │                        │
//!     │            ▼                        │
//!     └─▶┌──────────────────┐               │
//!        │  ProvideResponse │             reject
//!        └──────────────────┘               │
//!                  │                        │
//!                  │                        │
//!                  ▼                        │
//!        ┌──────────────────┐◀──────────────┘
//!        │   SendResponse   │──┐
//!        └──────────────────┘  │
//!                  │           │
//!                  │           │
//!                  ▼           │
//!        ┌──────────────────┐  │
//!        │     SendBody     │  │
//!        └──────────────────┘  │
//!                  │           │
//!                  │           │
//!                  ▼           │
//!        ┌──────────────────┐  │
//!        │     Cleanup      │◀─┘
//!        └──────────────────┘
//! ```
//!
//! # Example
//!
//! ```
//! use ureq_proto::server::*;
//! use http::{Response, StatusCode, Version};
//!
//! // ********************************** RecvRequest
//!
//! // Create a new Reply in the RecvRequest state
//! let mut reply = Reply::new().unwrap();
//!
//! // Receive a request from the client
//! let input = b"POST /my-path HTTP/1.1\r\n\
//!     host: example.test\r\n\
//!     transfer-encoding: chunked\r\n\
//!     expect: 100-continue\r\n\
//!     \r\n";
//! let (input_used, request) = reply.try_request(input).unwrap();
//!
//! assert_eq!(input_used, 96);
//! let request = request.unwrap();
//! assert_eq!(request.uri().path(), "/my-path");
//! assert_eq!(request.method(), "POST");
//!
//! // Check if we can proceed to the next state
//! // In a real server, you would implement this method
//! // let can_proceed = reply.can_proceed();
//!
//! // Proceed to the next state
//! let reply = reply.proceed().unwrap();
//!
//! // ********************************** Send100
//!
//! // In this example, we know the next state is Send100 because
//! // the request included an "Expect: 100-continue" header.
//! // A real server needs to match on the variants.
//! let reply = match reply {
//!     RecvRequestResult::Send100(v) => v,
//!     _ => panic!(),
//! };
//!
//! // We can either accept or reject the 100-continue request
//! // Here we accept it and proceed to receiving the body
//! let mut output = vec![0_u8; 1024];
//! let (output_used, reply) = reply.accept(&mut output).unwrap();
//!
//! assert_eq!(output_used, 25);
//! assert_eq!(&output[..output_used], b"HTTP/1.1 100 Continue\r\n\r\n");
//!
//! // ********************************** RecvBody
//!
//! // Now we can receive the request body
//! let mut reply = reply;
//!
//! // Receive the body in chunks (chunked encoding format)
//! let input = b"5\r\nhello\r\n0\r\n\r\n";
//! let mut body_buffer = vec![0_u8; 1024];
//! let (input_used, output_used) = reply.read(input, &mut body_buffer).unwrap();
//!
//! assert_eq!(input_used, 15);
//! assert_eq!(output_used, 5);
//! assert_eq!(&body_buffer[..output_used], b"hello");
//!
//! // Check if the body is fully received
//! // In this example, we'll assume it is
//! assert!(reply.is_ended());
//!
//! // Proceed to providing a response
//! let reply = reply.proceed().unwrap();
//!
//! // ********************************** ProvideResponse
//!
//! // Create a response
//! let response = Response::builder()
//!     .status(StatusCode::OK)
//!     .header("content-type", "text/plain")
//!     .body(())
//!     .unwrap();
//!
//! // Provide the response and proceed to sending it
//! let mut reply = reply.provide(response).unwrap();
//!
//! // ********************************** SendResponse
//!
//! // Send the response headers
//! let output_used = reply.write(&mut output).unwrap();
//!
//! assert_eq!(&output[..output_used], b"\
//!     HTTP/1.1 200 OK\r\n\
//!     transfer-encoding: chunked\r\n\
//!     content-type: text/plain\r\n\
//!     \r\n");
//!
//! // Check if the response headers are fully sent
//! assert!(reply.is_finished());
//!
//! // Proceed to sending the response body
//! let SendResponseResult::SendBody(mut reply) = reply.proceed() else {
//!     panic!("Expected SendBody");
//! };
//!
//! // ********************************** SendBody
//!
//! // Send the response body
//! let (input_used, output_used) = reply.write(b"hello world", &mut output).unwrap();
//!
//! assert_eq!(input_used, 11);
//! assert_eq!(&output[..output_used], b"b\r\nhello world\r\n");
//!
//! // Indicate the end of the body with an empty input
//! let (input_used, output_used) = reply.write(&[], &mut output).unwrap();
//!
//! assert_eq!(input_used, 0);
//! assert_eq!(&output[..output_used], b"0\r\n\r\n");
//!
//! // Check if the body is fully sent
//! assert!(reply.is_finished());
//!
//! // ********************************** Cleanup
//!
//! // Proceed to cleanup
//! let reply = reply.proceed();
//!
//! // Check if we need to close the connection
//! if reply.must_close_connection() {
//!     // connection.close();
//! } else {
//!     // Prepare for the next request
//!     // let new_reply = Reply::new().unwrap();
//! }
//! ```

use std::fmt;
use std::io::Write;
use std::marker::PhantomData;

use amended::AmendedResponse;
use http::{Method, Response, StatusCode, Version};

use crate::body::{BodyReader, BodyWriter};
use crate::ext::{MethodExt, StatusCodeExt};
use crate::util::Writer;
use crate::{ArrayVec, CloseReason};

mod amended;

#[cfg(test)]
mod test;

/// Maximum number of headers to parse from an HTTP request.
///
/// This constant defines the upper limit on the number of headers that can be
/// parsed from an incoming HTTP request. Requests with more headers than this
/// will be rejected.
pub const MAX_REQUEST_HEADERS: usize = 128;

/// A state machine for an HTTP request/response cycle.
///
/// This type represents a state machine that transitions through various
/// states during the lifecycle of an HTTP request/response.
///
/// The type parameters are:
/// - `State`: The current state of the state machine (e.g., `RecvRequest`, `SendResponse`, etc.)
/// - `B`: The type of the response body (defaults to `()`)
///
/// See the [state graph][crate::server] in the server module documentation for a
/// visual representation of the state transitions.
pub struct Reply<State> {
    inner: Inner,
    _ph: PhantomData<State>,
}

// pub(crate) for tests to inspect state
#[derive(Debug)]
pub(crate) struct Inner {
    pub phase: ResponsePhase,
    pub state: BodyState,
    pub response: Option<AmendedResponse>,
    pub close_reason: ArrayVec<CloseReason, 4>,
    pub force_recv_body: bool,
    pub force_send_body: bool,
    pub method: Option<Method>,
    pub expect_100: bool,
    pub expect_100_reject: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum ResponsePhase {
    Status,
    Headers(usize),
    Body,
}

impl ResponsePhase {
    fn is_prelude(&self) -> bool {
        matches!(self, ResponsePhase::Status | ResponsePhase::Headers(_))
    }

    fn is_body(&self) -> bool {
        matches!(self, ResponsePhase::Body)
    }
}

#[derive(Debug, Default)]
pub(crate) struct BodyState {
    reader: Option<BodyReader>,
    writer: Option<BodyWriter>,
    stop_on_chunk_boundary: bool,
}

#[doc(hidden)]
pub mod state {
    pub(crate) trait Named {
        fn name() -> &'static str;
    }

    macro_rules! reply_state {
        ($n:tt) => {
            #[doc(hidden)]
            pub struct $n(());
            impl Named for $n {
                fn name() -> &'static str {
                    stringify!($n)
                }
            }
        };
    }

    reply_state!(RecvRequest);
    reply_state!(Send100);
    reply_state!(RecvBody);
    reply_state!(ProvideResponse);
    reply_state!(SendResponse);
    reply_state!(SendBody);
    reply_state!(Cleanup);
}
use self::state::*;

impl<S> Reply<S> {
    fn wrap(inner: Inner) -> Reply<S>
    where
        S: Named,
    {
        let wrapped = Reply {
            inner,
            _ph: PhantomData,
        };

        debug!("{:?}", wrapped);

        wrapped
    }

    #[cfg(test)]
    pub(crate) fn inner(&self) -> &Inner {
        &self.inner
    }
}

// //////////////////////////////////////////////////////////////////////////////////////////// RECV REQUEST

mod recvreq;

/// The possible states after receiving a request.
///
/// See [state graph][crate::server]
pub enum RecvRequestResult {
    /// Client is expecting a 100-continue response.
    Send100(Reply<Send100>),
    /// Receive a request body.
    RecvBody(Reply<RecvBody>),
    /// Client did not send a body.
    ProvideResponse(Reply<ProvideResponse>),
}

// //////////////////////////////////////////////////////////////////////////////////////////// SEND 100

mod send100;

/// Internal function to append a response to an existing inner state.
///
/// This function is used when transitioning from a state that has received a request
/// to a state that will send a response.
fn append_request(inner: Inner, response: Response<()>) -> Inner {
    // unwrap is ok because method is set early.
    let method_allows_body = inner.method.as_ref().unwrap().allow_request_body();
    let status_allows_body = response.status().body_allowed();

    let default_body_mode = if method_allows_body && status_allows_body {
        BodyWriter::new_chunked()
    } else {
        BodyWriter::new_none()
    };

    Inner {
        phase: inner.phase,
        state: BodyState {
            writer: Some(default_body_mode),
            ..inner.state
        },
        response: Some(AmendedResponse::new(response)),
        force_recv_body: inner.force_recv_body,
        force_send_body: inner.force_send_body,
        close_reason: inner.close_reason,
        method: inner.method,
        expect_100: inner.expect_100,
        expect_100_reject: inner.expect_100_reject,
    }
}

/// Internal function to write a status line to a writer.
///
/// This function is used when sending a response status line.
fn do_write_send_line(line: (Version, StatusCode), w: &mut Writer, end_head: bool) -> bool {
    w.try_write(|w| {
        write!(
            w,
            "{:?} {} {}\r\n{}",
            line.0,
            line.1.as_str(),
            line.1.canonical_reason().unwrap_or("Unknown"),
            if end_head { "\r\n" } else { "" }
        )
    })
}

// //////////////////////////////////////////////////////////////////////////////////////////// RECV BODY

mod provres;

// //////////////////////////////////////////////////////////////////////////////////////////// RECV BODY

mod recvbody;

// //////////////////////////////////////////////////////////////////////////////////////////// SEND RESPONSE

mod sendres;

/// The possible states after sending a response.
///
/// After sending the response headers, the reply can transition to one of two states:
/// - `SendBody`: If the response has a body that needs to be sent
/// - `Cleanup`: If the response has no body (e.g., HEAD requests, 204 responses)
///
/// See the [state graph][crate::server] for a visual representation.
pub enum SendResponseResult {
    /// Send the response body.
    SendBody(Reply<SendBody>),
    /// Proceed directly to cleanup without sending a body.
    Cleanup(Reply<Cleanup>),
}

// //////////////////////////////////////////////////////////////////////////////////////////// SEND RESPONSE

mod sendbody;

// //////////////////////////////////////////////////////////////////////////////////////////// CLEANUP

impl Reply<Cleanup> {
    /// Tell if we must close the connection.
    pub fn must_close_connection(&self) -> bool {
        self.close_reason().is_some()
    }

    /// If we are closing the connection, give a reason.
    pub fn close_reason(&self) -> Option<&'static str> {
        self.inner.close_reason.first().map(|s| s.explain())
    }
}

// ////////////////////////////////////////////////////////////////////////////////////////////

impl<State: Named> fmt::Debug for Reply<State> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Reply<{}>", State::name())
    }
}

impl fmt::Debug for ResponsePhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ResponsePhase::Status => write!(f, "SendStatus"),
            ResponsePhase::Headers(_) => write!(f, "SendHeaders"),
            ResponsePhase::Body => write!(f, "SendBody"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use http::{Response, StatusCode};
    use std::str;

    #[test]
    fn get_simple() {
        // Create a new Reply in RecvRequest state
        let mut reply = Reply::new().unwrap();

        // Simulate receiving a GET request
        let input = b"GET /page HTTP/1.1\r\n\
            host: test.local\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 40);
        assert_eq!(request.method(), "GET");
        assert_eq!(request.uri().path(), "/page");

        // Since GET has no body, we should go straight to ProvideResponse
        let reply = reply.proceed().unwrap();
        let RecvRequestResult::ProvideResponse(reply) = reply else {
            panic!("Expected ProvideResponse state");
        };

        // Create and provide a response
        let response = Response::builder()
            .status(StatusCode::OK)
            .header("content-type", "text/plain")
            .body(())
            .unwrap();

        let mut reply = reply.provide(response).unwrap();

        // Write response headers
        let mut output = vec![0_u8; 1024];
        let n = reply.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();
        assert_eq!(
            s,
            "HTTP/1.1 200 OK\r\n\
            transfer-encoding: chunked\r\n\
            content-type: text/plain\r\n\
            \r\n"
        );
    }

    #[test]
    fn post_with_100_continue() {
        // Create a new Reply
        let mut reply = Reply::new().unwrap();

        // Receive POST request with Expect: 100-continue
        let input = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n\
            expect: 100-continue\r\n\
            transfer-encoding: chunked\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 93); // Verify exact bytes consumed
        assert_eq!(request.method(), "POST");
        assert_eq!(request.uri().path(), "/upload");
        assert_eq!(request.headers().get("expect").unwrap(), "100-continue");

        // Proceed to Send100 state and handle the state transition
        let reply = reply.proceed().unwrap();
        let reply = match reply {
            RecvRequestResult::Send100(r) => r,
            _ => panic!("Expected Send100 state"),
        };

        // Accept the 100-continue request
        // Accept the 100-continue request
        let mut output = vec![0_u8; 1024];
        let (n, reply) = reply.accept(&mut output).unwrap();

        assert_eq!(&output[..n], b"HTTP/1.1 100 Continue\r\n\r\n");

        // Receive chunked body
        let mut reply = reply;
        let mut body_buf = vec![0_u8; 1024];

        // First chunk
        let input = b"5\r\nhello\r\n";
        let (input_used, output_used) = reply.read(input, &mut body_buf).unwrap();
        assert_eq!(input_used, 10);
        assert_eq!(&body_buf[..output_used], b"hello");

        // Final chunk
        let input = b"0\r\n\r\n";
        let (input_used, output_used) = reply.read(input, &mut body_buf[5..]).unwrap();
        assert_eq!(input_used, 5);
        assert_eq!(output_used, 0);

        assert!(reply.is_ended());
    }

    #[test]
    fn post_with_content_length() {
        let mut reply = Reply::new().unwrap();

        // Receive POST request with Content-Length
        let input = b"POST /data HTTP/1.1\r\n\
            host: test.local\r\n\
            content-length: 11\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 61); // Verify exact bytes consumed
        assert_eq!(request.method(), "POST");
        assert_eq!(request.uri().path(), "/data");

        // Should go to RecvBody state
        let reply = reply.proceed().unwrap();
        let mut reply = match reply {
            RecvRequestResult::RecvBody(r) => r,
            _ => panic!("Expected RecvBody state"),
        };

        // Receive fixed-length body
        let mut body_buf = vec![0_u8; 1024];
        let input = b"Hello World";
        let (input_used, output_used) = reply.read(input, &mut body_buf).unwrap();

        assert_eq!(input_used, 11);
        assert_eq!(&body_buf[..output_used], b"Hello World");
        assert!(reply.is_ended());
    }

    #[test]
    fn head_response_with_body_fails() {
        let mut reply = Reply::new().unwrap();

        // Receive HEAD request
        let input = b"HEAD /status HTTP/1.1\r\n\
            host: test.local\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 43); // Verify exact bytes consumed
        assert_eq!(request.method(), "HEAD");
        assert_eq!(request.uri().path(), "/status");

        // Go to ProvideResponse
        let reply = reply.proceed().unwrap();
        let RecvRequestResult::ProvideResponse(reply) = reply else {
            panic!("Expected ProvideResponse state");
        };

        // Provide a response
        let response = Response::builder()
            .status(StatusCode::OK)
            .header("content-length", "1000") // Even with content-length
            .body(())
            .unwrap();

        reply
            .provide(response)
            .expect_err("no body allowed on HEAD response");
    }

    #[test]
    fn head_response_with_body_and_footgun() {
        let mut reply = Reply::new().unwrap();

        // Receive HEAD request
        let input = b"HEAD /status HTTP/1.1\r\n\
            host: test.local\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 43); // Verify exact bytes consumed
        assert_eq!(request.method(), "HEAD");
        assert_eq!(request.uri().path(), "/status");

        // Go to ProvideResponse
        let reply = reply.proceed().unwrap();
        let RecvRequestResult::ProvideResponse(mut reply) = reply else {
            panic!("Expected ProvideResponse state");
        };

        // Provide a response
        let response = Response::builder()
            .status(StatusCode::OK)
            .header("content-length", "1000") // Even with content-length
            .body(())
            .unwrap();

        reply.force_send_body();
        let mut reply = reply.provide(response).unwrap();

        // Write response headers
        let mut output = vec![0_u8; 1024];
        let n = reply.write(&mut output).unwrap();

        // For HEAD requests, we send headers but no body
        let s = str::from_utf8(&output[..n]).unwrap();
        assert!(s.contains("content-length: 1000"));
        assert!(!s.contains("transfer-encoding"));
    }

    #[test]
    fn post_streaming() {
        let mut reply = Reply::new().unwrap();

        // Receive streaming POST request
        let input = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n\
            transfer-encoding: chunked\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 71);
        assert_eq!(request.method(), "POST");
        assert_eq!(request.uri().path(), "/upload");

        // Should go to RecvBody state
        let reply = reply.proceed().unwrap();
        let mut reply = match reply {
            RecvRequestResult::RecvBody(r) => r,
            _ => panic!("Expected RecvBody state"),
        };

        // Receive first chunk
        let mut body_buf = vec![0_u8; 1024];
        let input = b"5\r\nhello\r\n";
        let (input_used, output_used) = reply.read(input, &mut body_buf).unwrap();
        assert_eq!(input_used, 10);
        assert_eq!(output_used, 5);
        assert_eq!(&body_buf[..output_used], b"hello");

        // Receive final chunk
        let input = b"0\r\n\r\n";
        let (input_used, output_used) = reply.read(input, &mut body_buf[5..]).unwrap();
        assert_eq!(input_used, 5);
        assert_eq!(output_used, 0);
        assert!(reply.is_ended());
    }

    #[test]
    fn post_small_input() {
        let mut reply = Reply::new().unwrap();

        // Receive POST request headers in small chunks
        let input1 = b"POST /upload";
        let (used1, req1) = reply.try_request(input1).unwrap();
        assert_eq!(used1, 0);
        assert!(req1.is_none());

        let input2 = b"POST /upload HTTP/1.1\r\n";
        let (used2, req2) = reply.try_request(input2).unwrap();
        assert_eq!(used2, 0);
        assert!(req2.is_none());

        let input3 = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n";
        let (used3, req3) = reply.try_request(input3).unwrap();
        assert_eq!(used3, 0);
        assert!(req3.is_none());

        let input4 = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n\
            \r\n";
        let (used4, req4) = reply.try_request(input4).unwrap();
        assert_eq!(used4, 43);
        let request = req4.unwrap();
        assert_eq!(request.method(), "POST");
        assert_eq!(request.uri().path(), "/upload");
    }

    #[test]
    fn post_with_short_content_length() {
        let mut reply = Reply::new().unwrap();

        // Receive POST request with short content-length
        let input = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n\
            content-length: 2\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 62);
        assert_eq!(request.method(), "POST");

        // Should go to RecvBody state
        let reply = reply.proceed().unwrap();
        let mut reply = match reply {
            RecvRequestResult::RecvBody(r) => r,
            _ => panic!("Expected RecvBody state"),
        };

        // Try to receive more data than content-length
        let mut body_buf = vec![0_u8; 1024];
        let input = b"hello";
        let (i1, o1) = reply.read(input, &mut body_buf).unwrap();
        assert_eq!(i1, 2);
        assert_eq!(o1, 2);

        assert!(reply.is_ended());
    }

    #[test]
    fn post_streaming_too_much() {
        let mut reply = Reply::new().unwrap();

        // Receive POST request with content-length
        let input = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n\
            content-length: 5\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 62);
        assert_eq!(request.method(), "POST");

        // Should go to RecvBody state
        let reply = reply.proceed().unwrap();
        let mut reply = match reply {
            RecvRequestResult::RecvBody(r) => r,
            _ => panic!("Expected RecvBody state"),
        };

        // Try to receive more data than content-length
        let mut body_buf = vec![0_u8; 1024];
        let input = b"hello world"; // 11 bytes, but content-length is 5
        let (input_used, output_used) = reply.read(input, &mut body_buf).unwrap();
        assert_eq!(input_used, 5);
        assert_eq!(output_used, 5);
    }

    #[test]
    fn post_streaming_after_end() {
        let mut reply = Reply::new().unwrap();

        // Receive POST request with chunked encoding
        let input = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n\
            transfer-encoding: chunked\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 71);
        assert_eq!(request.method(), "POST");

        // Should go to RecvBody state
        let reply = reply.proceed().unwrap();
        let mut reply = match reply {
            RecvRequestResult::RecvBody(r) => r,
            _ => panic!("Expected RecvBody state"),
        };

        // Receive body chunks
        let mut body_buf = vec![0_u8; 1024];

        // First chunk
        let input = b"5\r\nhello\r\n";
        let (input_used, output_used) = reply.read(input, &mut body_buf).unwrap();
        assert_eq!(input_used, 10);
        assert_eq!(output_used, 5);

        // Final chunk
        let input = b"0\r\n\r\n";
        let (input_used, output_used) = reply.read(input, &mut body_buf[5..]).unwrap();
        assert_eq!(input_used, 5);
        assert_eq!(output_used, 0);
        assert!(reply.is_ended());

        // Try to receive more data after end
        let input = b"more data";
        let (i1, o1) = reply.read(input, &mut body_buf).unwrap();
        assert_eq!(i1, 0);
        assert_eq!(o1, 0);
    }

    #[test]
    fn post_with_short_body_input() {
        let mut reply = Reply::new().unwrap();

        // Receive POST request with content-length
        let input = b"POST /upload HTTP/1.1\r\n\
            host: test.local\r\n\
            content-length: 11\r\n\
            \r\n";
        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 63);
        assert_eq!(request.method(), "POST");

        // Should go to RecvBody state
        let reply = reply.proceed().unwrap();
        let mut reply = match reply {
            RecvRequestResult::RecvBody(r) => r,
            _ => panic!("Expected RecvBody state"),
        };

        // Receive body in small chunks
        let mut body_buf = vec![0_u8; 1024];

        // First chunk
        let input = b"He";
        let (input_used, output_used) = reply.read(input, &mut body_buf).unwrap();
        assert_eq!(input_used, 2);
        assert_eq!(output_used, 2);
        assert_eq!(&body_buf[..output_used], b"He");

        // Second chunk
        let input = b"llo ";
        let (input_used, output_used) = reply.read(input, &mut body_buf[2..]).unwrap();
        assert_eq!(input_used, 4);
        assert_eq!(output_used, 4);
        assert_eq!(&body_buf[..6], b"Hello ");

        // Final chunk
        let input = b"World";
        let (input_used, output_used) = reply.read(input, &mut body_buf[6..]).unwrap();
        assert_eq!(input_used, 5);
        assert_eq!(output_used, 5);
        assert_eq!(&body_buf[..11], b"Hello World");
        assert!(reply.is_ended());
    }

    #[test]
    fn non_standard_method_is_ok() {
        let mut reply = Reply::new().unwrap();

        // Try to receive request with non-standard method
        let input = b"FNORD /page HTTP/1.1\r\n\
            host: test.local\r\n\
            \r\n";

        let result = reply.try_request(input);
        assert!(result.is_ok());
    }

    #[test]
    fn ensure_reasonable_stack_sizes() {
        macro_rules! ensure {
            ($type:ty, $size:tt) => {
                let sz = std::mem::size_of::<$type>();
                assert!(
                    sz <= $size,
                    "Stack size of {} is too big {} > {}",
                    stringify!($type),
                    sz,
                    $size
                );
            };
        }

        ensure!(http::Response<()>, 300); // ~224
        ensure!(AmendedResponse, 400); // ~368
        ensure!(Inner, 600); // ~512
        ensure!(Reply<RecvRequest>, 600); // ~512
    }

    #[test]
    fn connect() {
        let mut reply = Reply::new().unwrap();

        let input = b"CONNECT example.com HTTP/1.1\r\nhost: example.com\r\n\r\n";

        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 51);
        assert_eq!(request.method(), "CONNECT");
        assert_eq!(request.uri().path(), "");

        // Should go to ProvideReponse state (content-length/transfer-encoding is ignored with CONNECT)
        let RecvRequestResult::ProvideResponse(reply) = reply.proceed().unwrap() else {
            panic!("Expected ProvideResponse state");
        };

        let response = Response::builder().status(StatusCode::OK).body(()).unwrap();

        let mut reply = reply.provide(response).unwrap();

        let mut output = vec![0_u8; 1024];
        let n = reply.write(&mut output).unwrap();

        // Response should ignore provided content-length/transfer-encoding headers
        let s = str::from_utf8(&output[..n]).unwrap();
        assert_eq!(s, "HTTP/1.1 200 OK\r\n\r\n");

        // should go to Cleanup state (content-length/transfer-encoding is ignored with CONNECT)
        let SendResponseResult::Cleanup(_reply) = reply.proceed() else {
            panic!("Expected Cleanup state")
        };
    }

    #[test]
    fn connect_read_body() {
        let mut reply = Reply::new().unwrap();
        reply.force_recv_body();

        let input =
            b"CONNECT example.com HTTP/1.1\r\nhost: example.com\r\ncontent-length: 1024\r\n\r\n";

        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 73);
        assert_eq!(request.method(), "CONNECT");
        assert_eq!(request.uri().path(), "");

        // Should go to RecvBody state (body reading footgun was enabled)
        let RecvRequestResult::RecvBody(_reply) = reply.proceed().unwrap() else {
            panic!("Expected RecvBody state");
        };
    }

    #[test]
    fn connect_send_body_fails() {
        let mut reply = Reply::new().unwrap();

        let input =
            b"CONNECT example.com HTTP/1.1\r\nhost: example.com\r\ncontent-length: 1024\r\n\r\n";

        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 73);
        assert_eq!(request.method(), "CONNECT");
        assert_eq!(request.uri().path(), "");

        // Should go to ProvideReponse state (content-length/transfer-encoding is ignored with CONNECT)
        let RecvRequestResult::ProvideResponse(reply) = reply.proceed().unwrap() else {
            panic!("Expected ProvideResponse state");
        };

        let response = Response::builder()
            .status(StatusCode::OK)
            .header("content-length", 1024)
            .body(())
            .unwrap();

        reply
            .provide(response)
            .expect_err("no body allowed on CONNECT response");
    }

    #[test]
    fn connect_send_body_with_footgun() {
        let mut reply = Reply::new().unwrap();

        let input =
            b"CONNECT example.com HTTP/1.1\r\nhost: example.com\r\ncontent-length: 1024\r\n\r\n";

        let (input_used, request) = reply.try_request(input).unwrap();
        let request = request.unwrap();

        assert_eq!(input_used, 73);
        assert_eq!(request.method(), "CONNECT");
        assert_eq!(request.uri().path(), "");

        // Should go to ProvideReponse state (content-length/transfer-encoding is ignored with CONNECT)
        let RecvRequestResult::ProvideResponse(mut reply) = reply.proceed().unwrap() else {
            panic!("Expected ProvideResponse state");
        };

        let response = Response::builder()
            .status(StatusCode::OK)
            .header("content-length", 1024)
            .body(())
            .unwrap();

        reply.force_send_body();
        let mut reply = reply.provide(response).unwrap();

        let mut output = vec![0_u8; 1024];
        let n = reply.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();
        assert_eq!(s, "HTTP/1.1 200 OK\r\ncontent-length: 1024\r\n\r\n");

        let SendResponseResult::SendBody(_reply) = reply.proceed() else {
            panic!("Expected SendBody state")
        };
    }
}
