use http::{HeaderMap, HeaderName, HeaderValue, Method, Request, Uri, Version, header};

use crate::body::BodyWriter;
use crate::client::amended::AmendedRequest;
use crate::ext::{HeaderIterExt, MethodExt};
use crate::{ArrayVec, Error};

use super::state::{Prepare, SendRequest};
use super::{BodyState, Call, CloseReason, Inner};

impl Call<Prepare> {
    /// Create a new Call instance from an HTTP request.
    ///
    /// This initializes a new Call state machine in the Prepare state,
    /// setting up the necessary internal state based on the request properties.
    pub fn new(request: Request<()>) -> Result<Self, Error> {
        let mut close_reason = ArrayVec::from_fn(|_| CloseReason::ClientConnectionClose);

        if request.version() == Version::HTTP_10 {
            // request.analyze() in CallHolder::new() ensures the only versions are HTTP 1.0 and 1.1
            close_reason.push(CloseReason::CloseDelimitedBody)
        }

        if request.headers().iter().has(header::CONNECTION, "close") {
            close_reason.push(CloseReason::ClientConnectionClose);
        }

        let need_request_body = request.method().need_request_body();
        let await_100_continue = request.headers().iter().has_expect_100();

        let request = AmendedRequest::new(request);

        let default_body_mode = if need_request_body {
            BodyWriter::new_chunked()
        } else {
            BodyWriter::new_none()
        };

        let inner = Inner {
            request,
            analyzed: false,
            state: BodyState {
                writer: default_body_mode,
                ..Default::default()
            },
            close_reason,
            force_send_body: false,
            force_recv_body: false,
            await_100_continue,
            status: None,
            location: None,
        };

        Ok(Call::wrap(inner))
    }

    /// Inspect call method
    pub fn method(&self) -> &Method {
        self.inner.request.method()
    }

    /// Inspect call URI
    pub fn uri(&self) -> &Uri {
        self.inner.request.uri()
    }

    /// Inspect call HTTP version
    pub fn version(&self) -> Version {
        self.inner.request.version()
    }

    /// Inspect call headers
    pub fn headers(&self) -> &HeaderMap {
        self.inner.request.original_request_headers()
    }

    /// Set whether to allow non-standard HTTP methods.
    ///
    /// By default the methods are limited by the HTTP version.
    pub fn allow_non_standard_methods(&mut self, v: bool) {
        self.inner.state.allow_non_standard_methods = v;
    }

    /// Add more headers to the call
    pub fn header<K, V>(&mut self, key: K, value: V) -> Result<(), Error>
    where
        HeaderName: TryFrom<K>,
        <HeaderName as TryFrom<K>>::Error: Into<http::Error>,
        HeaderValue: TryFrom<V>,
        <HeaderValue as TryFrom<V>>::Error: Into<http::Error>,
    {
        self.inner.request.set_header(key, value)
    }

    /// Convert the state to send body despite method.
    ///
    /// Methods like GET, HEAD and DELETE should not have a request body.
    /// Some broken APIs use bodies anyway, and this is an escape hatch to
    /// interoperate with such services.
    pub fn force_send_body(&mut self) {
        self.inner.force_send_body = true;
    }

    /// Continue to the next call state.
    pub fn proceed(self) -> Call<SendRequest> {
        Call::wrap(self.inner)
    }
}
