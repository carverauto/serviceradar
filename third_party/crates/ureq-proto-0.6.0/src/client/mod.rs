//! HTTP/1.1 client protocol
//!
//! Sans-IO protocol impl, which means "writing" and "reading" are made via buffers
//! rather than the Write/Read std traits.
//!
//! The [`Call`] object attempts to encode correct HTTP/1.1 handling using
//! state variables, for example `Call<'a, SendRequest>` to represent the
//! lifecycle stage where we are to send the request.
//!
//! The states are:
//!
//! * **Prepare** - Preparing a request means 1) adding headers such as
//!   cookies. 2) acquiring the connection from a pool or opening a new
//!   socket (potentially wrappping in TLS)
//! * **SendRequest** - Send the first row, which is the method, path
//!   and version as well as the request headers
//! * **SendBody** - Send the request body
//! * **Await100** - If there is an `Expect: 100-continue` header, the
//!   client should pause before sending the body
//! * **RecvResponse** - Receive the response, meaning the status and
//!   version and the response headers
//! * **RecvBody** - Receive the response body
//! * **Redirect** - Handle redirects, potentially spawning new requests
//! * **Cleanup** - Return the connection to the pool or close it
//!
//!
//! ```text
//!                            ┌──────────────────┐
//! ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ▶│     Prepare      │
//!                            └──────────────────┘
//! │                                    │
//!                                      ▼
//! │                          ┌──────────────────┐
//!                         ┌──│   SendRequest    │──────────────┐
//! │                       │  └──────────────────┘              │
//!                         │            │                       │
//! │                       │            ▼                       ▼
//!                         │  ┌──────────────────┐    ┌──────────────────┐
//! │                       │  │     SendBody     │◀───│     Await100     │
//!                         │  └──────────────────┘    └──────────────────┘
//! │                       │            │                       │
//!                         │            ▼                       │
//! │                       └─▶┌──────────────────┐◀─────────────┘
//!              ┌─────────────│   RecvResponse   │──┐
//! │            │             └──────────────────┘  │
//!              │                       │           │
//! │            ▼                       ▼           │
//!    ┌──────────────────┐    ┌──────────────────┐  │
//! └ ─│     Redirect     │◀───│     RecvBody     │  │
//!    └──────────────────┘    └──────────────────┘  │
//!              │                       │           │
//!              │                       ▼           │
//!              │             ┌──────────────────┐  │
//!              └────────────▶│     Cleanup      │◀─┘
//!                            └──────────────────┘
//! ```
//!
//! # Example
//!
//! ```
//! use ureq_proto::client::*;
//! use ureq_proto::http::Request;
//!
//! let request = Request::put("https://example.test/my-path")
//!     .header("Expect", "100-continue")
//!     .header("x-foo", "bar")
//!     .body(())
//!     .unwrap();
//!
//! // ********************************** Prepare
//!
//! let mut call = Call::new(request).unwrap();
//!
//! // Prepare with state from cookie jar. The uri
//! // is used to key the cookies.
//! let uri = call.uri();
//!
//! // call.header("Cookie", "my_cookie1=value1");
//! // call.header("Cookie", "my_cookie2=value2");
//!
//! // Obtain a connection for the uri, either a
//! // pooled connection from a previous http/1.1
//! // keep-alive, or open a new. The connection
//! // must be TLS wrapped if the scheme so indicate.
//! // let connection = todo!();
//!
//! // Sans-IO means it does not use any
//! // Write trait or similar. Requests and request
//! // bodies are written to a buffer that in turn
//! // should be sent via the connection.
//! let mut output = vec![0_u8; 1024];
//!
//! // ********************************** SendRequest
//!
//! // Proceed to the next state writing the request.
//! let mut call = call.proceed();
//!
//! let output_used = call.write(&mut output).unwrap();
//! assert_eq!(output_used, 107);
//!
//! assert_eq!(&output[..output_used], b"\
//!     PUT /my-path HTTP/1.1\r\n\
//!     host: example.test\r\n\
//!     transfer-encoding: chunked\r\n\
//!     expect: 100-continue\r\n\
//!     x-foo: bar\r\n\
//!     \r\n");
//!
//! // Check we can continue to send the body
//! assert!(call.can_proceed());
//!
//! // ********************************** Await100
//!
//! // In this example, we know the next state is Await100.
//! // A real client needs to match on the variants.
//! let mut call = match call.proceed() {
//!     Ok(Some(SendRequestResult::Await100(v))) => v,
//!     _ => panic!(),
//! };
//!
//! // When awaiting 100, the client should run a timer and
//! // proceed to sending the body either when the server
//! // indicates it can receive the body, or the timer runs out.
//!
//! // This boolean can be checked whether there's any point
//! // in keeping waiting for the timer to run out.
//! assert!(call.can_keep_await_100());
//!
//! let input = b"HTTP/1.1 100 Continue\r\n\r\n";
//! let input_used = call.try_read_100(input).unwrap();
//!
//! assert_eq!(input_used, 25);
//! assert!(!call.can_keep_await_100());
//!
//! // ********************************** SendBody
//!
//! // Proceeding is possible regardless of whether the
//! // can_keep_await_100() is true or false.
//! // A real client needs to match on the variants.
//! let mut call = match call.proceed() {
//!     Ok(Await100Result::SendBody(v)) => v,
//!     _ => panic!(),
//! };
//!
//! let (input_used, o1) =
//!     call.write(b"hello", &mut output).unwrap();
//!
//! assert_eq!(input_used, 5);
//!
//! // When doing transfer-encoding: chunked,
//! // the end of body must be signaled with
//! // an empty input. This is also valid for
//! // regular content-length body.
//! assert!(!call.can_proceed());
//!
//! let (_, o2) = call.write(&[], &mut output[o1..]).unwrap();
//!
//! let output_used = o1 + o2;
//! assert_eq!(output_used, 15);
//!
//! assert_eq!(&output[..output_used], b"\
//!     5\r\n\
//!     hello\
//!     \r\n\
//!     0\r\n\
//!     \r\n");
//!
//! assert!(call.can_proceed());
//!
//! // ********************************** RecvRequest
//!
//! // Proceed to read the request.
//! let mut call = call.proceed().unwrap();
//!
//! let part = b"HTTP/1.1 200 OK\r\nContent-Len";
//! let full = b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n";
//!
//! // try_response can be used repeatedly until we
//! // get enough content including all headers.
//! let (input_used, maybe_response) =
//!     call.try_response(part, false).unwrap();
//!
//! assert_eq!(input_used, 0);
//! assert!(maybe_response.is_none());
//!
//! let (input_used, maybe_response) =
//!     call.try_response(full, false).unwrap();
//!
//! assert_eq!(input_used, 38);
//! let response = maybe_response.unwrap();
//!
//! // ********************************** RecvBody
//!
//! // It's not possible to proceed until we
//! // have read a response.
//! let mut call = match call.proceed() {
//!     Some(RecvResponseResult::RecvBody(v)) => v,
//!     _ => panic!(),
//! };
//!
//! let(input_used, output_used) =
//!     call.read(b"hi there!", &mut output).unwrap();
//!
//! assert_eq!(input_used, 9);
//! assert_eq!(output_used, 9);
//!
//! assert_eq!(&output[..output_used], b"hi there!");
//!
//! // ********************************** Cleanup
//!
//! let call = match call.proceed() {
//!     Some(RecvBodyResult::Cleanup(v)) => v,
//!     _ => panic!(),
//! };
//!
//! if call.must_close_connection() {
//!     // connection.close();
//! } else {
//!     // connection.return_to_pool();
//! }
//!
//! ```

use std::fmt;
use std::marker::PhantomData;

use http::{HeaderValue, StatusCode};

use crate::CloseReason;
use crate::body::{BodyReader, BodyWriter};
use crate::util::ArrayVec;

use amended::AmendedRequest;

mod amended;

// mod holder;

#[cfg(test)]
mod test;

/// Max number of headers to parse from an HTTP response
pub const MAX_RESPONSE_HEADERS: usize = 128;

/// State types for the Call state machine.
///
/// These types are used as type parameters to `Call<B, State>` to represent
/// the current state of the HTTP request/response state machine.
pub mod state {
    pub(crate) trait Named {
        fn name() -> &'static str;
    }

    macro_rules! call_state {
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

    call_state!(Prepare);
    call_state!(SendRequest);
    call_state!(Await100);
    call_state!(SendBody);
    call_state!(RecvResponse);
    call_state!(RecvBody);
    call_state!(Redirect);
    call_state!(Cleanup);
}
use self::state::*;

/// A state machine for an HTTP request/response cycle.
///
/// This type represents a state machine that transitions through various
/// states during the lifecycle of an HTTP request/response.
///
/// The type parameters are:
/// - `State`: The current state of the state machine (e.g., `Prepare`, `SendRequest`, etc.)
///
/// See the [state graph][crate::client] in the client module documentation for a
/// visual representation of the state transitions.
pub struct Call<State> {
    inner: Inner,
    _ph: PhantomData<State>,
}

/// Internal state of a Call.
///
/// This struct contains the actual state data for a Call, independent of the
/// state type parameter. It's exposed as pub(crate) to allow tests to inspect
/// the state.
#[derive(Debug)]
pub(crate) struct Inner {
    pub request: AmendedRequest,
    pub analyzed: bool,
    pub state: BodyState,
    pub close_reason: ArrayVec<CloseReason, 4>,
    pub force_recv_body: bool,
    pub force_send_body: bool,
    pub await_100_continue: bool,
    pub status: Option<StatusCode>,
    pub location: Option<HeaderValue>,
}

impl Inner {
    fn is_redirect(&self) -> bool {
        match self.status {
            // 304 is a redirect code, but it has no location header and
            // thus we don't consider it a redirection.
            Some(v) => v.is_redirection() && v != StatusCode::NOT_MODIFIED,
            None => false,
        }
    }
}

/// State of the request/response body.
///
/// This struct tracks the current phase of the request/response cycle
/// and manages the body writers and readers.
#[derive(Debug, Default)]
pub(crate) struct BodyState {
    phase: RequestPhase,
    writer: BodyWriter,
    reader: Option<BodyReader>,
    allow_non_standard_methods: bool,
    stop_on_chunk_boundary: bool,
}

impl BodyState {
    fn need_response_body(&self) -> bool {
        !matches!(
            self.reader,
            Some(BodyReader::NoBody) | Some(BodyReader::LengthDelimited(0))
        )
    }
}

/// Phases of sending an HTTP request.
///
/// This enum represents the different phases of sending an HTTP request:
/// - `SendLine`: Sending the request line (method, path, version)
/// - `SendHeaders`: Sending the request headers
/// - `SendBody`: Sending the request body
#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum RequestPhase {
    #[default]
    Line,
    Headers(usize),
    Body,
}

impl RequestPhase {
    fn is_prelude(&self) -> bool {
        matches!(self, RequestPhase::Line | RequestPhase::Headers(_))
    }

    fn is_body(&self) -> bool {
        matches!(self, RequestPhase::Body)
    }
}

impl<S> Call<S> {
    fn wrap(inner: Inner) -> Call<S>
    where
        S: Named,
    {
        let wrapped = Call {
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

// //////////////////////////////////////////////////////////////////////////////////////////// PREPARE

mod prepare;

// //////////////////////////////////////////////////////////////////////////////////////////// SEND REQUEST

mod sendreq;

/// Possible state transitions after sending a request.
///
/// After sending the request headers, the call can transition to one of three states:
/// - `Await100`: If the request included an `Expect: 100-continue` header
/// - `SendBody`: If the request has a body to send
/// - `RecvResponse`: If the request has no body (e.g., GET, HEAD)
///
/// See the [state graph][crate::client] for a visual representation.
pub enum SendRequestResult {
    /// Expect-100/Continue mechanic.
    Await100(Call<Await100>),

    /// Send the request body.
    SendBody(Call<SendBody>),

    /// Receive the response.
    RecvResponse(Call<RecvResponse>),
}

// //////////////////////////////////////////////////////////////////////////////////////////// AWAIT 100

mod await100;

/// Possible state transitions after awaiting a 100 Continue response.
///
/// After awaiting a 100 Continue response, the call can transition to one of two states:
/// - `SendBody`: If the server sent a 100 Continue response or the timeout expired
/// - `RecvResponse`: If the server sent a different response
///
/// See the [state graph][crate::client] for a visual representation.
pub enum Await100Result {
    /// Send the request body.
    SendBody(Call<SendBody>),

    /// Receive server response.
    RecvResponse(Call<RecvResponse>),
}

// //////////////////////////////////////////////////////////////////////////////////////////// SEND BODY

mod sendbody;

// //////////////////////////////////////////////////////////////////////////////////////////// RECV RESPONSE

mod recvresp;

/// Possible state transitions after receiving a response.
///
/// After receiving a response (status and headers), the call can transition to one of three states:
/// - `RecvBody`: If the response has a body to receive
/// - `Redirect`: If the response is a redirect
/// - `Cleanup`: If the response has no body and is not a redirect
///
/// See the [state graph][crate::client] for a visual representation.
pub enum RecvResponseResult {
    /// Receive a response body.
    RecvBody(Call<RecvBody>),

    /// Follow a redirect.
    Redirect(Call<Redirect>),

    /// Run cleanup.
    Cleanup(Call<Cleanup>),
}

// //////////////////////////////////////////////////////////////////////////////////////////// RECV BODY

mod recvbody;

/// Possible state transitions after receiving a response body.
///
/// After receiving a response body, the call can transition to one of two states:
/// - `Redirect`: If the response is a redirect
/// - `Cleanup`: If the response is not a redirect
///
/// See the [state graph][crate::client] for a visual representation.
pub enum RecvBodyResult {
    /// Follow a redirect
    Redirect(Call<Redirect>),

    /// Go to cleanup
    Cleanup(Call<Cleanup>),
}

// //////////////////////////////////////////////////////////////////////////////////////////// REDIRECT

mod redirect;

/// Strategy for preserving authorization headers during redirects.
///
/// This enum defines how authorization headers should be handled when following
/// redirects:
///
/// * `Never`: Never preserve the `authorization` header in redirects. This is the default.
/// * `SameHost`: Preserve the `authorization` header when the redirect is to the same host
///   and uses the same scheme (or switches to a more secure one, i.e., from HTTP to HTTPS,
///   but not the reverse).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum RedirectAuthHeaders {
    /// Never preserve the `authorization` header on redirect. This is the default.
    Never,
    /// Preserve the `authorization` header when the redirect is to the same host. Both hosts must use
    /// the same scheme (or switch to a more secure one, i.e we can redirect from `http` to `https`,
    /// but not the reverse).
    SameHost,
}

// //////////////////////////////////////////////////////////////////////////////////////////// CLEANUP

impl Call<Cleanup> {
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

impl<State: Named> fmt::Debug for Call<State> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Call<{}>", State::name())
    }
}

impl fmt::Debug for RequestPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Line => write!(f, "SendLine"),
            Self::Headers(_) => write!(f, "SendHeaders"),
            Self::Body => write!(f, "SendBody"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Error;
    use crate::client::Inner;
    use crate::client::amended::AmendedRequest;
    use crate::client::state::SendRequest;
    use http::{Method, Request, Version, header};
    use std::str;

    #[test]
    fn get_simple() {
        let req = Request::get("http://foo.test/page")
            .header("content-length", "0")
            .body(())
            .unwrap();

        let call = Call::new(req).unwrap();

        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();
        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(
            s,
            "GET /page HTTP/1.1\r\n\
            host: foo.test\r\n\
            content-length: 0\r\n\
            \r\n"
        );

        // Since GET has no body (explicitly defined by content-length too) we should go straight to RecvResponse
        let Ok(Some(SendRequestResult::RecvResponse(_call))) = call.proceed() else {
            panic!("Exepcted `RecvResponse`")
        };
    }

    #[test]
    fn head_simple() {
        let req = Request::head("http://foo.test/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();
        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(s, "HEAD /page HTTP/1.1\r\nhost: foo.test\r\n\r\n");
    }

    #[test]
    fn head_without_body() {
        let req = Request::head("http://foo.test/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to the next state
        let call = call.proceed().unwrap().unwrap();

        // For a HEAD request, we should get a RecvResponse result
        let SendRequestResult::RecvResponse(_) = call else {
            panic!("Expected RecvResponse")
        };
    }

    #[test]
    fn head_with_body_despite_method() {
        let req = Request::head("http://foo.fest/page")
            .header(header::TRANSFER_ENCODING, "chunked")
            .body(())
            .unwrap();

        let mut call = Call::new(req).unwrap();

        // Force sending a body despite the method
        call.force_send_body();

        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to the next state
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody")
        };

        // Write an empty body
        let (i, n) = call.write(&[], &mut output).unwrap();
        assert_eq!(i, 0);
        assert_eq!(n, 5); // "0\r\n\r\n" for chunked encoding

        // Check if we can proceed (body is fully sent)
        assert!(call.can_proceed());
    }

    #[test]
    fn post_simple() {
        let req = Request::post("http://f.test/page")
            .header("content-length", 5)
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n1 = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to the next state
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody")
        };

        // Write the body
        let (i1, n2) = call.write(b"hallo", &mut output[n1..]).unwrap();
        assert_eq!(i1, 5);

        let s = str::from_utf8(&output[..n1 + n2]).unwrap();
        assert_eq!(
            s,
            "POST /page HTTP/1.1\r\nhost: f.test\r\ncontent-length: 5\r\n\r\nhallo"
        );
    }

    #[test]
    fn post_small_output() {
        let req = Request::post("http://f.test/page")
            .header("content-length", 5)
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        let body = b"hallo";

        // Write the request headers in multiple steps with small output buffers
        {
            let n = call.write(&mut output[..25]).unwrap();
            let s = str::from_utf8(&output[..n]).unwrap();
            assert_eq!(s, "POST /page HTTP/1.1\r\n");
            assert!(!call.can_proceed());
        }

        {
            let n = call.write(&mut output[..20]).unwrap();
            let s = str::from_utf8(&output[..n]).unwrap();
            assert_eq!(s, "host: f.test\r\n");
            assert!(!call.can_proceed());
        }

        {
            let n = call.write(&mut output[..21]).unwrap();
            let s = str::from_utf8(&output[..n]).unwrap();
            assert_eq!(s, "content-length: 5\r\n\r\n");
            assert!(call.can_proceed());
        }

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody")
        };

        // Write the body
        {
            let (i, n) = call.write(body, &mut output[..25]).unwrap();
            assert_eq!(n, 5);
            assert_eq!(i, 5);
            let s = str::from_utf8(&output[..n]).unwrap();
            assert_eq!(s, "hallo");

            // Check if we can proceed (body is fully sent)
            assert!(call.can_proceed());
        }
    }

    #[test]
    fn post_with_short_content_length() {
        let req = Request::post("http://f.test/page")
            .header("content-length", 2)
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n1 = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody")
        };

        // Write the body (first write should fail because it's larger than content-length)
        let body = b"hallo";
        let r = call.write(body, &mut output[n1..]);
        assert_eq!(r.unwrap_err(), Error::BodyLargerThanContentLength);

        // Write a smaller body that fits within content-length
        let body = b"ha";
        let r = call.write(body, &mut output[n1..]);
        assert!(r.is_ok());

        // Check if we can proceed (body is fully sent)
        assert!(call.can_proceed());
    }

    #[test]
    fn post_with_short_body_input() {
        let req = Request::post("http://f.test/page")
            .header("content-length", 5)
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n1 = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody")
        };

        // Write the first part of the body
        let (i1, n2) = call.write(b"ha", &mut output[n1..]).unwrap();
        assert_eq!(i1, 2);

        // Write the second part of the body
        let (i2, n3) = call.write(b"ha", &mut output[n1 + n2..]).unwrap();
        assert_eq!(i2, 2);

        let s = str::from_utf8(&output[..n1 + n2 + n3]).unwrap();
        assert_eq!(
            s,
            "POST /page HTTP/1.1\r\nhost: f.test\r\ncontent-length: 5\r\n\r\nhaha"
        );

        // Check if we can proceed (body is not fully sent yet)
        assert!(!call.can_proceed());

        // Write the third part of the body (should fail because it's larger than remaining content length)
        let err = call.write(b"llo", &mut output[n1 + n2 + n3..]).unwrap_err();
        assert_eq!(err, Error::BodyLargerThanContentLength);

        // Write the last byte to complete the content length
        let (i3, n4) = call.write(b"l", &mut output[n1 + n2 + n3..]).unwrap();
        assert_eq!(i3, 1);

        let s = str::from_utf8(&output[..n1 + n2 + n3 + n4]).unwrap();
        assert_eq!(
            s,
            "POST /page HTTP/1.1\r\nhost: f.test\r\ncontent-length: 5\r\n\r\nhahal"
        );

        // Check if we can proceed (body is fully sent)
        assert!(call.can_proceed());
    }

    #[test]
    fn post_with_chunked() {
        let req = Request::post("http://f.test/page")
            .header("transfer-encoding", "chunked")
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n1 = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody")
        };

        let body = b"hallo";

        // Write the first chunk of the body
        let (i1, n2) = call.write(body, &mut output[n1..]).unwrap();
        assert_eq!(i1, 5);

        // Write the second chunk of the body
        let (i2, n3) = call.write(body, &mut output[n1 + n2..]).unwrap();
        assert_eq!(i2, 5);

        // Indicate the end of the body
        let (i3, n4) = call.write(&[], &mut output[n1 + n2 + n3..]).unwrap();
        assert_eq!(i3, 0);

        let s = str::from_utf8(&output[..n1 + n2 + n3 + n4]).unwrap();
        assert_eq!(
            s,
            "POST /page HTTP/1.1\r\nhost: f.test\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhallo\r\n5\r\nhallo\r\n0\r\n\r\n"
        );

        // Check if we can proceed (body is fully sent)
        assert!(call.can_proceed());
    }

    #[test]
    fn post_without_body() {
        let req = Request::post("http://foo.test/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to the next state
        let call = call.proceed().unwrap().unwrap();

        // For a POST request, we should get a SendBody result
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody");
        };

        // Check that we can't proceed without writing a body
        assert!(!call.can_proceed());

        // Write an empty body
        let (i, n) = call.write(&[], &mut output).unwrap();
        assert_eq!(i, 0);
        assert_eq!(n, 5); // "0\r\n\r\n" for chunked encoding

        // Check if we can proceed (body is fully sent)
        assert!(call.can_proceed());
    }

    #[test]
    fn post_streaming() {
        let req = Request::post("http://f.test/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n1 = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody");
        };

        // Write the first chunk of the body (using i2, n2 to match original test)
        let (i2, n2) = call.write(b"hallo", &mut output[n1..]).unwrap();

        // Send end (using i3, n3 to match original test)
        let (i3, n3) = call.write(&[], &mut output[n1 + n2..]).unwrap();

        // Use i1 = 0 to match original test (in Call API, i1 is not used for headers)
        let i1 = 0;

        // Verify the results with the same assertions as the original test
        assert_eq!(i1, 0);
        assert_eq!(i2, 5);
        assert_eq!(n1, 65);
        assert_eq!(n2, 10);
        assert_eq!(i3, 0);
        assert_eq!(n3, 5);

        let s = str::from_utf8(&output[..(n1 + n2 + n3)]).unwrap();

        assert_eq!(
            s,
            "POST /page HTTP/1.1\r\nhost: f.test\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhallo\r\n0\r\n\r\n"
        );
    }

    #[test]
    fn post_streaming_with_size() {
        let req = Request::post("http://f.test/page")
            .header("content-length", "5")
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let headers_n = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody");
        };

        // Write the body (first call)
        let (i1, n1) = call.write(b"hallo", &mut output[headers_n..]).unwrap();

        // Verify the results
        assert_eq!(i1, 5); // In Call API, i1 is the number of bytes consumed from the input
        assert_eq!(n1, 5); // In Call API, n1 is the number of bytes written to the output

        // Check if we can proceed (body is fully sent)
        assert!(call.can_proceed());

        // Try to write more data after the body is fully sent (should fail)
        let err = call
            .write(b"hallo", &mut output[headers_n + n1..])
            .unwrap_err();
        assert_eq!(err, Error::BodyContentAfterFinish);

        let s = str::from_utf8(&output[..headers_n + n1]).unwrap();

        assert_eq!(
            s,
            "POST /page HTTP/1.1\r\nhost: f.test\r\ncontent-length: 5\r\n\r\nhallo"
        );
    }

    #[test]
    fn post_streaming_after_end() {
        let req = Request::post("http://f.test/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let headers_n = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody");
        };

        // Write the body
        let (_, n1) = call.write(b"hallo", &mut output[headers_n..]).unwrap();

        // Send end
        let (_, n2) = call.write(&[], &mut output[headers_n + n1..]).unwrap();

        // Try to write after end
        let err = call.write(b"after end", &mut output[headers_n + n1 + n2..]);

        assert_eq!(err, Err(Error::BodyContentAfterFinish));
    }

    #[test]
    fn post_streaming_too_much() {
        let req = Request::post("http://f.test/page")
            .header("content-length", "5")
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let headers_n = call.write(&mut output).unwrap();

        // Check if we can proceed
        assert!(call.can_proceed());

        // Proceed to SendBody
        let call = call.proceed().unwrap().unwrap();
        let SendRequestResult::SendBody(mut call) = call else {
            panic!("Expected SendBody");
        };

        // Write the body (first call)
        let (i1, n1) = call.write(b"hallo", &mut output[headers_n..]).unwrap();

        // Verify the results
        assert_eq!(i1, 5); // In Call API, i1 is the number of bytes consumed from the input
        assert_eq!(n1, 5); // In Call API, n1 is the number of bytes written to the output

        // Check if we can proceed (body is fully sent)
        assert!(call.can_proceed());

        // Try to write more data after the body is fully sent (should fail with BodyContentAfterFinish)
        let err = call
            .write(b"hallo", &mut output[headers_n + n1..])
            .unwrap_err();
        assert_eq!(err, Error::BodyContentAfterFinish);

        let s = str::from_utf8(&output[..headers_n + n1]).unwrap();

        assert_eq!(
            s,
            "POST /page HTTP/1.1\r\nhost: f.test\r\ncontent-length: 5\r\n\r\nhallo"
        );
    }

    #[test]
    fn username_password_uri() {
        let req = Request::get("http://martin:secret@f.test/page")
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(
            s,
            "GET /page HTTP/1.1\r\nhost: f.test\r\n\
            authorization: Basic bWFydGluOnNlY3JldA==\r\n\r\n"
        );
    }

    #[test]
    fn username_uri() {
        let req = Request::get("http://martin@f.test/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(
            s,
            "GET /page HTTP/1.1\r\nhost: f.test\r\n\
            authorization: Basic bWFydGluOg==\r\n\r\n"
        );
    }

    #[test]
    fn password_uri() {
        let req = Request::get("http://:secret@f.test/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(
            s,
            "GET /page HTTP/1.1\r\nhost: f.test\r\n\
            authorization: Basic OnNlY3JldA==\r\n\r\n"
        );
    }

    #[test]
    fn override_auth_header() {
        let req = Request::get("http://martin:secret@f.test/page")
            // This should override the auth from the URI
            .header("authorization", "meh meh meh")
            .body(())
            .unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(
            s,
            "GET /page HTTP/1.1\r\nhost: f.test\r\n\
            authorization: meh meh meh\r\n\r\n"
        );
    }

    #[test]
    fn non_standard_port() {
        let req = Request::get("http://f.test:8080/page").body(()).unwrap();
        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(s, "GET /page HTTP/1.1\r\nhost: f.test:8080\r\n\r\n");
    }

    #[test]
    fn non_standard_method_not_allowed() {
        let m = Method::from_bytes(b"FNORD").unwrap();

        let req = Request::builder()
            .method(m.clone())
            .uri("http://f.test:8080/page")
            .body(())
            .unwrap();

        let call = Call::new(req).unwrap();

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Try to write the request headers
        let mut output = vec![0; 1024];
        let err = call.write(&mut output).unwrap_err();

        assert_eq!(err, Error::MethodVersionMismatch(m, Version::HTTP_11));
    }

    #[test]
    fn non_standard_method_when_allowed() {
        let m = Method::from_bytes(b"FNORD").unwrap();

        let req = Request::builder()
            .method(m.clone())
            .uri("http://f.test:8080/page")
            .body(())
            .unwrap();

        let mut call = Call::new(req).unwrap();

        // Allow non-standard methods
        call.allow_non_standard_methods(true);

        // Proceed to SendRequest
        let mut call = call.proceed();

        // Write the request headers
        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        let s = str::from_utf8(&output[..n]).unwrap();

        assert_eq!(s, "FNORD /page HTTP/1.1\r\nhost: f.test:8080\r\n\r\n");
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

        ensure!(http::Request<()>, 300); // 224
        ensure!(AmendedRequest, 400); // 368
        ensure!(Inner, 600); // 512
        ensure!(Call<SendRequest>, 600); // 512
    }

    #[test]
    fn connect() {
        let req = Request::builder()
            .method(Method::CONNECT)
            .uri("http://example.com:80")
            .body(())
            .unwrap();

        let call = Call::new(req).unwrap();
        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        // CONNECT request should have request target in authority form
        let s = str::from_utf8(&output[..n]).unwrap();
        assert_eq!(
            s,
            "CONNECT example.com:80 HTTP/1.1\r\nhost: example.com:80\r\n\r\n"
        );

        // Should go to RecvResponse state (content-length/transfer-encoding is ignored with CONNECT)
        let SendRequestResult::RecvResponse(mut call) = call.proceed().unwrap().unwrap() else {
            panic!("Expected RecvResponse state")
        };

        let input = b"HTTP/1.1 200 OK\r\n\r\n";
        let (n, res) = call.try_response(input, false).unwrap();
        assert_eq!(n, 19);

        let Some(res) = res else {
            panic!("`try_response()` should return a response");
        };

        assert!(res.headers().is_empty());

        // should go to Cleanup state (content-length/transfer-encoding is ignored with CONNECT)
        let RecvResponseResult::Cleanup(_call) = call.proceed().unwrap() else {
            panic!("Expected Cleanup state")
        };
    }

    #[test]
    fn connect_read_body() {
        let req = Request::builder()
            .method(Method::CONNECT)
            .uri("http://example.com:80")
            .body(())
            .unwrap();

        let call = Call::new(req).unwrap();
        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        // CONNECT request should have request target in authority form
        let s = str::from_utf8(&output[..n]).unwrap();
        assert_eq!(
            s,
            "CONNECT example.com:80 HTTP/1.1\r\nhost: example.com:80\r\n\r\n"
        );

        // Should go to RecvResponse state (content-length/transfer-encoding is ignored with CONNECT)
        let SendRequestResult::RecvResponse(mut call) = call.proceed().unwrap().unwrap() else {
            panic!("Expected RecvResponse state")
        };

        call.force_recv_body();

        let input = b"HTTP/1.1 200 OK\r\ncontent-length: 1024\r\n\r\n";
        let (_n, res) = call.try_response(input, false).unwrap();

        let Some(_res) = res else {
            panic!("`try_response()` should return a response");
        };

        let RecvResponseResult::RecvBody(_call) = call.proceed().unwrap() else {
            panic!("Expect RecvBody state");
        };
    }

    #[test]
    fn connect_send_body_fails() {
        let req = Request::builder()
            .method(Method::CONNECT)
            .uri("http://example.com:80")
            .header("content-length", 1024)
            .body(())
            .unwrap();

        let call = Call::new(req).unwrap();
        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        call.write(&mut output)
            .expect_err("no body allowed on CONNECT request");
    }

    #[test]
    fn connect_send_body_with_footgun() {
        let req = Request::builder()
            .method(Method::CONNECT)
            .uri("http://example.com:80")
            .header("content-length", 1024)
            .body(())
            .unwrap();

        let mut call = Call::new(req).unwrap();

        call.force_send_body();
        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();

        // CONNECT request should have request target in authority form
        let s = str::from_utf8(&output[..n]).unwrap();
        assert_eq!(
            s,
            "CONNECT example.com:80 HTTP/1.1\r\nhost: example.com:80\r\ncontent-length: 1024\r\n\r\n"
        );

        let SendRequestResult::SendBody(_call) = call.proceed().unwrap().unwrap() else {
            panic!("Expected SendBody state")
        };
    }

    #[test]
    fn query_no_slash() {
        let req = Request::get("http://foo.test?query=foo").body(()).unwrap();

        let call = Call::new(req).unwrap();

        let mut call = call.proceed();

        let mut output = vec![0; 1024];
        let n = call.write(&mut output).unwrap();
        let s = str::from_utf8(&output[..n]).unwrap();

        // The added / here is to be compliant with RFC 9112 §3.2.1
        assert_eq!(
            s,
            "GET /?query=foo HTTP/1.1\r\n\
            host: foo.test\r\n\
            \r\n"
        );
    }
}
