//! The types of backoff strategies that are supported

use crate::RetryPolicy;
use std::time::Duration;

/// Trait for computing the amount of delay between attempts.
pub trait BackoffStrategy<'a, E> {
    /// The delay type. Will normally be either [`Duration`] or [`RetryPolicy`].
    ///
    /// [`Duration`]: https://doc.rust-lang.org/stable/std/time/struct.Duration.html
    /// [`RetryPolicy`]: ../enum.RetryPolicy.html
    type Output;

    /// Compute the amount of delay given the number of attempts so far and the most previous
    /// error.
    fn delay(&mut self, attempt: u32, error: &'a E) -> Self::Output;
}

/// No backoff. This will make the future be retried immediately without any delay in between
/// attempts.
#[derive(Debug, Clone, Copy)]
pub struct NoBackoff;

impl<'a, E> BackoffStrategy<'a, E> for NoBackoff {
    type Output = Duration;

    #[inline]
    fn delay(&mut self, _attempt: u32, _error: &'a E) -> Duration {
        Duration::new(0, 0)
    }
}

/// Exponential backoff. The delay will double each time.
#[derive(Debug, Clone, Copy)]
pub struct ExponentialBackoff {
    pub(crate) delay: Duration,
}

impl ExponentialBackoff {
    /// Create a new `ExponentialBackoff` with an initial delay.
    pub fn new(initial_delay: Duration) -> Self {
        Self {
            delay: initial_delay,
        }
    }
}

impl<'a, E> BackoffStrategy<'a, E> for ExponentialBackoff {
    type Output = Duration;

    #[inline]
    fn delay(&mut self, _attempt: u32, _error: &'a E) -> Duration {
        let prev_delay = self.delay;
        self.delay = self.delay.saturating_mul(2);
        prev_delay
    }
}

/// Fixed backoff. The delay wont change between attempts.
#[derive(Debug, Clone, Copy)]
pub struct FixedBackoff {
    pub(crate) delay: Duration,
}

impl FixedBackoff {
    /// Create a new `FixedBackoff` with an initial delay.
    pub fn new(initial_delay: Duration) -> Self {
        Self {
            delay: initial_delay,
        }
    }
}

impl<'a, E> BackoffStrategy<'a, E> for FixedBackoff {
    type Output = Duration;

    #[inline]
    fn delay(&mut self, _attempt: u32, _error: &'a E) -> Duration {
        self.delay
    }
}

/// Linear backoff. The delay will scale linearly with the number of attempts.
#[derive(Debug, Clone, Copy)]
pub struct LinearBackoff {
    pub(crate) delay: Duration,
}

impl LinearBackoff {
    /// Create a new `LinearBackoff` with an initial delay.
    pub fn new(initial_delay: Duration) -> Self {
        Self {
            delay: initial_delay,
        }
    }
}

impl<'a, E> BackoffStrategy<'a, E> for LinearBackoff {
    type Output = Duration;

    #[inline]
    fn delay(&mut self, attempt: u32, _error: &'a E) -> Duration {
        self.delay.saturating_mul(attempt)
    }
}

impl<'a, F, E, T> BackoffStrategy<'a, E> for F
where
    E: 'a,
    F: FnMut(u32, &'a E) -> T,
    T: Into<RetryPolicy>,
{
    type Output = RetryPolicy;

    #[inline]
    fn delay(&mut self, attempt: u32, error: &'a E) -> RetryPolicy {
        self(attempt, error).into()
    }
}
