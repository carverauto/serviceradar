use crate::body::BodyReader;
use crate::{BodyMode, Error};

use super::state::RecvBody;
use super::{Call, RecvBodyResult};

impl Call<RecvBody> {
    /// Read the response body from `input` to `output`.
    ///
    /// Depending on response headers, we can be in `transfer-encoding: chunked` or not. If we are,
    /// there will be less `output` bytes than `input`.
    ///
    /// The result `(usize, usize)` is `(input consumed, output buffer used)`.
    pub fn read(&mut self, input: &[u8], output: &mut [u8]) -> Result<(usize, usize), Error> {
        let rbm = self.inner.state.reader.as_mut().unwrap();

        if rbm.is_ended() {
            return Ok((0, 0));
        }

        rbm.read(input, output, self.inner.state.stop_on_chunk_boundary)
    }

    /// Set if we are stopping on chunk boundaries.
    ///
    /// If `false`, we try to fill entire `output` on each read() call.
    /// Has no meaning unless the response in chunked.
    ///
    /// Defaults to `false`
    pub fn stop_on_chunk_boundary(&mut self, enabled: bool) {
        self.inner.state.stop_on_chunk_boundary = enabled;
    }

    /// Tell if the reading is on a chunk boundary.
    ///
    /// Used when we want to read exactly chunk-by-chunk.
    ///
    /// Only releveant if we first enabled `stop_on_chunk_boundary()`.
    pub fn is_on_chunk_boundary(&self) -> bool {
        let rbm = self.inner.state.reader.as_ref().unwrap();
        rbm.is_on_chunk_boundary()
    }

    /// Tell which kind of mode the response body is.
    pub fn body_mode(&self) -> BodyMode {
        self.inner.state.reader.as_ref().unwrap().body_mode()
    }

    /// Check if the response body has been fully received.
    pub fn can_proceed(&self) -> bool {
        self.is_ended() || self.is_close_delimited()
    }

    /// Tell if the response is over
    fn is_ended(&self) -> bool {
        let rbm = self.inner.state.reader.as_ref().unwrap();
        rbm.is_ended()
    }

    /// Tell if we got an end chunk when reading chunked.
    ///
    /// A normal chunk ending is:
    ///
    /// ```text
    /// 0\r\n
    /// \r\n
    /// ```
    ///
    /// However there are cases where the server abruptly does a `FIN` after sending `0\r\n`.
    /// This means we still got the entire response body, and could use it, but not reuse the connection.
    ///
    /// This returns true as soon as we got the `0\r\n`.
    pub fn is_ended_chunked(&self) -> bool {
        let rbm = self.inner.state.reader.as_ref().unwrap();
        rbm.is_ended_chunked()
    }

    /// Tell if response body is closed delimited
    ///
    /// HTTP/1.0 does not have `content-length` to serialize many requests over the same
    /// socket. Instead it uses socket close to determine the body is finished.
    fn is_close_delimited(&self) -> bool {
        let rbm = self.inner.state.reader.as_ref().unwrap();
        matches!(rbm, BodyReader::CloseDelimited)
    }

    /// Proceed to the next state.
    ///
    /// Returns `None` if we are not fully received the body. It is guaranteed that if `can_proceed()`
    /// returns `true`, this will return `Some`.
    pub fn proceed(self) -> Option<RecvBodyResult> {
        if !self.can_proceed() {
            return None;
        }

        Some(if self.inner.is_redirect() {
            RecvBodyResult::Redirect(Call::wrap(self.inner))
        } else {
            RecvBodyResult::Cleanup(Call::wrap(self.inner))
        })
    }
}
