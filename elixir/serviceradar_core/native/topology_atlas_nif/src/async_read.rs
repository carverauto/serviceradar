//! Asynchronous `read_graph`, the one atlas entry point that talks to Dgraph.
//!
//! It used to block a dirty-IO scheduler for the whole paged read; a stalled
//! Dgraph held that scheduler until the read returned. Now the NIF returns
//! `{:ok, ref, handle}` at once and the read replies by message
//! `{:dgraph_nif_reply, ref, {:ok, graph} | {:error, reason}, {kind, 0, elapsed_us}}`,
//! the same protocol as `ServiceRadar.Dgraph.Native`, so the Elixir side shares
//! one waiting/cancelling implementation. The `GRAPH_READ` admission permit is
//! held by the read itself and released only when it returns, times out, is
//! cancelled or unwinds.

use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::pin::Pin;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Mutex;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

const CONNECT_DEADLINE: Duration = Duration::from_secs(10);

use dgraph_topology::{TopologyClient, TopologyView};
use rustler::env::OwnedEnv;
use rustler::{Atom, Encoder, Env, LocalPid, Monitor, Resource, ResourceArc, Term};
use tokio::task::AbortHandle;

use crate::admission::GRAPH_READ;
use crate::model::Result;
use crate::{runtime, GraphResource};

mod atoms {
    rustler::atoms! {ok, error, busy, timeout, panic, cancelled, replying, dgraph_nif_reply}
}

const RUNNING: u8 = 0;
const REPLYING: u8 = 1;
const CANCELLED: u8 = 2;

pub(crate) struct ReadHandle {
    state: AtomicU8,
    abort: Mutex<Option<AbortHandle>>,
}

#[rustler::resource_impl]
impl Resource for ReadHandle {
    const IMPLEMENTS_DOWN: bool = true;

    /// The caller exited while waiting: abort the read and free the
    /// GRAPH_READ permit now rather than at the deadline.
    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        let _ = self.cancel();
    }
}

impl ReadHandle {
    fn new() -> Self {
        Self {
            state: AtomicU8::new(RUNNING),
            abort: Mutex::new(None),
        }
    }

    fn claim_reply(&self) -> bool {
        self.state
            .compare_exchange(RUNNING, REPLYING, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    fn cancel(&self) -> bool {
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
}

/// How a read ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    Ok,
    Timeout,
    Error,
    Panic,
}

struct CatchUnwind<F>(Pin<Box<F>>);

impl<F: Future> Future for CatchUnwind<F> {
    type Output = std::result::Result<F::Output, ()>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let inner = self.get_mut().0.as_mut();
        match catch_unwind(AssertUnwindSafe(|| inner.poll(cx))) {
            Ok(Poll::Pending) => Poll::Pending,
            Ok(Poll::Ready(value)) => Poll::Ready(Ok(value)),
            Err(_) => Poll::Ready(Err(())),
        }
    }
}

/// Connect and read the topology view, bounded by `deadline` and isolated from
/// panics.
pub(crate) async fn read_topology_view(
    url: &str,
    stale_cutoff: &str,
    deadline: Duration,
) -> (Result<TopologyView>, Kind) {
    let entry = Instant::now();
    let connect_deadline = CONNECT_DEADLINE.min(deadline);
    let connect = CatchUnwind(Box::pin(TopologyClient::connect(url)));
    let client = match tokio::time::timeout(connect_deadline, connect).await {
        Ok(Ok(Ok(c))) => c,
        Ok(Ok(Err(err))) => return (Err(err.to_string()), Kind::Error),
        Ok(Err(())) => {
            return (
                Err("topology view connect panicked (call isolated)".into()),
                Kind::Panic,
            )
        }
        Err(_elapsed) => {
            return (
                Err(format!(
                    "dgraph connect timed out after {}ms",
                    connect_deadline.as_millis()
                )),
                Kind::Timeout,
            )
        }
    };
    let remaining = deadline.saturating_sub(entry.elapsed());
    if remaining.is_zero() {
        return (
            Err(format!(
                "topology view read timed out after {}ms",
                deadline.as_millis()
            )),
            Kind::Timeout,
        );
    }
    let read = async move { client.query_topology_view(stale_cutoff).await };
    match tokio::time::timeout(remaining, CatchUnwind(Box::pin(read))).await {
        Ok(Ok(Ok(graph))) => (Ok(graph), Kind::Ok),
        Ok(Ok(Err(_))) => (Err("topology view read failed".into()), Kind::Error),
        Ok(Err(())) => (
            Err("topology view read panicked (call isolated)".into()),
            Kind::Panic,
        ),
        Err(_elapsed) => (
            Err(format!(
                "topology view read timed out after {}ms",
                deadline.as_millis()
            )),
            Kind::Timeout,
        ),
    }
}

fn kind_atom(kind: Kind) -> Atom {
    match kind {
        Kind::Ok => atoms::ok(),
        Kind::Timeout => atoms::timeout(),
        Kind::Error => atoms::error(),
        Kind::Panic => atoms::panic(),
    }
}

#[rustler::nif]
fn read_graph(env: Env<'_>, url: String, stale_cutoff: String, deadline_ms: u64) -> Term<'_> {
    if url.trim().is_empty() {
        return (atoms::error(), "dgraph url is not configured").encode(env);
    }
    let Some(permit) = GRAPH_READ.try_acquire() else {
        return (atoms::error(), atoms::busy()).encode(env);
    };
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    let pid = env.pid();
    let reference = env.make_ref();
    let mut reply_env = OwnedEnv::new();
    let saved_ref = reply_env.save(reference);
    let handle = ResourceArc::new(ReadHandle::new());
    let task_handle = handle.clone();
    let deadline = Duration::from_millis(deadline_ms);

    let task = runtime.spawn(async move {
        let started = Instant::now();
        let (result, kind) = read_topology_view(&url, &stale_cutoff, deadline).await;
        drop(permit);
        let elapsed = u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX);
        let result = result.map(|graph| ResourceArc::new(GraphResource(Mutex::new(Some(graph)))));
        if task_handle.claim_reply() {
            let _ = reply_env.send_and_clear(&pid, move |env| {
                let reply = match result {
                    Ok(graph) => (atoms::ok(), graph).encode(env),
                    Err(reason) => (atoms::error(), reason).encode(env),
                };
                (
                    atoms::dgraph_nif_reply(),
                    saved_ref.load(env),
                    reply,
                    (kind_atom(kind), 0_u64, elapsed),
                )
                    .encode(env)
            });
        }
    });
    if let Ok(mut abort) = handle.abort.lock() {
        *abort = Some(task.abort_handle());
    }
    // A monitor on the caller cancels the read if it exits before the reply.
    let _ = handle.monitor(Some(env), &pid);
    (atoms::ok(), reference, handle).encode(env)
}

/// `:cancelled` means no reply will ever arrive; `:replying` means it has been
/// or is being sent and must be collected.
#[rustler::nif]
fn cancel_read(handle: ResourceArc<ReadHandle>) -> Atom {
    if handle.cancel() {
        atoms::cancelled()
    } else {
        atoms::replying()
    }
}
