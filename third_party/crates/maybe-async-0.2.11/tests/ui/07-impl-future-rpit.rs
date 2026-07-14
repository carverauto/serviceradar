#![allow(dead_code)]

#[allow(unused_imports)]
use core::future::Future;
#[allow(unused_imports)]
use core::pin::Pin;

use maybe_async::maybe_async;

// Public trait using the RPIT (return-position impl Future) pattern.
// This avoids the `async_fn_in_trait` warning that fires for `async fn`
// in public traits when using `#[maybe_async(AFIT)]`.
#[maybe_async(AFIT)]
pub trait PubRpitTrait: Sync {
    fn declare_rpit(&self) -> impl Future<Output = ()> + Send + '_;

    fn default_rpit(&self) -> impl Future<Output = ()> + Send + '_ {
        async move { self.declare_rpit().await }
    }
}

// Non-Send variant (no `+ Send` bound).
#[maybe_async(AFIT)]
pub trait PubRpitNotSendTrait {
    fn declare_rpit_nosend(&self) -> impl Future<Output = ()> + '_;

    fn default_rpit_nosend(&self) -> impl Future<Output = ()> + '_ {
        async move { self.declare_rpit_nosend().await }
    }
}

// Mixing RPIT methods with regular sync methods and `async fn` methods.
// `async fn` in trait methods that need Send-able futures require the
// returned future to also be Send; the simplest way to express that
// uniformly is to also use the RPIT form for the declaration.
#[maybe_async(AFIT)]
pub trait MixedTrait: Sync {
    fn sync_fn(&self) {}

    fn async_fn_decl(&self) -> impl Future<Output = ()> + Send + '_;

    fn rpit_fn(&self) -> impl Future<Output = Result<u32, ()>> + Send + '_ {
        async move {
            self.async_fn_decl().await;
            Ok(42)
        }
    }
}

struct Foo;

#[maybe_async(AFIT)]
impl PubRpitTrait for Foo {
    fn declare_rpit(&self) -> impl Future<Output = ()> + Send + '_ {
        async move {}
    }
}

#[maybe_async(AFIT)]
impl PubRpitNotSendTrait for Foo {
    fn declare_rpit_nosend(&self) -> impl Future<Output = ()> + '_ {
        async move {}
    }
}

#[maybe_async(AFIT)]
impl MixedTrait for Foo {
    fn async_fn_decl(&self) -> impl Future<Output = ()> + Send + '_ {
        async move {}
    }
}

// Free function using the RPIT pattern.
#[maybe_async]
fn free_rpit() -> impl Future<Output = u32> {
    async { 7 }
}

// (a) Returned future with `Send + Sync` auto-trait bounds.
#[maybe_async(AFIT)]
pub trait SyncBoundTrait: Sync {
    fn rpit_send_sync(&self) -> impl Future<Output = u32> + Send + Sync + '_;

    fn rpit_send_sync_default(&self) -> impl Future<Output = u32> + Send + Sync + '_ {
        async move { self.rpit_send_sync().await }
    }
}

#[maybe_async(AFIT)]
impl SyncBoundTrait for Foo {
    fn rpit_send_sync(&self) -> impl Future<Output = u32> + Send + Sync + '_ {
        async move { 1 }
    }
}

// (b) Boxed `dyn Future` return types — the form `async-trait` produces.
#[maybe_async(AFIT)]
pub trait BoxedTrait: Sync {
    fn pin_box_decl(&self) -> Pin<Box<dyn Future<Output = u32> + Send + '_>>;

    fn pin_box_default(&self) -> Pin<Box<dyn Future<Output = u32> + Send + '_>> {
        Box::pin(async move { self.pin_box_decl().await + 1 })
    }

    // Bare `Box<dyn Future + Send>` (not pin-wrapped). Less common because
    // the returned value isn't directly awaitable without manual pinning,
    // but the return-type rewriting should still strip it in sync mode.
    fn box_new_default(&self) -> Box<dyn Future<Output = u32> + Send + '_> {
        Box::new(async move { 9 })
    }
}

#[maybe_async(AFIT)]
impl BoxedTrait for Foo {
    fn pin_box_decl(&self) -> Pin<Box<dyn Future<Output = u32> + Send + '_>> {
        Box::pin(async move { 5 })
    }
}

// Free function returning `Pin<Box<dyn Future>>`.
#[maybe_async]
fn boxed_free() -> Pin<Box<dyn Future<Output = u32>>> {
    Box::pin(async { 11 })
}

#[cfg(feature = "is_sync")]
fn main() {
    let f = Foo;
    f.declare_rpit();
    f.default_rpit();
    f.declare_rpit_nosend();
    f.default_rpit_nosend();
    f.sync_fn();
    f.async_fn_decl();
    let _ = f.rpit_fn();
    let _ = free_rpit();
    let _ = f.rpit_send_sync();
    let _ = f.rpit_send_sync_default();
    let _ = f.pin_box_decl();
    let _ = f.pin_box_default();
    let _ = f.box_new_default();
    let _ = boxed_free();
}

#[cfg(not(feature = "is_sync"))]
#[async_std::main]
async fn main() {
    let f = Foo;
    f.declare_rpit().await;
    f.default_rpit().await;
    f.declare_rpit_nosend().await;
    f.default_rpit_nosend().await;
    f.sync_fn();
    f.async_fn_decl().await;
    let _ = f.rpit_fn().await;
    let _ = free_rpit().await;
    let _ = f.rpit_send_sync().await;
    let _ = f.rpit_send_sync_default().await;
    let _ = f.pin_box_decl().await;
    let _ = f.pin_box_default().await;
    // `box_new_default` returns `Box<dyn Future + Send>` which is not directly
    // awaitable without manual pinning; just confirm it's callable.
    let _ = f.box_new_default();
    let _ = boxed_free().await;
}
