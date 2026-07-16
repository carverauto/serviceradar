use crate::Error;
use crate::body::calculate_max_input;
use crate::util::Writer;

use super::Call;
use super::state::{RecvResponse, SendBody};

impl Call<SendBody> {
    /// Write request body from `input` to `output`.
    ///
    /// This is called repeatedly until the entire body has been sent. The output buffer is filled
    /// as much as possible for each call.
    ///
    /// Depending on request headers, the output might be `transfer-encoding: chunked`. Chunking means
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

        if !input.is_empty() && self.inner.state.writer.is_ended() {
            return Err(Error::BodyContentAfterFinish);
        }

        if let Some(left) = self.inner.state.writer.left_to_send() {
            if input.len() as u64 > left {
                return Err(Error::BodyLargerThanContentLength);
            }
        }

        let input_used = self.inner.state.writer.write(input, &mut w);
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
        if let Some(left) = self.inner.state.writer.left_to_send() {
            if amount as u64 > left {
                return Err(Error::BodyLargerThanContentLength);
            }
        } else {
            return Err(Error::BodyIsChunked);
        }

        self.inner.state.writer.consume_direct_write(amount);

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

    /// Test if call is chunked.
    ///
    /// This might need some processing, hence the &mut and
    pub fn is_chunked(&self) -> bool {
        self.inner.state.writer.is_chunked()
    }

    /// Check whether the request body is fully sent.
    ///
    /// For requests with a `content-length` header set, this will only become `true` once the
    /// number of bytes communicated have been sent. For chunked transfer, this becomes `true`
    /// after calling `write()` with an input of `&[]`.
    pub fn can_proceed(&self) -> bool {
        self.inner.state.writer.is_ended()
    }

    /// Proceed to the next state.
    ///
    /// Returns `None` if it's not possible to proceed. It's guaranteed that if `can_proceed()` returns
    /// `true`, this will result in `Some`.
    pub fn proceed(self) -> Option<Call<RecvResponse>> {
        if !self.can_proceed() {
            return None;
        }

        Some(Call::wrap(self.inner))
    }
}
