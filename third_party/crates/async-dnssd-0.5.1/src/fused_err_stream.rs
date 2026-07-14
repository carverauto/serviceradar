use futures_core::{
	Stream,
	TryStream,
};
use std::{
	pin::Pin,
	task::{
		Context,
		Poll,
	},
};

enum Inner<E, S> {
	Err(Option<E>),
	Stream(S),
}

pub(crate) struct FusedErrorStream<S: TryStream>(Inner<S::Error, S>);

impl<S: TryStream> From<Result<S, S::Error>> for FusedErrorStream<S> {
	fn from(r: Result<S, S::Error>) -> Self {
		match r {
			Ok(s) => Self(Inner::Stream(s)),
			Err(e) => Self(Inner::Err(Some(e))),
		}
	}
}

impl<S, T, E> Stream for FusedErrorStream<S>
where
	S: Stream<Item = Result<T, E>>,
	E: Unpin,
{
	type Item = S::Item;

	fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
		match &mut unsafe { self.get_unchecked_mut() }.0 {
			Inner::Err(e) => {
				// "error variant" is `Unpin`; extract error and fuse stream
				match e.take() {
					Some(e) => Poll::Ready(Some(Err(e))),
					None => Poll::Ready(None), // error already returned before
				}
			},
			Inner::Stream(s) => unsafe { Pin::new_unchecked(s) }.poll_next(cx),
		}
	}
}
