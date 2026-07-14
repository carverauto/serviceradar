extern crate mio;
extern crate tokio_io;


use std::{
    io,
    ops::Deref,
    sync::Arc,
};

use self::{
    mio::{
        event::Evented,
        unix::EventedFd,
    },
    tokio_io::AsyncRead,
};
use futures::{
    Async,
    Poll,
    Stream,
};
use tokio_reactor::{
    Handle,
    PollEvented,
};

use events::{
    Event,
    EventOwned,
};
use fd_guard::FdGuard;
use util::read_into_buffer;


/// Stream of inotify events
///
/// Allows for streaming events returned by [`Inotify::event_stream`].
///
/// [`Inotify::event_stream`]: struct.Inotify.html#method.event_stream
pub struct EventStream<T> {
    fd: PollEvented<EventedFdGuard>,
    buffer: T,
    buffer_pos: usize,
    unused_bytes: usize,
}

impl<T> EventStream<T>
where
    T: AsMut<[u8]> + AsRef<[u8]>,
{
    /// Returns a new `EventStream` associated with the default reactor.
    pub(crate) fn new(fd: Arc<FdGuard>, buffer: T) -> Self {
        EventStream {
            fd: PollEvented::new(EventedFdGuard(fd)),
            buffer: buffer,
            buffer_pos: 0,
            unused_bytes: 0,
        }
    }

    /// Returns a new `EventStream` associated with the specified reactor.
     pub(crate) fn new_with_handle(
        fd    : Arc<FdGuard>,
        handle: &Handle,
        buffer: T,
    )
        -> io::Result<Self>
    {
        Ok(EventStream {
            fd: PollEvented::new_with_handle(EventedFdGuard(fd), handle)?,
            buffer: buffer,
            buffer_pos: 0,
            unused_bytes: 0,
        })
    }
}

impl<T> Stream for EventStream<T>
where
    T: AsMut<[u8]> + AsRef<[u8]>,
{
    type Item = EventOwned;
    type Error = io::Error;

    fn poll(&mut self) -> Poll<Option<Self::Item>, Self::Error>
    {
        if self.unused_bytes == 0 {
            // Nothing usable in buffer. Need to reset and fill buffer.
            self.buffer_pos   = 0;
            self.unused_bytes = try_ready!(self.fd.poll_read(&mut self.buffer.as_mut()));
        }

        if self.unused_bytes == 0 {
            // The previous read returned `0` signalling end-of-file. Let's
            // signal end-of-stream to the caller.
            return Ok(Async::Ready(None));
        }

        // We have bytes in the buffer. inotify doesn't put partial events in
        // there, and we only take complete events out. That means we have at
        // least one event in there and can call `from_buffer` to take it out.
        let (bytes_consumed, event) = Event::from_buffer(
            Arc::downgrade(self.fd.get_ref()),
            &self.buffer.as_ref()[self.buffer_pos..],
        );
        self.buffer_pos   += bytes_consumed;
        self.unused_bytes -= bytes_consumed;

        Ok(Async::Ready(Some(event.into_owned())))
    }
}

#[derive(Clone, Debug, PartialEq)]
struct EventedFdGuard(Arc<FdGuard>);

impl Evented for EventedFdGuard {
    #[inline]
    fn register(&self,
                poll: &mio::Poll,
                token: mio::Token,
                interest: mio::Ready,
                opts: mio::PollOpt)
                -> io::Result<()>
    {
        EventedFd(&(self.fd)).register(poll, token, interest, opts)
    }

    #[inline]
    fn reregister(&self,
                  poll: &mio::Poll,
                  token: mio::Token,
                  interest: mio::Ready,
                  opts: mio::PollOpt)
                  -> io::Result<()>
    {
        EventedFd(&(self.fd)).reregister(poll, token, interest, opts)
    }

    #[inline]
    fn deregister(&self, poll: &mio::Poll) -> io::Result<()> {
        EventedFd(&self.fd).deregister(poll)
    }
}

impl io::Read for EventedFdGuard {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match read_into_buffer(self.fd, buf) {
            i if i >= 0 => Ok(i as usize),
            _ => Err(io::Error::last_os_error()),
        }
    }
}

impl Deref for EventedFdGuard {
    type Target = Arc<FdGuard>;
    #[inline]
    fn deref(&self) -> &Self::Target {
        &self.0
    }

}
