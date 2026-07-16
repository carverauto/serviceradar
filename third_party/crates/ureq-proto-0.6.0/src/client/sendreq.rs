use std::io::Write;

use base64::Engine;
use base64::prelude::BASE64_STANDARD;
use http::uri::Scheme;
use http::{HeaderMap, HeaderName, HeaderValue, Method, Uri, Version, header};

use crate::Error;
use crate::client::amended::AmendedRequest;
use crate::ext::{AuthorityExt, MethodExt, SchemeExt};
use crate::util::Writer;

use super::state::SendRequest;
use super::{BodyState, Call, RequestPhase, SendRequestResult};

impl Call<SendRequest> {
    /// Write the request to the buffer.
    ///
    /// Writes incrementally, it can be called repeatedly in situations where the output
    /// buffer is small.
    ///
    /// This includes the first row, i.e. `GET / HTTP/1.1` and all headers.
    /// The output buffer needs to be large enough for the longest row.
    ///
    /// Example:
    ///
    /// ```text
    /// POST /bar HTTP/1.1\r\n
    /// Host: my.server.test\r\n
    /// User-Agent: myspecialthing\r\n
    /// \r\n
    /// <body data>
    /// ```
    ///
    /// The buffer would need to be at least 28 bytes big, since the `User-Agent` row is
    /// 28 bytes long.
    ///
    /// If the output is too small for the longest line, the result is an `OutputOverflow` error.
    ///
    /// The `Ok(usize)` is the number of bytes of the `output` buffer that was used.
    pub fn write(&mut self, output: &mut [u8]) -> Result<usize, Error> {
        self.maybe_analyze_request()?;

        let mut w = Writer::new(output);
        try_write_prelude(&self.inner.request, &mut self.inner.state, &mut w)?;

        let output_used = w.len();

        Ok(output_used)
    }

    /// The configured method.
    pub fn method(&self) -> &Method {
        self.inner.request.method()
    }

    /// The uri being requested.
    pub fn uri(&self) -> &Uri {
        self.inner.request.uri()
    }

    /// Version of the request.
    ///
    /// This can only be 1.0 or 1.1.
    pub fn version(&self) -> Version {
        self.inner.request.version()
    }

    /// The configured headers.
    pub fn headers_map(&mut self) -> Result<HeaderMap, Error> {
        self.maybe_analyze_request()?;
        let mut map = HeaderMap::new();
        for (k, v) in self.inner.request.headers() {
            map.insert(k, v.clone());
        }
        Ok(map)
    }

    /// Check whether the entire request has been sent.
    ///
    /// This is useful when the output buffer is small and we need to repeatedly
    /// call `write()` to send the entire request.
    pub fn can_proceed(&self) -> bool {
        !self.inner.state.phase.is_prelude()
    }

    /// Attempt to proceed from this state to the next.
    ///
    /// Returns `None` if the entire request has not been sent. It is guaranteed that if
    /// `can_proceed()` returns `true`, this will return `Some`.
    pub fn proceed(mut self) -> Result<Option<SendRequestResult>, Error> {
        if !self.can_proceed() {
            return Ok(None);
        }

        if self.inner.state.writer.has_body() {
            if self.inner.await_100_continue {
                Ok(Some(SendRequestResult::Await100(Call::wrap(self.inner))))
            } else {
                // TODO(martin): is this needed?
                self.maybe_analyze_request()?;
                let call = Call::wrap(self.inner);
                Ok(Some(SendRequestResult::SendBody(call)))
            }
        } else {
            let call = Call::wrap(self.inner);
            Ok(Some(SendRequestResult::RecvResponse(call)))
        }
    }

    pub(crate) fn maybe_analyze_request(&mut self) -> Result<(), Error> {
        if self.inner.analyzed {
            return Ok(());
        }

        let info = self.inner.request.analyze(
            self.inner.state.writer,
            self.inner.state.allow_non_standard_methods,
        )?;

        let method = self.inner.request.method();
        let send_body = (method.allow_request_body() || self.inner.force_send_body)
            && info.body_mode.has_body();

        if !send_body && info.body_mode.has_body() {
            return Err(Error::BodyNotAllowed);
        }

        if !info.req_host_header && method != Method::CONNECT {
            if let Some(host) = self.inner.request.uri().host() {
                // User did not set a host header, and there is one in uri, we set that.
                // We need an owned value to set the host header.

                // This might append the port if it differs from the scheme default.
                let value = maybe_with_port(host, self.inner.request.uri())?;

                self.inner.request.set_header(header::HOST, value)?;
            }
        }

        if let Some(auth) = self.inner.request.uri().authority() {
            if self.inner.request.method() != Method::CONNECT {
                if auth.userinfo().is_some() && !info.req_auth_header {
                    let user = auth.username().unwrap_or_default();
                    let pass = auth.password().unwrap_or_default();
                    let creds = BASE64_STANDARD.encode(format!("{}:{}", user, pass));
                    let auth = format!("Basic {}", creds);
                    self.inner.request.set_header(header::AUTHORIZATION, auth)?;
                }
            } else if !info.req_host_header {
                self.inner
                    .request
                    .set_header(header::HOST, auth.clone().as_str())?;
            }
        }

        if !info.req_body_header && info.body_mode.has_body() {
            // User did not set a body header, we set one.
            let header = info.body_mode.body_header();
            self.inner.request.set_header(header.0, header.1)?;
        }

        self.inner.state.writer = info.body_mode;

        self.inner.analyzed = true;
        Ok(())
    }
}

fn maybe_with_port(host: &str, uri: &Uri) -> Result<HeaderValue, Error> {
    fn from_str(src: &str) -> Result<HeaderValue, Error> {
        HeaderValue::from_str(src).map_err(|e| Error::BadHeader(e.to_string()))
    }

    if let Some(port) = uri.port() {
        let scheme = uri.scheme().unwrap_or(&Scheme::HTTP);
        if let Some(scheme_default) = scheme.default_port() {
            if port != scheme_default {
                // This allocates, so we only do it if we absolutely have to.
                let host_port = format!("{}:{}", host, port);
                return from_str(&host_port);
            }
        }
    }

    // Fall back on no port (without allocating).
    from_str(host)
}

fn try_write_prelude(
    request: &AmendedRequest,
    state: &mut BodyState,
    w: &mut Writer,
) -> Result<(), Error> {
    let at_start = w.len();

    loop {
        if try_write_prelude_part(request, state, w) {
            continue;
        }

        let written = w.len() - at_start;

        if written > 0 || state.phase.is_body() {
            return Ok(());
        } else {
            return Err(Error::OutputOverflow);
        }
    }
}

fn try_write_prelude_part(request: &AmendedRequest, state: &mut BodyState, w: &mut Writer) -> bool {
    match &mut state.phase {
        RequestPhase::Line => {
            let success = do_write_send_line(request.prelude(), w);
            if success {
                state.phase = RequestPhase::Headers(0);
            }
            success
        }

        RequestPhase::Headers(index) => {
            let header_count = request.headers_len();
            let all = request.headers();
            let skipped = all.skip(*index);

            if header_count > 0 {
                do_write_headers(skipped, index, header_count - 1, w);
            }

            if *index == header_count {
                state.phase = RequestPhase::Body;
            }
            false
        }

        // We're past the header.
        _ => false,
    }
}

fn do_write_send_line(line: (&Method, &str, Version), w: &mut Writer) -> bool {
    // Ensure origin-form request-target starts with "/" when only a query is present
    // per RFC 9112 §3.2.1 (@https://datatracker.ietf.org/doc/html/rfc9112#section-3.2.1).
    let need_initial_slash = line.1.starts_with('?');
    let slash = if need_initial_slash { "/" } else { "" };

    w.try_write(|w| write!(w, "{} {}{} {:?}\r\n", line.0, slash, line.1, line.2))
}

fn do_write_headers<'a, I>(headers: I, index: &mut usize, last_index: usize, w: &mut Writer)
where
    I: Iterator<Item = (&'a HeaderName, &'a HeaderValue)>,
{
    for h in headers {
        let success = w.try_write(|w| {
            write!(w, "{}: ", h.0)?;
            w.write_all(h.1.as_bytes())?;
            write!(w, "\r\n")?;
            if *index == last_index {
                write!(w, "\r\n")?;
            }
            Ok(())
        });

        if success {
            *index += 1;
        } else {
            break;
        }
    }
}
