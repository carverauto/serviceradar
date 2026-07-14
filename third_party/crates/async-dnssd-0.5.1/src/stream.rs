use futures_channel::mpsc;
use futures_util::StreamExt;
use std::{
	io,
	os::raw::c_void,
	pin::Pin,
	task::{
		Context,
		Poll,
	},
};

use crate::{
	error::Error,
	ffi,
	inner::EventedService,
};

#[allow(clippy::borrowed_box)]
fn box_raw<T>(ptr: &mut Box<T>) -> *mut c_void {
	ptr.as_mut() as *mut T as *mut c_void
}

type CallbackContext<T> = mpsc::UnboundedSender<io::Result<T>>;

#[must_use = "streams do nothing unless polled"]
pub(crate) struct ServiceStream<S: EventedService, T> {
	service: S,
	_sender: Box<CallbackContext<T>>,
	receiver: mpsc::UnboundedReceiver<io::Result<T>>,
}

impl<S: EventedService, T> ServiceStream<S, T> {
	pub(crate) unsafe fn run_callback<F>(
		context: *mut c_void,
		error_code: ffi::DNSServiceErrorType,
		f: F,
	) where
		F: FnOnce() -> io::Result<T>,
		T: ::std::fmt::Debug,
	{
		let sender = context as *mut CallbackContext<T>;
		let sender: &mut CallbackContext<T> = &mut *sender;

		let data = Error::from(error_code)
			.map_err(io::Error::from)
			.and_then(|()| f());

		sender
			.unbounded_send(data)
			.expect("receiver must still be alive");
	}

	pub(crate) fn new<F>(f: F) -> io::Result<Self>
	where
		F: FnOnce(*mut c_void) -> Result<S, Error>,
	{
		let (sender, receiver) = mpsc::unbounded::<io::Result<T>>();
		let mut sender = Box::new(sender);

		let service = f(box_raw(&mut sender))?;

		Ok(Self {
			service,
			_sender: sender,
			receiver,
		})
	}
}

impl<S: EventedService, T> futures_core::Stream for ServiceStream<S, T> {
	type Item = io::Result<T>;

	fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
		self.service.poll_service(cx)?;
		self.receiver.poll_next_unpin(cx)
	}
}
