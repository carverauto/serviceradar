use std::io::Write;

use http::{HeaderName, HeaderValue};

use crate::Error;
use crate::util::Writer;

use super::state::SendResponse;
use super::{Reply, ResponsePhase, SendResponseResult, do_write_send_line};

impl Reply<SendResponse> {
    /// Write the response headers to the output buffer.
    ///
    /// Writes the response status line and headers to the output buffer.
    /// May need to be called multiple times if the output buffer isn't large enough.
    ///
    /// Returns the number of bytes written to the output buffer.
    pub fn write(&mut self, output: &mut [u8]) -> Result<usize, Error> {
        // unwrap is ok because we are not here without providing it
        let response = self.inner.response.as_ref().unwrap();

        let mut w = Writer::new(output);
        try_write_prelude(response, &mut self.inner.phase, &mut w)?;

        let output_used = w.len();

        Ok(output_used)
    }

    /// Whether the response headers have been fully written.
    ///
    /// Returns true if all response headers have been written and the state
    /// is ready to proceed to sending the response body.
    pub fn is_finished(&self) -> bool {
        !self.inner.phase.is_prelude()
    }

    /// Proceed to sending a response body or cleanup.
    ///
    /// Transitions to either:
    /// - SendBody state if the response needs a body (based on status code and method)
    /// - Cleanup state if no response body should be sent (e.g., HEAD requests)
    ///
    /// This is only possible when the response headers are fully written.
    ///
    /// Panics if the response headers have not been fully written.
    pub fn proceed(self) -> SendResponseResult {
        assert!(self.is_finished());

        if let Some(writer) = self.inner.state.writer {
            // Enter SendBody for both chunked and sized bodies, even when size is 0,
            // to ensure consistent state progression for explicit body headers.
            //
            // TODO(martin): Do we actually want this API wise? Isn't it better to go straight to Cleanup?
            if writer.is_chunked() || writer.left_to_send().is_some() {
                return SendResponseResult::SendBody(Reply::wrap(self.inner));
            }
        }

        SendResponseResult::Cleanup(Reply::wrap(self.inner))
    }
}

fn try_write_prelude(
    response: &super::amended::AmendedResponse,
    phase: &mut ResponsePhase,
    w: &mut Writer,
) -> Result<(), Error> {
    let at_start = w.len();

    loop {
        if try_write_prelude_part(response, phase, w) {
            continue;
        }

        let written = w.len() - at_start;

        if written > 0 || phase.is_body() {
            return Ok(());
        } else {
            return Err(Error::OutputOverflow);
        }
    }
}

fn try_write_prelude_part(
    response: &super::amended::AmendedResponse,
    phase: &mut ResponsePhase,
    w: &mut Writer,
) -> bool {
    match phase {
        ResponsePhase::Status => {
            let success = do_write_send_line(response.prelude(), w, false);
            if success {
                *phase = ResponsePhase::Headers(0);
            }
            success
        }

        ResponsePhase::Headers(index) => {
            let header_count = response.headers_len();
            let all = response.headers();
            let skipped = all.skip(*index);

            do_write_headers(skipped, index, w);
            if *index == header_count && w.try_write(|w| write!(w, "\r\n")) {
                *phase = ResponsePhase::Body;
            }
            false
        }

        // We're past the header.
        _ => false,
    }
}

fn do_write_headers<'a, I>(headers: I, index: &mut usize, w: &mut Writer)
where
    I: Iterator<Item = (&'a HeaderName, &'a HeaderValue)>,
{
    for h in headers {
        let success = w.try_write(|w| {
            write!(w, "{}: ", h.0)?;
            w.write_all(h.1.as_bytes())?;
            write!(w, "\r\n")?;

            Ok(())
        });

        if success {
            *index += 1;
        } else {
            break;
        }
    }
}
