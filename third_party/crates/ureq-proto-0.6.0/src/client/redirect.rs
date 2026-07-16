use http::uri::Scheme;
use http::{Method, StatusCode, Uri, header};

use crate::Error;
use crate::ext::{MethodExt, StatusExt};

use super::state::{Cleanup, Prepare, Redirect};
use super::{Call, RedirectAuthHeaders};

impl Call<Redirect> {
    /// Construct a new `Call` by following the redirect.
    ///
    /// There are some rules when following a redirect.
    ///
    /// * For 307/308
    ///     * POST/PUT results in `None`, since we do not allow redirecting a request body
    ///     * DELETE is intentionally excluded: <https://stackoverflow.com/questions/299628>
    ///     * All other methods retain the method in the redirect
    /// * Other redirect (301, 302, etc)
    ///     * HEAD results in HEAD in the redirect
    ///     * All other methods becomes GET
    pub fn as_new_call(
        &mut self,
        redirect_auth_headers: RedirectAuthHeaders,
    ) -> Result<Option<Call<Prepare>>, Error> {
        let header = match &self.inner.location {
            Some(v) => v,
            None => return Err(Error::NoLocationHeader),
        };

        let location = match header.to_str() {
            Ok(v) => v,
            Err(_) => {
                return Err(Error::BadLocationHeader(
                    String::from_utf8_lossy(header.as_bytes()).to_string(),
                ));
            }
        };

        // Previous request
        let previous = &mut self.inner.request;

        // Unwrap is OK, because we can't be here without having read a response.
        let status = self.inner.status.unwrap();
        let method = previous.method();

        // A new uri by combining the base from the previous request and the new location.
        let uri = previous.new_uri_from_location(location)?;

        // Perform the redirect method differently depending on 3xx code.
        let new_method = if status.is_redirect_retaining_status() {
            if method.need_request_body() {
                // only resend the request if it cannot have a body
                return Ok(None);
            } else if method == Method::DELETE {
                // NOTE: DELETE is intentionally excluded: https://stackoverflow.com/questions/299628
                return Ok(None);
            } else {
                method.clone()
            }
        } else {
            // this is to follow how curl does it. POST, PUT etc change
            // to GET on a redirect.
            if matches!(*method, Method::GET | Method::HEAD) {
                method.clone()
            } else {
                Method::GET
            }
        };

        let mut request = previous.take_request();

        // The calculated redirect method
        *request.method_mut() = new_method;

        let keep_auth_header = match redirect_auth_headers {
            RedirectAuthHeaders::Never => false,
            RedirectAuthHeaders::SameHost => can_redirect_auth_header(request.uri(), &uri),
        };

        // The redirect URI
        *request.uri_mut() = uri;

        // Mutate the original request to remove headers we cannot keep in the redirect.
        let headers = request.headers_mut();
        if !keep_auth_header {
            headers.remove(header::AUTHORIZATION);
        }
        headers.remove(header::COOKIE);
        headers.remove(header::CONTENT_LENGTH);

        // Next state
        let next = Call::new(request)?;

        Ok(Some(next))
    }

    /// The redirect status code.
    pub fn status(&self) -> StatusCode {
        self.inner.status.unwrap()
    }

    /// Whether we must close the connection corresponding to the current call.
    ///
    /// This is used to inform connection pooling.
    pub fn must_close_connection(&self) -> bool {
        self.close_reason().is_some()
    }

    /// If we are closing the connection, give a reason why.
    pub fn close_reason(&self) -> Option<&'static str> {
        self.inner.close_reason.first().map(|s| s.explain())
    }

    /// Proceed to the cleanup state.
    pub fn proceed(self) -> Call<Cleanup> {
        Call::wrap(self.inner)
    }
}

fn can_redirect_auth_header(prev: &Uri, next: &Uri) -> bool {
    let host_prev = prev.authority().map(|a| a.host());
    let host_next = next.authority().map(|a| a.host());
    let scheme_prev = prev.scheme();
    let scheme_next = next.scheme();
    host_prev == host_next && (scheme_prev == scheme_next || scheme_next == Some(&Scheme::HTTPS))
}
