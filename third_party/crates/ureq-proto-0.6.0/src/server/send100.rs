use http::{StatusCode, Version};

use crate::Error;
use crate::util::Writer;

use super::state::{ProvideResponse, RecvBody, Send100};
use super::{Reply, do_write_send_line};

impl Reply<Send100> {
    /// Sends a 100 Continue response and proceeds to receiving the body.
    ///
    /// This method sends an HTTP 100 Continue response to the client, indicating that
    /// the server is willing to accept the request body. After sending the response,
    /// it transitions to the RecvBody state to receive the request body.
    ///
    /// Returns a tuple with the number of bytes written to the output buffer and
    /// the Reply in the RecvBody state.
    ///
    /// Returns an `Error::OutputOverflow` if the output buffer isn't large enough to
    /// contain the 100 Continue status line.
    pub fn accept(self, output: &mut [u8]) -> Result<(usize, Reply<RecvBody>), Error> {
        let mut w = Writer::new(output);

        let success = do_write_send_line((Version::HTTP_11, StatusCode::CONTINUE), &mut w, true);
        if !success {
            return Err(Error::OutputOverflow);
        }

        let output_used = w.len();

        let flow = Reply::wrap(self.inner);

        Ok((output_used, flow))
    }

    /// Rejects the 100 Continue request and proceeds to providing a response.
    ///
    /// This method rejects the client's "Expect: 100-continue" request and transitions
    /// to the ProvideResponse state. The server should then provide an error response
    /// (typically a 4xx or 5xx status code) to indicate why the request was rejected.
    pub fn reject(mut self) -> Reply<ProvideResponse> {
        self.inner.expect_100_reject = true;
        Reply::wrap(self.inner)
    }
}
