// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Asynchronous Dgraph NIF calls.
//!
//! A Dgraph NIF validates its arguments, spawns the call onto the Dgraph
//! runtime and returns `{:ok, ref, handle}` straight away, on a normal
//! scheduler. The call later sends exactly one
//! `{:dgraph_nif_reply, ref, result, {kind, queue_wait_us, elapsed_us}}` to the
//! caller, unless the caller cancelled it first. A stalled Dgraph therefore
//! holds no BEAM scheduler at all, whatever the number of stalled calls: the
//! blocking version held one dirty-IO scheduler per call, and with all of them
//! taken, file I/O and every other dirty-IO NIF stalled node-wide.
//!
//! Every call is bounded by the deadline the caller passes. Waiting for one of
//! the in-flight slots counts against it, so backpressure cannot turn into an
//! unbounded queue.
//!
//! Cancellation and the reply race: the call and `cancel/1` both try to move
//! the handle out of `RUNNING`. Whichever wins decides, so either no reply is
//! ever sent (`:cancelled`), or one is already on its way (`:replying`) and the
//! caller collects it. A cancelled caller can therefore never be left with a
//! late reply in its mailbox.

use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::pin::Pin;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use rustler::env::OwnedEnv;
use rustler::{Atom, Encoder, Env, Resource, ResourceArc, Term};
use tokio::sync::Semaphore;
use tokio::task::AbortHandle;

use crate::runtime::{in_flight, runtime, Failure};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        timeout,
        transient,
        panic,
        cancelled,
        replying,
        dgraph_nif_reply,
    }
}

/// How an attempt ended, for the Elixir retry policy and telemetry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Ok,
    Timeout,
    Transient,
    Error,
    Panic,
}

impl Kind {
    fn atom(self) -> Atom {
        match self {
            Self::Ok => atoms::ok(),
            Self::Timeout => atoms::timeout(),
            Self::Transient => atoms::transient(),
            Self::Error => atoms::error(),
            Self::Panic => atoms::panic(),
        }
    }
}

/// The outcome of one attempt.
#[derive(Debug)]
pub struct Report<T> {
    pub result: Result<T, String>,
    pub kind: Kind,
    /// Time spent waiting for an in-flight slot (the whole call when it never
    /// got one).
    pub queue_wait: Duration,
    pub elapsed: Duration,
}

/// Run `work` under the in-flight limit and `deadline`, isolating panics.
///
/// `work` receives what is left of the deadline once a slot is free, so it can
/// bound its own connect step by it.
pub async fn execute<T, Fut>(
    permits: Arc<Semaphore>,
    deadline: Duration,
    work: impl FnOnce(Duration) -> Fut,
) -> Report<T>
where
    Fut: Future<Output = Result<T, Failure>>,
{
    let started = Instant::now();
    let mut queue_wait = None;
    let attempt = async {
        let _permit = permits
            .acquire()
            .await
            .map_err(|_| Failure::Error("dgraph call limit closed".to_string()))?;
        let waited = started.elapsed();
        queue_wait = Some(waited);
        work(deadline.saturating_sub(waited)).await
    };
    let outcome = tokio::time::timeout(deadline, CatchUnwind(Box::pin(attempt))).await;
    let elapsed = started.elapsed();
    let queue_wait_was = queue_wait;
    let (result, kind) = match outcome {
        Ok(Ok(Ok(value))) => (Ok(value), Kind::Ok),
        Ok(Ok(Err(Failure::Timeout(reason)))) => (Err(reason), Kind::Timeout),
        Ok(Ok(Err(Failure::Transient(reason)))) => (Err(reason), Kind::Transient),
        Ok(Ok(Err(Failure::Error(reason)))) => (Err(reason), Kind::Error),
        Ok(Err(Panicked)) => (
            Err("dgraph nif panicked (call isolated)".to_string()),
            Kind::Panic,
        ),
        Err(_elapsed) => {
            let phase = if queue_wait_was.is_some() {
                ""
            } else {
                " waiting for an in-flight slot"
            };
            (
                Err(format!(
                    "dgraph call timed out after {}ms{phase}",
                    deadline.as_millis()
                )),
                Kind::Timeout,
            )
        }
    };
    Report {
        result,
        kind,
        queue_wait: queue_wait_was.unwrap_or(elapsed),
        elapsed,
    }
}

/// A panic raised while polling the call.
#[derive(Debug)]
pub struct Panicked;

/// Polls the call inside `catch_unwind`, so a panic becomes a reply rather
/// than a silently dead task that leaves its caller waiting.
struct CatchUnwind<F>(Pin<Box<F>>);

impl<F: Future> Future for CatchUnwind<F> {
    type Output = Result<F::Output, Panicked>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let inner = self.get_mut().0.as_mut();
        match catch_unwind(AssertUnwindSafe(|| inner.poll(cx))) {
            Ok(Poll::Pending) => Poll::Pending,
            Ok(Poll::Ready(value)) => Poll::Ready(Ok(value)),
            Err(_) => Poll::Ready(Err(Panicked)),
        }
    }
}

const RUNNING: u8 = 0;
const REPLYING: u8 = 1;
const CANCELLED: u8 = 2;

/// The caller's handle on one in-flight call.
pub struct CallHandle {
    state: AtomicU8,
    abort: Mutex<Option<AbortHandle>>,
}

#[rustler::resource_impl]
impl Resource for CallHandle {}

impl CallHandle {
    pub fn new() -> Self {
        Self {
            state: AtomicU8::new(RUNNING),
            abort: Mutex::new(None),
        }
    }

    /// The call claims the right to reply. False once cancelled.
    pub fn claim_reply(&self) -> bool {
        self.state
            .compare_exchange(RUNNING, REPLYING, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    /// The caller cancels. False when the reply is already on its way.
    pub fn cancel(&self) -> bool {
        if self
            .state
            .compare_exchange(RUNNING, CANCELLED, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return false;
        }
        if let Ok(mut abort) = self.abort.lock() {
            if let Some(handle) = abort.take() {
                handle.abort();
            }
        }
        true
    }

    fn set_abort(&self, handle: AbortHandle) {
        if let Ok(mut abort) = self.abort.lock() {
            *abort = Some(handle);
        }
    }
}

impl Default for CallHandle {
    fn default() -> Self {
        Self::new()
    }
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

/// Spawn `work` and return `{:ok, ref, handle}`; `finish` shapes the reply
/// term from the call's result.
pub fn submit<'a, T, R, Fut>(
    env: Env<'a>,
    deadline_ms: u64,
    work: impl FnOnce(Duration) -> Fut + Send + 'static,
    finish: impl FnOnce(Result<T, String>) -> R + Send + 'static,
) -> Term<'a>
where
    Fut: Future<Output = Result<T, Failure>> + Send + 'static,
    T: Send + 'static,
    R: Encoder,
{
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    let pid = env.pid();
    let reference = env.make_ref();
    let mut reply_env = OwnedEnv::new();
    let saved_ref = reply_env.save(reference);
    let handle = ResourceArc::new(CallHandle::new());
    let task_handle = handle.clone();
    let deadline = Duration::from_millis(deadline_ms);
    let permits = in_flight();

    let task = runtime.spawn(async move {
        let report = execute(permits, deadline, work).await;
        if task_handle.claim_reply() {
            let stats = (
                report.kind.atom(),
                micros(report.queue_wait),
                micros(report.elapsed),
            );
            let result = report.result;
            // Fails only when the caller has exited, and then nobody is waiting.
            let _ = reply_env.send_and_clear(&pid, move |env| {
                (
                    atoms::dgraph_nif_reply(),
                    saved_ref.load(env),
                    finish(result),
                    stats,
                )
                    .encode(env)
            });
        }
    });
    handle.set_abort(task.abort_handle());
    (atoms::ok(), reference, handle).encode(env)
}

/// Cancel an in-flight call: `:cancelled` means no reply will ever arrive;
/// `:replying` means it has been or is being sent and must be collected.
#[rustler::nif]
fn cancel(handle: ResourceArc<CallHandle>) -> Atom {
    if handle.cancel() {
        atoms::cancelled()
    } else {
        atoms::replying()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use tokio::sync::Semaphore;

    use super::{execute, CallHandle, Kind};
    use crate::runtime::Failure;

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .expect("test runtime")
            .block_on(future)
    }

    #[test]
    fn a_stalled_call_is_cut_off_at_its_deadline() {
        let report = block_on(execute(
            Arc::new(Semaphore::new(1)),
            Duration::from_millis(100),
            |_| std::future::pending::<Result<(), Failure>>(),
        ));
        assert_eq!(report.kind, Kind::Timeout);
        assert_eq!(
            report.result,
            Err("dgraph call timed out after 100ms".to_string())
        );
        assert!(report.elapsed < Duration::from_secs(2));
    }

    #[test]
    fn excess_calls_wait_for_a_slot_instead_of_being_refused() {
        block_on(async {
            let permits = Arc::new(Semaphore::new(1));
            let (release_tx, release_rx) = tokio::sync::oneshot::channel::<()>();
            let first = execute(permits.clone(), Duration::from_secs(5), |_| async move {
                let _ = release_rx.await;
                Ok::<_, Failure>("first")
            });
            let second = execute(permits.clone(), Duration::from_secs(5), |_| async {
                Ok::<_, Failure>("second")
            });
            let release = async move {
                // Let both calls start; the second is now queued behind the first.
                tokio::task::yield_now().await;
                assert_eq!(permits.available_permits(), 0);
                let _ = release_tx.send(());
            };
            let (first, second, ()) = tokio::join!(first, second, release);
            assert_eq!(first.result, Ok("first"));
            assert_eq!(second.result, Ok("second"));
            assert_eq!(second.kind, Kind::Ok);
        });
    }

    #[test]
    fn queue_wait_counts_against_the_deadline() {
        block_on(async {
            let permits = Arc::new(Semaphore::new(1));
            let held = permits.clone().acquire_owned().await.expect("permit");
            let started = Instant::now();
            let mut ran = false;
            let report = execute(permits.clone(), Duration::from_millis(100), |_| {
                ran = true;
                async { Ok::<_, Failure>(()) }
            })
            .await;
            assert!(!ran, "work must not start without a slot");
            assert_eq!(report.kind, Kind::Timeout);
            assert!(
                matches!(&report.result, Err(reason) if reason.contains("waiting for an in-flight slot")),
                "{:?}",
                report.result
            );
            assert!(report.queue_wait >= Duration::from_millis(100));
            assert!(started.elapsed() < Duration::from_secs(2));
            drop(held);
            assert_eq!(permits.available_permits(), 1);
        });
    }

    #[test]
    fn work_gets_the_deadline_left_after_queueing() {
        let remaining = block_on(execute(
            Arc::new(Semaphore::new(1)),
            Duration::from_secs(30),
            |remaining| async move { Ok::<_, Failure>(remaining) },
        ));
        let remaining = remaining.result.expect("ran");
        assert!(remaining <= Duration::from_secs(30));
        assert!(remaining > Duration::from_secs(29));
    }

    #[test]
    fn a_panicking_call_reports_and_releases_its_slot() {
        let permits = Arc::new(Semaphore::new(1));
        let report = block_on(execute(
            permits.clone(),
            Duration::from_secs(5),
            |_| async { panic!("synthetic native failure") },
        ));
        let report: super::Report<()> = report;
        assert_eq!(report.kind, Kind::Panic);
        assert!(matches!(&report.result, Err(reason) if reason.contains("panicked")));
        assert_eq!(permits.available_permits(), 1);
    }

    #[test]
    fn failures_keep_their_retry_classification() {
        for (failure, kind) in [
            (Failure::Transient("unreachable".into()), Kind::Transient),
            (Failure::Timeout("connect".into()), Kind::Timeout),
            (Failure::Error("refused".into()), Kind::Error),
        ] {
            let report = block_on(execute(
                Arc::new(Semaphore::new(1)),
                Duration::from_secs(5),
                move |_| async move { Err::<(), _>(failure) },
            ));
            assert_eq!(report.kind, kind);
        }
    }

    #[test]
    fn cancel_and_reply_are_mutually_exclusive() {
        let cancelled = CallHandle::new();
        assert!(cancelled.cancel());
        assert!(!cancelled.claim_reply(), "a cancelled call must not reply");

        let replying = CallHandle::new();
        assert!(replying.claim_reply());
        assert!(!replying.cancel(), "a reply in flight must be collected");
    }
}
