use http::{Response, header};

use crate::body::response_body_allowed;
use crate::{CloseReason, Error};

use super::state::{ProvideResponse, SendResponse};
use super::{Reply, append_request};

impl Reply<ProvideResponse> {
    /// Provide a response to the client's request.
    ///
    /// Takes a Response object and transitions to the SendResponse state.
    /// Handles setting appropriate headers for the response body if they weren't already set.
    pub fn provide(self, response: Response<()>) -> Result<Reply<SendResponse>, Error> {
        if self.inner.expect_100_reject
            && !response.status().is_client_error()
            && !response.status().is_server_error()
        {
            return Err(Error::BadReject100Status(response.status()));
        }

        let mut inner = append_request(self.inner, response);

        // unwrap are correct due to state we should be in when we get here.
        let response = inner.response.as_mut().unwrap();

        if response
            .headers()
            .any(|(h, v)| h == header::CONNECTION && v == "close")
        {
            inner.close_reason.push(CloseReason::ServerConnectionClose);
        }

        let writer = inner.state.writer.take().unwrap();
        let info = response.analyze(writer)?;

        let body_provided = info.body_mode.has_body();

        let (_, status) = response.prelude();
        let status = status.into();
        let method = inner.method.as_ref().unwrap();

        let body_allowed = response_body_allowed(method, status, info.body_mode.body_mode());
        let force_send = inner.force_send_body;

        let should_send_body = body_allowed || force_send;

        if body_provided && !should_send_body {
            // User set a body header but method does not allow one
            return Err(Error::BodyNotAllowed);
        }

        if body_provided && !info.res_body_header && should_send_body {
            // User did not set a body header, we set one.
            let header = info.body_mode.body_header();
            response.set_header(header.0, header.1)?;
        }

        inner.state.writer = Some(info.body_mode);

        Ok(Reply::wrap(inner))
    }

    /// Convert the state to send a body despite the method
    ///
    /// Methods like HEAD and CONNECT should not have attached bodies.
    /// Some broken APIs use bodies anyway and this is an escape hatch to
    /// interoperate with such services.
    pub fn force_send_body(&mut self) {
        self.inner.force_send_body = true;
    }
}
