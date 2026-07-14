use std::{
    convert::Infallible,
    future::{Future, Ready},
    time::Duration,
};

/// Trait allowing you to run some future when a retry occurs. Could for example to be used for
/// logging or other kinds of telemetry.
///
/// You wont have to implement this trait manually. It is implemented for functions with the right
/// signature. See [`RetryFuture::on_retry`](struct.RetryFuture.html#method.on_retry) for more details.
pub trait OnRetry<E> {
    /// The type of the future you want to run.
    type Future: Future<Output = ()> + Send + 'static;

    /// Create another future to run.
    ///
    /// If `next_delay` is `None` then your future is out of retries and wont be called again.
    fn on_retry(
        &mut self,
        attempt: u32,
        next_delay: Option<Duration>,
        previous_error: &E,
    ) -> Self::Future;
}

/// A sentinel value that represents doing nothing in between retries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoOnRetry {
    cannot_exist: Infallible,
}

impl<E> OnRetry<E> for NoOnRetry {
    type Future = Ready<()>;

    #[inline]
    fn on_retry(&mut self, _: u32, _: Option<Duration>, _: &E) -> Self::Future {
        match self.cannot_exist {}
    }
}

impl<F, E, FutureT> OnRetry<E> for F
where
    F: Fn(u32, Option<Duration>, &E) -> FutureT,
    FutureT: Future<Output = ()> + Send + 'static,
    FutureT::Output: Send + 'static,
{
    type Future = FutureT;

    #[inline]
    fn on_retry(
        &mut self,
        attempts: u32,
        next_delay: Option<Duration>,
        previous_error: &E,
    ) -> Self::Future {
        self(attempts, next_delay, previous_error)
    }
}
