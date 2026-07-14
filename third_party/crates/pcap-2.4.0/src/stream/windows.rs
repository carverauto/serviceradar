//! Support for asynchronous packet iteration.
//!
//! See [`Capture::stream`](super::Capture::stream).
use std::marker::Unpin;
use std::pin::Pin;
use std::task::{self, Poll};

use futures::{ready, FutureExt};
use tokio::task::JoinHandle;
use windows_sys::Win32::{Foundation::HANDLE, System::Threading::WaitForSingleObject};

use crate::{
    capture::{Activated, Capture},
    codec::PacketCodec,
    Error,
};

/// Implement Stream for async use of pcap
pub struct PacketStream<T: Activated + ?Sized, C> {
    event_handle: EventHandle,
    capture: Capture<T>,
    codec: C,
}

impl<T: Activated + ?Sized, C> PacketStream<T, C> {
    pub(crate) fn new(capture: Capture<T>, codec: C) -> Result<Self, Error> {
        Ok(Self {
            event_handle: EventHandle::new(&capture),
            capture,
            codec,
        })
    }

    /// Returns a mutable reference to the inner [`Capture`].
    ///
    /// The caller must ensure the capture will not be set to be blocking.
    pub fn capture_mut(&mut self) -> &mut Capture<T> {
        &mut self.capture
    }
}

impl<T: Activated + ?Sized, C> Unpin for PacketStream<T, C> {}

impl<T: Activated + ?Sized, C: PacketCodec> futures::Stream for PacketStream<T, C> {
    type Item = Result<C::Item, Error>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut task::Context) -> Poll<Option<Self::Item>> {
        let stream = Pin::into_inner(self);
        let codec = &mut stream.codec;

        loop {
            ready!(stream.event_handle.poll_ready(cx));

            let res = match stream.capture.next_packet() {
                Ok(p) => Ok(codec.decode(p)),
                Err(Error::TimeoutExpired) => {
                    stream.event_handle.clear_ready();
                    continue;
                }
                Err(e) => Err(e),
            };
            return Poll::Ready(Some(res));
        }
    }
}

/// A wrapper around a HANDLE that can be used to call `WaitForSingleObject`
/// from an asynchronous context. Once the call to `WaitForSingleObject`
/// completes, the handle is considered ready and will keep returning `Ready`
/// until it's reset.
struct EventHandle {
    handle: HANDLE,
    state: EventHandleState,
}

enum EventHandleState {
    /// We haven't started waiting for an event yet.
    Init,
    /// We're currently waiting for an event.
    Polling(JoinHandle<()>),
    /// We waited for an event.
    Ready,
}

impl EventHandle {
    pub fn new<T: Activated + ?Sized>(capture: &Capture<T>) -> Self {
        Self {
            handle: unsafe {
                // SAFETY: PacketStream stores the handle before the capture,
                // so the handle will be dropped before the capture.
                capture.get_event()
            },
            state: EventHandleState::Init,
        }
    }

    pub fn poll_ready(&mut self, cx: &mut task::Context) -> Poll<()> {
        loop {
            match self.state {
                EventHandleState::Init => {
                    let handle = self.handle;
                    self.state =
                        EventHandleState::Polling(tokio::task::spawn_blocking(move || {
                            const INFINITE: u32 = !0;
                            unsafe {
                                WaitForSingleObject(handle, INFINITE);
                            }
                        }));
                }
                EventHandleState::Polling(ref mut join_handle) => {
                    let _ = ready!(join_handle.poll_unpin(cx));
                    self.state = EventHandleState::Ready;
                }
                EventHandleState::Ready => return Poll::Ready(()),
            }
        }
    }

    /// Reset the internal state. This will trigger a call to
    /// `WaitForSingleObject` the next time `poll_ready` is called.
    pub fn clear_ready(&mut self) {
        self.state = EventHandleState::Init;
    }
}
