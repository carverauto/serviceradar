#![no_std]

#[cfg(feature = "alloc")]
extern crate alloc;

#[cfg(feature = "alloc")]
use alloc::boxed::Box;
use core::{future::Future, marker::PhantomData, pin::Pin};

/// A [`Future`] super-trait with an implied upper bound on the provided lifetime.
/// This is especially useful for callbacks that use higher-ranked lifetimes in their return type,
/// where it can prevent `'static` bounds from being placed on a returned [`Future`].
///
/// # Example
/// ```
/// # fn test() {
/// use core::pin::Pin;
/// use scoped_futures::{ScopedBoxFuture, ScopedFutureExt};
///
/// pub struct Db {
///     count: u8,
/// }
///
/// impl Db {
///     async fn transaction<'a, F, T, E>(&mut self, callback: F) -> Result<T, E>
///     where
///         // ScopedBoxFuture imposes a lifetime bound on 'b which prevents the hrtb below needing
///         // to be satisfied for all lifetimes (including 'static) and instead only lifetimes
///         // which live at most as long as 'a
///         F: for<'b /* where 'a: 'b */> FnOnce(&'b mut Self) -> ScopedBoxFuture<'a, 'b, Result<T, E>> + Send + 'a,
///         T: 'a,
///         E: 'a,
///     {
///         callback(self).await
///     }
/// }
///
/// pub async fn test_transaction<'a, 'b>(
///     db: &mut Db,
///     ok: &'a str,
///     err: &'b str,
///     is_ok: bool,
/// ) -> Result<&'a str, &'b str> {
///     // note the lack of `move` or any cloning in front of the closure
///     db.transaction(|db| async move {
///         db.count += 1;
///         if is_ok {
///             Ok(ok)
///         } else {
///             Err(err)
///         }
///     }.scope_boxed()).await?;
///
///     // note that `async` can be used instead of `async move` since the callback param is unused
///     db.transaction(|_| async {
///         if is_ok {
///             Ok(ok)
///         } else {
///             Err(err)
///         }
///     }.scope_boxed()).await
/// }
///
/// futures::executor::block_on(async {
///     let mut db = Db { count: 0 };
///     let ok = String::from("ok");
///     let err = String::from("err");
///     let result = test_transaction(&mut db, &ok, &err, true).await;
///     assert_eq!(ok, result.unwrap());
///     assert_eq!(1, db.count);
/// });
/// # } #[cfg(feature = "alloc")] test();
/// ```
pub trait ScopedFuture<'upper_bound, 'subject, Bound = ImpliedLifetimeBound<'upper_bound, 'subject>>: Future
where
    Bound: sealed::Sealed,
{
}

/// A wrapper type which imposes an upper bound on a lifetime.
pub type ImpliedLifetimeBound<'upper_bound, 'subject> = PhantomData<&'subject &'upper_bound ()>;

impl<'upper_bound: 'subject, 'subject, Fut: Future + 'subject> ScopedFuture<'upper_bound, 'subject> for Fut {}

mod sealed {
    pub trait Sealed {}
    impl<'upper_bound, 'a> Sealed for super::ImpliedLifetimeBound<'upper_bound, 'a> {}
}

/// A boxed future whose lifetime is upper bounded.
#[cfg(feature = "alloc")]
pub type ScopedBoxFuture<'upper_bound, 'subject, T> = Pin<Box<dyn ScopedFuture<'upper_bound, 'subject, Output = T> + Send + 'subject>>;

/// A non-[`Send`] boxed future whose lifetime is upper bounded.
#[cfg(feature = "alloc")]
pub type ScopedLocalBoxFuture<'upper_bound, 'subject, T> = Pin<Box<dyn ScopedFuture<'upper_bound, 'subject, Output = T> + 'subject>>;

pin_project_lite::pin_project! {
    /// A [`Future`] wrapper type that imposes an upper bound on its lifetime's duration.
    #[derive(Clone, Debug)]
    pub struct ScopedFutureWrapper<'upper_bound, 'subject, Fut> {
        #[pin]
        future: Fut,
        scope: ImpliedLifetimeBound<'upper_bound, 'subject>,
    }
}

/// An extension trait for [`Future`] that provides methods for encoding lifetime upper bound information.
pub trait ScopedFutureExt: Sized {
    /// Encodes the lifetimes of this [`Future`]'s captures.
    fn scoped<'upper_bound, 'subject>(self) -> ScopedFutureWrapper<'upper_bound, 'subject, Self>;

    /// Boxes this [`Future`] and encodes the lifetimes of its captures.
    #[cfg(feature = "alloc")]
    fn scope_boxed<'upper_bound, 'subject>(self) -> ScopedBoxFuture<'upper_bound, 'subject, <Self as Future>::Output>
    where
        Self: Send + Future + 'subject;

    /// Boxes this [`Future`] and encodes the lifetimes of its captures.
    #[cfg(feature = "alloc")]
    fn scope_boxed_local<'upper_bound, 'subject>(self) -> ScopedLocalBoxFuture<'upper_bound, 'subject, <Self as Future>::Output>
    where
        Self: Future + 'subject;
}

impl<'upper_bound, 'subject, Fut: Future> Future for ScopedFutureWrapper<'upper_bound, 'subject, Fut> {
    type Output = Fut::Output;
    fn poll(self: Pin<&mut Self>, cx: &mut core::task::Context<'_>) -> core::task::Poll<Self::Output> {
        self.project().future.poll(cx)
    }
}

impl<Fut: Future> ScopedFutureExt for Fut {
    fn scoped<'upper_bound, 'subject>(self) -> ScopedFutureWrapper<'upper_bound, 'subject, Self> {
        ScopedFutureWrapper { future: self, scope: PhantomData }
    }

    #[cfg(feature = "alloc")]
    fn scope_boxed<'upper_bound, 'subject>(self) -> ScopedBoxFuture<'upper_bound, 'subject, <Self as Future>::Output>
    where
        Self: Send + Future + 'subject,
    {
        Box::pin(self)
    }

    #[cfg(feature = "alloc")]
    fn scope_boxed_local<'upper_bound, 'subject>(self) -> ScopedLocalBoxFuture<'upper_bound, 'subject, <Self as Future>::Output>
    where
        Self: Future + 'subject,
    {
        Box::pin(self)
    }
}

#[cfg(feature = "alloc")]
const _: () = {
    impl<'upper_bound, 'subject, T, Fut: Future<Output = T> + Send + 'subject> From<Pin<Box<Fut>>> for ScopedBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Pin<Box<Fut>>) -> Self {
            future
        }
    }

    impl<'upper_bound, 'subject, T, Fut: Future<Output = T> + 'subject> From<Pin<Box<Fut>>> for ScopedLocalBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Pin<Box<Fut>>) -> Self {
            future
        }
    }

    impl<'upper_bound, 'subject, T, Fut: Future<Output = T> + Send + 'subject> From<Box<Fut>> for ScopedBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Box<Fut>) -> Self {
            Box::into_pin(future)
        }
    }

    impl<'upper_bound, 'subject, T, Fut: Future<Output = T> + 'subject> From<Box<Fut>> for ScopedLocalBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Box<Fut>) -> Self {
            Box::into_pin(future)
        }
    }

    impl<'upper_bound, 'subject, T: 'subject> From<Pin<Box<dyn Future<Output = T> + Send + 'subject>>> for ScopedBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Pin<Box<dyn Future<Output = T> + Send + 'subject>>) -> Self {
            Box::pin(future)
        }
    }

    impl<'upper_bound, 'subject, T: 'subject> From<Pin<Box<dyn Future<Output = T> + 'subject>>> for ScopedLocalBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Pin<Box<dyn Future<Output = T> + 'subject>>) -> Self {
            Box::pin(future)
        }
    }

    impl<'upper_bound, 'subject, T: 'subject> From<Box<dyn Future<Output = T> + Send + 'subject>> for ScopedBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Box<dyn Future<Output = T> + Send + 'subject>) -> Self {
            Box::into_pin(future).into()
        }
    }

    impl<'upper_bound, 'subject, T: 'subject> From<Box<dyn Future<Output = T> + 'subject>> for ScopedLocalBoxFuture<'upper_bound, 'subject, T> {
        fn from(future: Box<dyn Future<Output = T> + 'subject>) -> Self {
            Box::into_pin(future).into()
        }
    }

    impl<'upper_bound, 'subject, T: 'subject> From<ScopedBoxFuture<'upper_bound, 'subject, T>> for Pin<Box<dyn Future<Output = T> + Send + 'subject>> {
        fn from(future: ScopedBoxFuture<'upper_bound, 'subject, T>) -> Self {
            Box::pin(future)
        }
    }

    impl<'upper_bound, 'subject, T: 'subject> From<ScopedLocalBoxFuture<'upper_bound, 'subject, T>> for Pin<Box<dyn Future<Output = T> + 'subject>> {
        fn from(future: ScopedLocalBoxFuture<'upper_bound, 'subject, T>) -> Self {
            Box::pin(future)
        }
    }
};
