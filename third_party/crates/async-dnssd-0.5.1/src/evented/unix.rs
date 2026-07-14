use std::{
	io,
	os::raw::c_int,
	task::{
		Context,
		Poll,
	},
};
use tokio::io::unix::AsyncFd;

fn is_readable(fd: c_int) -> io::Result<bool> {
	let mut fds = libc::pollfd {
		fd,
		events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
		revents: 0,
	};
	loop {
		let r = unsafe { libc::poll(&mut fds, 1, 0) };
		if r == 0 {
			return Ok(false);
		}
		if r == 1 {
			return Ok(true);
		}
		let e = io::Error::last_os_error();
		if e.kind() == io::ErrorKind::Interrupted {
			continue;
		}
		return Ok(false);
	}
}

pub(crate) struct ReadProcessor(AsyncFd<c_int>);

impl ReadProcessor {
	pub(crate) fn new(fd: c_int) -> io::Result<Self> {
		Ok(Self(AsyncFd::with_interest(
			fd,
			tokio::io::Interest::READABLE,
		)?))
	}

	/// call "p" until fd is no longer readable
	pub(crate) fn process<P>(&mut self, cx: &mut Context<'_>, mut p: P) -> io::Result<()>
	where
		P: FnMut() -> io::Result<()>,
	{
		loop {
			let mut ready_guard = match self.0.poll_read_ready(cx) {
				Poll::Pending => return Ok(()),
				Poll::Ready(r) => r?,
			};
			while is_readable(*self.0.get_ref())? {
				p()?;
			}
			ready_guard.clear_ready();
			// after clear we need to poll again to be registered!
		}
	}
}
