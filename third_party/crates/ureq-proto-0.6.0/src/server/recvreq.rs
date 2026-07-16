use http::{Request, Version, header};

use crate::body::BodyReader;
use crate::ext::HeaderIterExt;
use crate::parser::try_parse_request;
use crate::util::log_data;
use crate::{ArrayVec, CloseReason, Error};

use super::state::RecvRequest;
use super::{Inner, Reply, ResponsePhase};
use super::{MAX_REQUEST_HEADERS, RecvRequestResult};

impl Reply<RecvRequest> {
    /// Create a new Reply in the RecvRequest state.
    ///
    /// This is the entry point for the server state machine. It creates a new Reply
    /// in the RecvRequest state, ready to receive an HTTP request from a client.
    ///
    /// Returns an error if the Reply cannot be created.
    pub fn new() -> Result<Self, Error> {
        let close_reason = ArrayVec::from_fn(|_| CloseReason::ClientConnectionClose);

        let inner = Inner {
            phase: ResponsePhase::Status,
            state: super::BodyState::default(),
            response: None,
            close_reason,
            force_recv_body: false,
            force_send_body: false,
            method: None,
            expect_100: false,
            expect_100_reject: false,
        };

        Ok(Reply::wrap(inner))
    }

    /// Try reading a request from the input.
    ///
    /// Attempts to parse an HTTP request from the input buffer. If the input buffer
    /// doesn't contain a complete request, this method will return `Ok((0, None))`.
    ///
    /// Returns a tuple with the number of bytes consumed from the input and
    /// the parsed request (or None if incomplete).
    ///
    /// Returns an error if there's a problem parsing the request.
    pub fn try_request(&mut self, input: &[u8]) -> Result<(usize, Option<Request<()>>), Error> {
        let maybe_request = self.do_try_request(input)?;

        let (input_used, request) = match maybe_request {
            Some(v) => v,
            // Not enough input for a full response yet
            None => return Ok((0, None)),
        };

        self.inner.method = Some(request.method().clone());
        self.inner.expect_100 = request.headers().iter().has_expect_100();

        let headers = request.headers();
        let is_http10 = request.version() == Version::HTTP_10;
        let is_keep_alive = headers.iter().has(header::CONNECTION, "keep-alive");
        let is_conn_close = headers.iter().has(header::CONNECTION, "close");

        if is_http10 && !is_keep_alive {
            self.inner
                .close_reason
                .push(CloseReason::CloseDelimitedBody);
        }

        if is_conn_close {
            self.inner
                .close_reason
                .push(CloseReason::ClientConnectionClose);
        }

        Ok((input_used, Some(request)))
    }

    /// Try reading request headers
    ///
    /// A request is only possible once the `input` holds all the HTTP request
    /// headers. Before that this returns `None`. When the request is succesfully read,
    /// the return value `(usize, Request<()>)` contains how many bytes were consumed
    /// of the `input`.
    fn do_try_request(&mut self, input: &[u8]) -> Result<Option<(usize, Request<()>)>, Error> {
        // ~3k for 100 headers
        let (input_used, request) = match try_parse_request::<MAX_REQUEST_HEADERS>(input)? {
            Some(v) => v,
            None => {
                return Ok(None);
            }
        };

        log_data(&input[..input_used]);

        let http10 = request.version() == Version::HTTP_10;
        let method = request.method();

        let header_lookup = |name: http::HeaderName| {
            let header = request.headers().get(name)?;
            header.to_str().ok()
        };

        let reader =
            BodyReader::for_request(http10, method, self.inner.force_recv_body, &header_lookup)?;
        self.inner.state.reader = Some(reader);

        Ok(Some((input_used, request)))
    }

    /// Check if the Reply can proceed to the next state.
    ///
    /// This method is currently not implemented and will panic if called.
    /// In a real implementation, it would check if the request has been fully received
    /// and is ready to proceed to the next state.
    pub fn can_proceed(&self) -> bool {
        self.inner.state.reader.is_some()
    }

    /// Proceed to the next state.
    ///
    /// This returns `None` if we have not finished receiving the request. It is guaranteed that if
    /// `can_proceed()` returns true, this will return `Some`.
    ///
    /// Returns one of the following variants of `RecvRequestResult`:
    /// - `Send100` if the request included an "Expect: 100-continue" header
    /// - `RecvBody` if the request has a body to receive
    /// - `ProvideResponse` if the request doesn't have a body
    pub fn proceed(self) -> Option<RecvRequestResult> {
        if !self.can_proceed() {
            return None;
        }

        let has_request_body = self.inner.state.reader.as_ref().unwrap().has_body();

        if has_request_body {
            if self.inner.expect_100 {
                Some(RecvRequestResult::Send100(Reply::wrap(self.inner)))
            } else {
                Some(RecvRequestResult::RecvBody(Reply::wrap(self.inner)))
            }
        } else {
            Some(RecvRequestResult::ProvideResponse(Reply::wrap(self.inner)))
        }
    }

    /// Convert the state to receive a body despite method.
    ///
    /// Methods like HEAD and CONNECT should not have attached bodies.
    /// Some broken APIs use bodies anyway and this is an escape hatch to
    /// interoperate with such services.
    pub fn force_recv_body(&mut self) {
        self.inner.force_recv_body = true;
    }
}
