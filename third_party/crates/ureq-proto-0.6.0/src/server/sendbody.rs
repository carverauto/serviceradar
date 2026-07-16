use crate::Error;
use crate::body::calculate_max_input;
use crate::util::Writer;

use super::Reply;
use super::state::{Cleanup, SendBody};

impl Reply<SendBody> {
    /// Write response body from `input` to `output`.
    ///
    /// This is called repeatedly until the entire body has been sent. The output buffer is filled
    /// as much as possible for each call.
    ///
    /// Depending on response headers, the output might be `transfer-encoding: chunked`. Chunking means
    /// the output is slightly larger than the input due to the extra length headers per chunk.
    /// When not doing chunked, the input/output will be the same per call.
    ///
    /// The result `(usize, usize)` is `(input consumed, output used)`.
    ///
    /// **Important**
    ///
    /// To indicate that the body is fully sent, you call write with an `input` parameter set to `&[]`.
    /// This ends the `transfer-encoding: chunked` and ensures the state is correct to proceed.
    pub fn write(&mut self, input: &[u8], output: &mut [u8]) -> Result<(usize, usize), Error> {
        let mut w = Writer::new(output);

        // unwrap is ok because we must have called analyze in above write()
        // to use consume_direct_write()
        let writer = self.inner.state.writer.as_mut().unwrap();

        if !input.is_empty() && writer.is_ended() {
            return Err(Error::BodyContentAfterFinish);
        }

        if let Some(left) = writer.left_to_send() {
            if input.len() as u64 > left {
                return Err(Error::BodyLargerThanContentLength);
            }
        }

        let input_used = writer.write(input, &mut w);
        let output_used = w.len();

        Ok((input_used, output_used))
    }

    /// Helper to avoid copying memory.
    ///
    /// When the transfer is _NOT_ chunked, `write()` just copies the `input` to the `output`.
    /// This memcopy might be possible to avoid if the user can use the `input` buffer directly
    /// against the transport.
    ///
    /// This function is used to "report" how much of the input that has been used. It's effectively
    /// the same as the first `usize` in the pair returned by `write()`.
    pub fn consume_direct_write(&mut self, amount: usize) -> Result<(), Error> {
        // unwrap is ok because we must have called analyze in above write()
        // to use consume_direct_write()
        let writer = self.inner.state.writer.as_mut().unwrap();

        if let Some(left) = writer.left_to_send() {
            if amount as u64 > left {
                return Err(Error::BodyLargerThanContentLength);
            }
        } else {
            return Err(Error::BodyIsChunked);
        }

        writer.consume_direct_write(amount);

        Ok(())
    }

    /// Calculate the max amount of input we can transfer to fill the `output_len`.
    ///
    /// For chunked transfer, the input is less than the output.
    pub fn calculate_max_input(&self, output_len: usize) -> usize {
        // For non-chunked, the entire output can be used.
        if !self.is_chunked() {
            return output_len;
        }

        calculate_max_input(output_len)
    }

    /// Test if the response is using chunked transfer encoding.
    pub fn is_chunked(&self) -> bool {
        self.inner.state.writer.as_ref().unwrap().is_chunked()
    }

    /// Check whether the response body is fully sent.
    ///
    /// For responses with a `content-length` header set, this will only become `true` once the
    /// number of bytes communicated have been sent. For chunked transfer, this becomes `true`
    /// after calling `write()` with an input of `&[]`.
    pub fn is_finished(&self) -> bool {
        self.inner.state.writer.as_ref().unwrap().is_ended()
    }

    /// Proceed to the Cleanup state.
    ///
    /// Transitions to the Cleanup state after the response body has been fully sent.
    /// This is only possible when the response body is fully sent.
    ///
    /// Panics if the response body has not been fully sent.
    pub fn proceed(self) -> Reply<Cleanup> {
        assert!(self.is_finished());

        Reply::wrap(self.inner)
    }
}
