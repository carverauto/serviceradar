// tokio::sync::Notify hides `Notified` and also uses lifetimes;
// we need 'static lifetime and explicit types.

use std::{
	future::Future,
	pin::Pin,
	sync::Arc,
	task::{
		Context,
		Poll,
	},
};

type NotifiedBox<'a> = Pin<Box<dyn Future<Output = ()> + Send + 'a>>;

pub struct Notify {
	notify: Arc<tokio::sync::Notify>,
}

impl Notify {
	pub fn new() -> Self {
		Self {
			notify: Arc::new(tokio::sync::Notify::new()),
		}
	}

	pub fn notified(&self) -> Notified {
		Notified {
			notify: self.notify.clone(),
			notified: None,
		}
	}

	pub fn notify_waiters(&self) {
		self.notify.notify_waiters();
	}
}

pub struct Notified {
	notify: Arc<tokio::sync::Notify>,
	notified: Option<NotifiedBox<'static>>,
}

impl Drop for Notified {
	fn drop(&mut self) {
		// make sure we drop `Notified` first as we cheated the lifetime
		drop(self.notified.take());
	}
}

impl Clone for Notified {
	fn clone(&self) -> Self {
		Self {
			notify: self.notify.clone(),
			notified: None,
		}
	}
}

impl Future for Notified {
	type Output = ();

	fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
		let this: &mut Self = &mut self;
		if this.notified.is_none() {
			let notified: NotifiedBox<'_> = Box::pin(this.notify.notified());
			// convert to static lifetime: we make sure to keep the Arc<Notify> alive
			// until `notified` is gone.
			let notified =
				unsafe { std::mem::transmute::<NotifiedBox<'_>, NotifiedBox<'static>>(notified) };
			this.notified = Some(notified);
		}
		this.notified.as_mut().unwrap().as_mut().poll(cx)
	}
}
