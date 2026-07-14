//! Support for asynchronous packet iteration.
//!
//! See [`Capture::stream`](super::Capture::stream).
use std::io;
use std::marker::Unpin;
use std::pin::Pin;
use std::task::{self, Poll};

use futures::ready;
use tokio::io::unix::AsyncFd;

use crate::{
    capture::{selectable::SelectableCapture, Activated, Capture},
    codec::PacketCodec,
    Error,
};

/// Implement Stream for async use of pcap
pub struct PacketStream<T: Activated + ?Sized, C> {
    inner: AsyncFd<SelectableCapture<T>>,
    codec: C,
}

impl<T: Activated + ?Sized, C> PacketStream<T, C> {
    pub(crate) fn new(capture: Capture<T>, codec: C) -> Result<Self, Error> {
        let capture = SelectableCapture::new(capture)?;
        Ok(PacketStream {
            inner: AsyncFd::with_interest(capture, tokio::io::Interest::READABLE)?,
            codec,
        })
    }

    /// Returns a mutable reference to the inner [`Capture`].
    ///
    /// The caller must ensure the capture will not be set to be blocking.
    pub fn capture_mut(&mut self) -> &mut Capture<T> {
        self.inner.get_mut().get_inner_mut()
    }
}

impl<T: Activated + ?Sized, C> Unpin for PacketStream<T, C> {}

impl<T: Activated + ?Sized, C: PacketCodec> futures::Stream for PacketStream<T, C> {
    type Item = Result<C::Item, Error>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut task::Context) -> Poll<Option<Self::Item>> {
        let stream = Pin::into_inner(self);
        let codec = &mut stream.codec;

        loop {
            let mut guard = ready!(stream.inner.poll_read_ready_mut(cx))?;
            match guard.try_io(
                |inner| match inner.get_mut().get_inner_mut().next_packet() {
                    Ok(p) => Ok(Ok(codec.decode(p))),
                    Err(e @ Error::TimeoutExpired) => {
                        Err(io::Error::new(io::ErrorKind::WouldBlock, e))
                    }
                    Err(e) => Ok(Err(e)),
                },
            ) {
                Ok(result) => {
                    return Poll::Ready(Some(result?));
                }
                Err(_would_block) => continue,
            }
        }
    }
}
