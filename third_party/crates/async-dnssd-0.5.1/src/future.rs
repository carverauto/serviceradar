use futures_channel::oneshot;
use futures_util::FutureExt;
use std::{
	future::Future,
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

type CallbackContext<T> = Option<oneshot::Sender<io::Result<T>>>;

struct Inner<S: EventedService, T> {
	service: S,
	_sender: Box<CallbackContext<T>>,
	receiver: oneshot::Receiver<io::Result<T>>,
}

#[must_use = "futures do nothing unless polled"]
pub(crate) struct ServiceFuture<S: EventedService, T>(Option<Inner<S, T>>);

impl<S: EventedService, T> ServiceFuture<S, T> {
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
		let sender = sender.take().expect("callback must be run only once");

		let data = Error::from(error_code)
			.map_err(io::Error::from)
			.and_then(|()| f());

		sender.send(data).expect("receiver must still be alive");
	}

	pub(crate) fn new<F>(f: F) -> io::Result<Self>
	where
		F: FnOnce(*mut c_void) -> Result<S, Error>,
	{
		let (sender, receiver) = oneshot::channel::<io::Result<T>>();
		let mut sender = Box::new(Some(sender));

		let service = f(box_raw(&mut sender))?;

		Ok(Self(Some(Inner {
			service,
			_sender: sender,
			receiver,
		})))
	}

	pub(crate) fn new_with<R, F>(service: S, f: F) -> io::Result<(Self, R)>
	where
		F: FnOnce(*mut c_void) -> Result<R, Error>,
	{
		let (sender, receiver) = oneshot::channel::<io::Result<T>>();
		let mut sender = Box::new(Some(sender));

		let res = f(box_raw(&mut sender))?;

		Ok((
			Self(Some(Inner {
				service,
				_sender: sender,
				receiver,
			})),
			res,
		))
	}

	fn inner(&self) -> &Inner<S, T> {
		self.0.as_ref().expect("can only get ready once")
	}

	fn inner_mut(&mut self) -> &mut Inner<S, T> {
		self.0.as_mut().expect("can only get ready once")
	}

	pub(crate) fn service(&self) -> &S {
		&self.inner().service
	}
}

impl<S: EventedService, T> Future for ServiceFuture<S, T> {
	type Output = io::Result<(S, T)>;

	fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
		if self.0.is_none() {
			// can only get ready once.
			return Poll::Pending;
		}
		self.inner_mut().service.poll_service(cx)?;
		let item = futures_core::ready!(self.inner_mut().receiver.poll_unpin(cx))
			.expect("send can't die")?;
		Poll::Ready(Ok((self.0.take().unwrap().service, item)))
	}
}
