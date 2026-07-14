//! On windows we cannot get read (or write) events for sockets in the
//! IOCP model; we only can run asynchronous reads!
//!
//! So we need to use select() to poll for read, and run it in a
//! separate thread.  To cancel that select() we'd need another socket
//! to select() for, and there is no socketpair() - we could use a
//! loopback TCP connection, but a firewall might block it.
//!
//! Instead we use a small (1 second) timeout for the select; it is only
//! used to terminate the thread anyway.
//!
//! This of course wastes one thread per fd we want to watch; a bigger
//! solution would reuse the same backend thread over and over, but then
//! we'd have to try the loopback TCP connection to wake it and fall
//! back to a smaller timeout.

use futures_channel::mpsc as futures_mpsc;
use futures_util::{
	SinkExt,
	StreamExt,
};
use log::debug;
use std::{
	io,
	os::raw::c_int,
	sync::{
		mpsc as std_mpsc,
		Mutex,
	},
	task::{
		Context,
		Poll,
	},
	thread,
	time::Duration,
};
use winapi::um::winsock2;

use self::fd_set::FdSet;

pub(crate) struct ReadProcessor {
	fd: libc::c_int,
	poll: PollReadFd,
}

impl ReadProcessor {
	pub(crate) fn new(fd: libc::c_int) -> io::Result<Self> {
		Ok(Self {
			fd,
			poll: PollReadFd::new(fd)?,
		})
	}

	/// call "p" until fd is no longer readable
	pub(crate) fn process<P>(&mut self, cx: &mut Context<'_>, mut p: P) -> io::Result<()>
	where
		P: FnMut() -> io::Result<()>,
	{
		match self.poll.poll_read_ready(cx)? {
			Poll::Ready(()) => {
				while is_readable(self.fd)? {
					p()?;
				}
				self.poll.clear_read_ready(cx)?;
			},
			Poll::Pending => (),
		}
		Ok(())
	}
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum PollRequest {
	Poll,
	Close,
}

struct SelectFdRead {
	fd: c_int,
	read_fds: FdSet,
}
impl SelectFdRead {
	pub fn new(fd: c_int) -> Self {
		Self {
			fd,
			read_fds: FdSet::new(),
		}
	}

	pub fn select(&mut self, timeout: Option<Duration>) -> bool {
		use std::ptr::null_mut;
		let mut timeout = timeout.map(|timeout| winsock2::timeval {
			tv_sec: timeout.as_secs() as libc::c_long,
			tv_usec: (timeout.subsec_nanos() / 1000) as libc::c_long,
		});
		self.read_fds.set(self.fd);
		unsafe {
			winsock2::select(
				self.fd + 1,
				self.read_fds.inner(),
				null_mut(),
				null_mut(),
				timeout.as_mut().map(|x| x as *mut _).unwrap_or(null_mut()),
			);
		}
		self.read_fds.is_set(self.fd)
	}
}

struct Inner {
	/// file descriptor to watch read events for
	fd: c_int,
	/// background select thread
	_thread: thread::JoinHandle<()>,
	/// either the select thread is running a Poll request or we manually
	/// sent a response through `send_response`
	pending_request: bool,
	/// send poll or close request to select thread
	send_request: std_mpsc::SyncSender<PollRequest>,
	/// when clear_read_ready() is called we use this to trigger a response if
	/// we already know the read event is pending
	send_response: futures_mpsc::Sender<()>,
	/// a response means a read event is pending
	recv_response: futures_mpsc::Receiver<()>,
}

impl Inner {
	fn poll_read_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		debug!("poll read");
		if !self.pending_request {
			self.pending_request = true;
			let mut read_fds = SelectFdRead::new(self.fd);
			if read_fds.select(Some(Duration::from_millis(0))) {
				debug!("poll read: local ready");
				return Poll::Ready(Ok(()));
			} else {
				debug!("poll read: not ready, start thread");
				self.send_request
					.send(PollRequest::Poll)
					.expect("select thread terminated");
			}
		}

		match self.recv_response.poll_next_unpin(cx) {
			Poll::Ready(None) => unreachable!(), // can't be disconnected
			Poll::Ready(Some(())) => {
				debug!("poll read: thread ready");
				self.pending_request = false;
				Poll::Ready(Ok(()))
			},
			Poll::Pending => {
				debug!("poll read: thread not ready");
				Poll::Pending
			},
		}
	}

	// read() return EAGAIN; re-trigger polling and notify cx
	fn clear_read_ready(&mut self, cx: &mut Context<'_>) -> io::Result<()> {
		// we need to get Poll::Pending from recv_response.poll to make sure `cx` was registered
		match self.recv_response.poll_next_unpin(cx) {
			Poll::Ready(None) => unreachable!(), // can't be disconnected
			Poll::Ready(Some(())) => {
				// was ready. damn...
				assert!(self.pending_request);
				// try again - can't be ready again, but register context
				match self.recv_response.poll_next_unpin(cx) {
					Poll::Ready(None) => unreachable!(),     // can't be disconnected
					Poll::Ready(Some(())) => unreachable!(), // no one could have sent this
					Poll::Pending => (),
				}
				// now send a response - it was ready after all
				self.send_response
					.try_send(())
					.expect("channel can't be full or disconnected");
			},
			Poll::Pending => {
				// yay!
				//
				// already on the way (background thread polling)?
				if !self.pending_request {
					// now we need something to trigger a response
					self.pending_request = true;
					let mut read_fds = SelectFdRead::new(self.fd);
					if read_fds.select(Some(Duration::from_millis(0))) {
						debug!("poll need read: local ready");
						// ready, send a response
						self.send_response
							.try_send(())
							.expect("channel can't be full or disconnected");
					} else {
						debug!("poll need read: not ready, start thread");
						self.send_request
							.send(PollRequest::Poll)
							.expect("select thread terminated");
					}
				}
			},
		}
		Ok(())
	}
}

fn is_readable(fd: c_int) -> io::Result<bool> {
	let mut read_fds = SelectFdRead::new(fd);
	Ok(read_fds.select(Some(Duration::from_millis(0))))
}

struct PollReadFd(Mutex<Inner>);
impl PollReadFd {
	/// does not take overship of fd
	fn new(fd: c_int) -> io::Result<Self> {
		// buffer one request for "Close"
		let (send_request, recv_request) = std_mpsc::sync_channel(1);
		// buffer one notification
		let (mut send_response, recv_response) = futures_mpsc::channel(1);
		let outer_send_response = send_response.clone();

		let thread = thread::spawn(move || {
			let mut read_fds = SelectFdRead::new(fd);
			loop {
				debug!("[select thread] waiting for request");
				match recv_request.recv() {
					Ok(PollRequest::Poll) => (),
					Ok(PollRequest::Close) => return,
					Err(_) => return,
				}
				debug!("[select thread] start polling");

				while !read_fds.select(Some(Duration::from_millis(1000))) {
					match recv_request.try_recv() {
						Ok(PollRequest::Poll) => unreachable!(),
						Ok(PollRequest::Close) => return,
						Err(_) => (), // back to select()
					}
				}

				debug!("[select thread] read event");

				// Can only fail if the other end is dropped
				let _ = futures_executor::block_on(send_response.send(()));
			}
		});

		Ok(Self(Mutex::new(Inner {
			fd,
			_thread: thread,
			pending_request: false,
			send_request,
			send_response: outer_send_response,
			recv_response,
		})))
	}

	fn poll_read_ready(&self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		self.0.lock().expect("mutex poisoned").poll_read_ready(cx)
	}

	fn clear_read_ready(&self, cx: &mut Context<'_>) -> io::Result<()> {
		self.0.lock().expect("mutex poisoned").clear_read_ready(cx)
	}
}

impl Drop for PollReadFd {
	fn drop(&mut self) {
		let _ = self
			.0
			.get_mut()
			.expect("mutex poisoned")
			.send_request
			.send(PollRequest::Close);
	}
}

mod fd_set {
	use libc::{
		c_int,
		c_uint,
	};
	use std::{
		mem::MaybeUninit,
		ptr,
	};
	use winapi::um::winsock2::{
		fd_set,
		u_int,
		FD_SETSIZE,
		SOCKET,
	};

	/// Layout compatible struct of `fd_set`, but it holds maybe uninitialized `fd_array`.
	///
	/// # Safety
	/// The first `fd_count` slots of `fd_array` must be initialized,
	/// and the rest may be uninitialized.
	#[repr(C)]
	pub(super) struct FdSet {
		fd_count: u_int,
		fd_array: [MaybeUninit<SOCKET>; FD_SETSIZE],
	}

	impl FdSet {
		pub fn new() -> Self {
			Self {
				fd_count: 0,
				// safe according to:
				// https://doc.rust-lang.org/std/mem/union.MaybeUninit.html#initializing-an-array-element-by-element
				fd_array: unsafe { MaybeUninit::uninit().assume_init() },
			}
		}

		pub fn inner(&mut self) -> *mut fd_set {
			self as *mut Self as *mut _
		}

		pub fn set(&mut self, fd: c_int) {
			if self.is_set(fd) {
				return;
			}
			let count = self.fd_count as usize;
			if count < FD_SETSIZE {
				let fd = fd as c_uint as SOCKET;
				// This is safe because this slot is uninitialized.
				unsafe { ptr::write(self.fd_array[count].as_mut_ptr(), fd) };
				self.fd_count += 1;
			}
		}

		pub fn is_set(&self, fd: c_int) -> bool {
			let fd = fd as c_uint as SOCKET;
			let count = self.fd_count as usize;
			self.fd_array[..count].iter().any(|slot| {
				// This is safe because it's reading from first `fd_count` slots.
				fd == unsafe { ptr::read(slot.as_ptr()) }
			})
		}
	}

	#[cfg(test)]
	mod tests {
		use super::*;
		use std::mem::{
			needs_drop,
			transmute,
		};

		// Check that `FdSet` is layout compatible with `fd_set`.
		#[test]
		fn fd_set_layout_compatible() {
			let mut fd_set = FdSet::new();
			(0..FD_SETSIZE as c_int).for_each(|i| fd_set.set(i));
			let fd_set: fd_set = unsafe { transmute(fd_set) };
			assert_eq!(fd_set.fd_count, FD_SETSIZE as u32);
			for i in 0..FD_SETSIZE as usize {
				assert_eq!(fd_set.fd_array[i], i as SOCKET);
			}
		}

		// Check that `SOCKET` doesn't need to be dropped, so that we don't need to
		// implement `Drop` for `FdSet`.
		#[test]
		fn socket_not_drop() {
			assert!(!needs_drop::<SOCKET>());
		}
	}
}
