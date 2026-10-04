//! NATS JetStream KV-backed [`netflow_parser::TemplateStore`].
//!
//! `netflow_parser` exposes a synchronous trait so it can be plugged in from
//! anywhere in the parser hot path. `async_nats`, the NATS client we use
//! everywhere else in the flow collector, is async-only. This module bridges
//! the two with a bounded message-passing bridge to a dedicated worker
//! thread. The worker owns a small Tokio runtime for NATS I/O; parser calls
//! wait synchronously for its reply without ever driving async NATS work on
//! the collector's ingest runtime.
//!
//! # Why this exists
//!
//! With multiple flow-collector replicas behind a UDP load balancer, each
//! replica needs to observe the templates that any other replica has
//! learned — otherwise a data record routed to a fresh pod is dropped or
//! queued for the template definition that already lives in another
//! replica's in-process cache. NATS KV gives us a shared template tier
//! that survives both pod restarts and per-source-affinity routing
//! decisions made above us.
//!
//! See `netflow_parser::template_store` for the read-through / write-through
//! protocol the parser implements on top of this trait.

use crate::config::{Config, TemplateStoreConfig};
use crate::nats_client;
use anyhow::{Context, Result};
use async_nats::jetstream::{self, kv::Store};
use log::warn;
use netflow_parser::{TemplateKind, TemplateStore, TemplateStoreError, TemplateStoreKey};
use std::cell::Cell;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Mutex, Once};
use std::thread;
use std::time::{Duration, Instant};
use tokio::sync::mpsc as tokio_mpsc;

/// Hard bound on any single KV round-trip.
///
/// These calls run on the packet path *while the parser mutex is held*, so a
/// slow NATS stalls every datagram on that listener, not just this one. The
/// async-nats default request timeout is 5s, which is far too long to hold
/// the parse lock for. Failing fast turns a NATS outage into "degrade to the
/// in-process cache" instead of "stop ingesting": the parser treats a
/// `Backend` error as a miss and carries on, and the failure is visible as
/// `flow_collector_template_store_backend_errors_total`.
const KV_OP_TIMEOUT: Duration = Duration::from_millis(500);
const DATAGRAM_KV_TIMEOUT: Duration = Duration::from_millis(100);
const DATAGRAM_KV_OPERATIONS: usize = 16;
const GLOBAL_KV_OPERATIONS_PER_SECOND: usize = 128;
const MAX_TEMPLATE_VALUE_BYTES: usize = 1024 * 1024;
static BUDGET_REJECTIONS: AtomicU64 = AtomicU64::new(0);
static MUTATION_FAILURES: AtomicU64 = AtomicU64::new(0);
static BUCKET_BYTES: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy)]
struct PacketBudget {
    deadline: Instant,
    remaining: usize,
}

thread_local! {
    static PACKET_BUDGET: Cell<Option<PacketBudget>> = const { Cell::new(None) };
}

/// One shared allowance for all synchronous store calls made while parsing a packet.
/// The parser also calls the store for implicit evictions and withdrawals.
pub(crate) struct DatagramBudget(Option<PacketBudget>);

impl DatagramBudget {
    pub(crate) fn begin() -> Self {
        Self(PACKET_BUDGET.replace(Some(PacketBudget {
            deadline: Instant::now() + DATAGRAM_KV_TIMEOUT,
            remaining: DATAGRAM_KV_OPERATIONS,
        })))
    }
}

impl Drop for DatagramBudget {
    fn drop(&mut self) {
        PACKET_BUDGET.set(self.0);
    }
}

#[derive(Debug)]
struct RateBudget {
    since: Instant,
    remaining: usize,
}

impl Default for RateBudget {
    fn default() -> Self {
        Self {
            since: Instant::now(),
            remaining: GLOBAL_KV_OPERATIONS_PER_SECOND,
        }
    }
}

pub(crate) fn metrics() -> (u64, u64, u64) {
    (
        BUDGET_REJECTIONS.load(Ordering::Relaxed),
        MUTATION_FAILURES.load(Ordering::Relaxed),
        BUCKET_BYTES.load(Ordering::Relaxed),
    )
}

#[derive(Debug)]
struct KvWork {
    operation: KvOperation,
    deadline: Instant,
}
const KV_WORK_QUEUE_CAPACITY: usize = 64;

type WorkerResult<T> = Result<T, String>;

#[derive(Debug)]
enum KvOperation {
    Get {
        key: String,
        reply: SyncSender<WorkerResult<Option<Vec<u8>>>>,
    },
    Put {
        key: String,
        value: bytes::Bytes,
        reply: SyncSender<WorkerResult<()>>,
    },
    Remove {
        key: String,
        reply: SyncSender<WorkerResult<()>>,
    },
}

#[derive(Debug)]
struct SyncWorker<T> {
    sender: tokio_mpsc::Sender<T>,
}

impl<T: Send + 'static> SyncWorker<T> {
    fn try_send(&self, message: T) -> io::Result<()> {
        self.sender.try_send(message).map_err(|error| match error {
            tokio_mpsc::error::TrySendError::Full(_) => {
                io::Error::new(io::ErrorKind::WouldBlock, "NATS KV worker queue is full")
            }
            tokio_mpsc::error::TrySendError::Closed(_) => {
                io::Error::new(io::ErrorKind::BrokenPipe, "NATS KV worker has stopped")
            }
        })
    }

    fn from_sender(sender: tokio_mpsc::Sender<T>) -> Self {
        Self { sender }
    }
}

/// Run `body` on a dedicated thread whose current-thread Tokio runtime stays
/// driven for the worker's entire lifetime.
///
/// The "stays driven" part is the whole point. `async_nats` spawns its
/// connection handler as a background task, and on a current-thread runtime a
/// spawned task only makes progress while the runtime is actually being
/// polled. Waiting for the next request on a *blocking* channel between
/// operations would freeze that handler, so the client would stop answering
/// server PINGs and NATS would drop the connection after roughly two ping
/// intervals -- which, on a collector seeing sparse exporter traffic, is the
/// steady state rather than an edge case. Keeping one `block_on` around the
/// receive loop means the handler is polled whenever the worker is idle.
fn spawn_driven_worker<T, F, Fut>(
    name: &str,
    capacity: usize,
    body: F,
) -> io::Result<tokio_mpsc::Sender<T>>
where
    T: Send + 'static,
    F: FnOnce(tokio_mpsc::Receiver<T>) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()>,
{
    let (sender, receiver) = tokio_mpsc::channel(capacity);
    thread::Builder::new()
        .name(name.to_string())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    log::error!("NATS KV worker runtime build failed: {error}");
                    return;
                }
            };
            runtime.block_on(body(receiver));
        })?;
    Ok(sender)
}

#[derive(Debug)]
pub struct NatsKvTemplateStore {
    worker: SyncWorker<KvWork>,
    rate_budget: Mutex<RateBudget>,
}

impl NatsKvTemplateStore {
    /// Connect to NATS, open the KV bucket, and start its dedicated I/O worker.
    ///
    /// # Panics
    ///
    /// The NATS connection is created on the worker runtime as well. The
    /// async-nats connection driver must not live on the collector's single
    /// Tokio worker, which is synchronously waiting for the KV reply.
    pub fn connect(config: Config, store_config: TemplateStoreConfig) -> Result<Self> {
        Ok(Self {
            worker: spawn_kv_worker(config, store_config)?,
            rate_budget: Mutex::new(RateBudget::default()),
        })
    }

    fn admit(&self) -> Result<Instant, TemplateStoreError> {
        let now = Instant::now();
        let deadline = PACKET_BUDGET.with(|budget| match budget.get() {
            Some(mut current) if current.remaining > 0 && now < current.deadline => {
                current.remaining -= 1;
                budget.set(Some(current));
                Some(current.deadline)
            }
            Some(_) => None,
            None => Some(now + DATAGRAM_KV_TIMEOUT),
        });
        let mut rate = self.rate_budget.lock().unwrap_or_else(|e| e.into_inner());
        if now.duration_since(rate.since) >= Duration::from_secs(1) {
            rate.since = now;
            rate.remaining = GLOBAL_KV_OPERATIONS_PER_SECOND;
        }
        if let Some(deadline) = deadline
            && rate.remaining > 0
        {
            rate.remaining -= 1;
            return Ok(deadline);
        }
        BUDGET_REJECTIONS.fetch_add(1, Ordering::Relaxed);
        Err(worker_error("NATS KV operation budget exhausted"))
    }

    /// Render a [`TemplateStoreKey`] as a NATS KV key.
    ///
    /// NATS KV keys must consist of `[A-Za-z0-9._=/-]` and use `.` as a
    /// token separator. Our scope strings come from
    /// [`netflow_parser::AutoScopedParser`] and look like
    /// `"v9:10.0.0.1:2055/0"` (IPv4) or `"legacy:[fe80::1]:6343"` (IPv6),
    /// which contain `:`, `[`, `]` — characters NATS forbids. We
    /// replace any disallowed character with `_`. Scopes that come from
    /// `format!("{}:{}/{}", ...)` patterns can't collide after this
    /// substitution in practice because the surrounding tokens (`v9`,
    /// `ipfix`, `legacy`) and template-id suffix keep the structure
    /// distinct.
    ///
    /// Layout: `{safe_scope}.{kind_tag}.{template_id}`
    pub(crate) fn render_key(key: &TemplateStoreKey) -> String {
        let kind_tag = kind_tag(key.kind);
        let mut safe_scope = String::with_capacity(key.scope.len());
        for c in key.scope.chars() {
            match c {
                'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '=' => safe_scope.push(c),
                _ => safe_scope.push('_'),
            }
        }
        if safe_scope.is_empty() {
            safe_scope.push_str("default");
        }
        format!("{}.{}.{}", safe_scope, kind_tag, key.template_id)
    }
}

fn spawn_kv_worker(
    config: Config,
    store_config: TemplateStoreConfig,
) -> Result<SyncWorker<KvWork>> {
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);

    // The NATS connection is opened *inside* the worker's runtime so that its
    // connection-handler task lives there too, and is therefore driven by the
    // same `block_on` that serves the request loop.
    let sender = spawn_driven_worker(
        "flow-template-kv",
        KV_WORK_QUEUE_CAPACITY,
        move |mut receiver| async move {
            let kv = match open_kv_store(&config, &store_config).await {
                Ok(kv) => kv,
                Err(error) => {
                    let _ = ready_tx.try_send(Err(format!("{error:#}")));
                    return;
                }
            };
            if ready_tx.try_send(Ok(())).is_err() {
                return;
            }
            let mut status_tick = tokio::time::interval(Duration::from_secs(30));
            loop {
                tokio::select! {
                    operation = receiver.recv() => match operation {
                        Some(work) => handle_operation(&kv, work).await,
                        None => break,
                    },
                    _ = status_tick.tick() => {
                        if let Ok(Ok(status)) = tokio::time::timeout(KV_OP_TIMEOUT, kv.status()).await {
                            BUCKET_BYTES.store(status.info.state.bytes, Ordering::Relaxed);
                        }
                    }
                }
            }
        },
    )
    .context("spawn NATS KV worker thread")?;

    match ready_rx.recv() {
        Ok(Ok(())) => Ok(SyncWorker::from_sender(sender)),
        Ok(Err(error)) => Err(anyhow::anyhow!(error)),
        Err(error) => Err(anyhow::anyhow!(
            "NATS KV worker exited during startup: {error}"
        )),
    }
}

async fn open_kv_store(config: &Config, cfg: &TemplateStoreConfig) -> Result<Store> {
    let url = cfg.nats_url.as_deref().unwrap_or(&config.nats_url);
    let (_, js) = nats_client::connect_with_retry(url, config, "template-store").await?;
    let kv_config = jetstream::kv::Config {
        bucket: cfg.kv_bucket.clone(),
        history: i64::from(cfg.kv_history),
        max_bytes: cfg.kv_max_bytes,
        max_value_size: MAX_TEMPLATE_VALUE_BYTES as i32,
        max_age: if cfg.kv_ttl_secs > 0 {
            Duration::from_secs(cfg.kv_ttl_secs)
        } else {
            Duration::ZERO
        },
        ..Default::default()
    };
    js.create_or_update_key_value(kv_config)
        .await
        .with_context(|| format!("opening NATS KV bucket {}", cfg.kv_bucket))
}

fn kind_tag(kind: TemplateKind) -> &'static str {
    // `TemplateKind` is marked `#[non_exhaustive]` upstream so this match
    // must have a wildcard. If a new variant ships in netflow_parser, the
    // build keeps working — entries land under "unk" so they're at least
    // grouped predictably — but we warn once on first sighting so an
    // operator has a chance to notice. Add a new explicit arm when
    // bumping the dep.
    match kind {
        TemplateKind::V9Data => "v9d",
        TemplateKind::V9Options => "v9o",
        TemplateKind::IpfixData => "ipd",
        TemplateKind::IpfixOptions => "ipo",
        TemplateKind::IpfixV9Data => "i9d",
        TemplateKind::IpfixV9Options => "i9o",
        _ => {
            static ONCE: Once = Once::new();
            ONCE.call_once(|| {
                warn!(
                    "Unknown TemplateKind variant {:?} from netflow_parser — bump the dep \
                     and add an explicit kind_tag arm; entries are landing under '.unk.'",
                    kind
                );
            });
            "unk"
        }
    }
}

/// Build the error reported when a KV op exceeds [`KV_OP_TIMEOUT`].
fn timed_out(op: &str, key: &str, timeout: Duration) -> io::Error {
    io::Error::new(
        io::ErrorKind::TimedOut,
        format!("NATS KV {op} for '{key}' exceeded {timeout:?}"),
    )
}

fn worker_error(error: impl std::fmt::Display) -> TemplateStoreError {
    TemplateStoreError::Backend(Box::new(io::Error::other(error.to_string())))
}

fn wait_for_reply<T>(
    reply: mpsc::Receiver<WorkerResult<T>>,
    deadline: Instant,
) -> Result<T, TemplateStoreError> {
    match reply.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(worker_error(error)),
        Err(mpsc::RecvTimeoutError::Timeout) => Err(worker_error(
            "NATS KV worker reply exceeded the datagram deadline",
        )),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            Err(worker_error("NATS KV worker reply channel closed"))
        }
    }
}

async fn handle_operation(kv: &Store, work: KvWork) {
    let remaining = work.deadline.saturating_duration_since(Instant::now());
    // Check before constructing a NATS future: expired queued mutations must
    // never be applied after the parser has already abandoned the operation.
    if remaining.is_zero() {
        let error = "NATS KV queued operation expired".to_string();
        match work.operation {
            KvOperation::Get { reply, .. } => {
                let _ = reply.try_send(Err(error));
            }
            KvOperation::Put { reply, .. } | KvOperation::Remove { reply, .. } => {
                MUTATION_FAILURES.fetch_add(1, Ordering::Relaxed);
                let _ = reply.try_send(Err(error));
            }
        }
        return;
    }
    let timeout = remaining.min(KV_OP_TIMEOUT);
    match work.operation {
        KvOperation::Get { key, reply } => {
            let result = match tokio::time::timeout(timeout, kv.get(&key)).await {
                Ok(Ok(Some(bytes))) => Ok(Some(bytes.to_vec())),
                Ok(Ok(None)) => Ok(None),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err(timed_out("get", &key, timeout).to_string()),
            };
            let _ = reply.try_send(result);
        }
        KvOperation::Put { key, value, reply } => {
            let result = match tokio::time::timeout(timeout, kv.put(&key, value)).await {
                Ok(Ok(_revision)) => Ok(()),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err(timed_out("put", &key, timeout).to_string()),
            };
            if result.is_err() {
                MUTATION_FAILURES.fetch_add(1, Ordering::Relaxed);
            }
            let _ = reply.try_send(result);
        }
        KvOperation::Remove { key, reply } => {
            let result = match tokio::time::timeout(timeout, kv.delete(&key)).await {
                Ok(Ok(())) => Ok(()),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err(timed_out("remove", &key, timeout).to_string()),
            };
            if result.is_err() {
                MUTATION_FAILURES.fetch_add(1, Ordering::Relaxed);
            }
            let _ = reply.try_send(result);
        }
    }
}

impl TemplateStore for NatsKvTemplateStore {
    fn get(&self, key: &TemplateStoreKey) -> Result<Option<Vec<u8>>, TemplateStoreError> {
        let deadline = self.admit()?;
        let nats_key = Self::render_key(key);
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.worker
            .try_send(KvWork {
                deadline,
                operation: KvOperation::Get {
                    key: nats_key,
                    reply: reply_tx,
                },
            })
            .map_err(worker_error)?;
        wait_for_reply(reply_rx, deadline)
    }

    fn put(&self, key: &TemplateStoreKey, value: &[u8]) -> Result<(), TemplateStoreError> {
        if value.len() > MAX_TEMPLATE_VALUE_BYTES {
            BUDGET_REJECTIONS.fetch_add(1, Ordering::Relaxed);
            return Err(worker_error("NATS KV template exceeds maximum value size"));
        }
        let deadline = self.admit()?;
        let nats_key = Self::render_key(key);
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.worker
            .try_send(KvWork {
                deadline,
                operation: KvOperation::Put {
                    key: nats_key,
                    value: bytes::Bytes::copy_from_slice(value),
                    reply: reply_tx,
                },
            })
            .map_err(worker_error)?;
        wait_for_reply(reply_rx, deadline)
    }

    fn remove(&self, key: &TemplateStoreKey) -> Result<(), TemplateStoreError> {
        let deadline = self.admit()?;
        let nats_key = Self::render_key(key);
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.worker
            .try_send(KvWork {
                deadline,
                operation: KvOperation::Remove {
                    key: nats_key,
                    reply: reply_tx,
                },
            })
            .map_err(worker_error)?;
        wait_for_reply(reply_rx, deadline)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn key(scope: &str, kind: TemplateKind, id: u16) -> TemplateStoreKey {
        TemplateStoreKey::new(Arc::<str>::from(scope), kind, id)
    }

    #[test]
    fn adapter_bounds_packet_work_shared_rate_and_values_before_enqueue() {
        let received = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&received);
        let sender = spawn_driven_worker(
            "test-budget-worker",
            KV_WORK_QUEUE_CAPACITY,
            move |mut rx: tokio_mpsc::Receiver<KvWork>| async move {
                while let Some(work) = rx.recv().await {
                    count.fetch_add(1, Ordering::SeqCst);
                    match work.operation {
                        KvOperation::Get { reply, .. } => {
                            let _ = reply.try_send(Ok(None));
                        }
                        KvOperation::Put { reply, .. } | KvOperation::Remove { reply, .. } => {
                            let _ = reply.try_send(Ok(()));
                        }
                    }
                }
            },
        )
        .unwrap();
        let store = NatsKvTemplateStore {
            worker: SyncWorker::from_sender(sender),
            rate_budget: Mutex::new(RateBudget::default()),
        };
        let k = key("v9:192.0.2.1:2055/1", TemplateKind::V9Data, 256);
        assert!(store.put(&k, &vec![0; 1024 * 1024 + 1]).is_err());
        assert_eq!(
            received.load(Ordering::SeqCst),
            0,
            "oversized value reached the worker"
        );
        {
            let _packet = DatagramBudget::begin();
            // Isolate the count contract from scheduler latency; the deadline
            // contract is exercised independently below.
            PACKET_BUDGET.with(|budget| {
                let mut current = budget.get().unwrap();
                current.deadline = Instant::now() + Duration::from_secs(10);
                budget.set(Some(current));
            });
            for index in 0..16 {
                store.rate_budget.lock().unwrap().since = Instant::now();
                match index % 3 {
                    0 => {
                        assert_eq!(store.get(&k).unwrap(), None);
                    }
                    1 => store.put(&k, b"synthetic-template").unwrap(),
                    _ => store.remove(&k).unwrap(),
                }
            }
            assert!(store.get(&k).is_err());
            assert!(store.put(&k, b"synthetic-template").is_err());
            assert!(store.remove(&k).is_err());
            assert_eq!(
                received.load(Ordering::SeqCst),
                16,
                "packet limit failed before enqueue"
            );
        }
        // New packets get their own allowance; the store-wide rate remains shared.
        for _ in 16..128 {
            // Hold one rate window while observing count consumption across
            // separate packet budgets, without adding a production clock hook.
            store.rate_budget.lock().unwrap().since = Instant::now();
            let _packet = DatagramBudget::begin();
            PACKET_BUDGET.with(|budget| {
                let mut current = budget.get().unwrap();
                current.deadline = Instant::now() + Duration::from_secs(10);
                budget.set(Some(current));
            });
            assert_eq!(store.get(&k).unwrap(), None);
        }
        store.rate_budget.lock().unwrap().since = Instant::now();
        assert!(store.remove(&k).is_err());
        assert_eq!(received.load(Ordering::SeqCst), 128);
    }

    #[test]
    fn one_stalled_kv_call_exhausts_the_packet_deadline() {
        let (sender, mut rx) = tokio_mpsc::channel(KV_WORK_QUEUE_CAPACITY);
        let store = NatsKvTemplateStore {
            worker: SyncWorker::from_sender(sender),
            rate_budget: Mutex::new(RateBudget::default()),
        };
        let k = key("ipfix:192.0.2.1:4739/1", TemplateKind::IpfixData, 256);
        let _packet = DatagramBudget::begin();
        let started = Instant::now();
        assert!(store.get(&k).is_err());

        assert!(store.remove(&k).is_err());
        assert!(store.put(&k, b"synthetic-template").is_err());
        let queued = rx.try_recv().unwrap();
        assert!(queued.deadline <= started + Duration::from_millis(100));
        assert!(queued.deadline <= Instant::now());
        assert!(
            rx.try_recv().is_err(),
            "operations were queued after the packet deadline"
        );
    }

    #[test]
    fn render_v9_per_source_scope_is_nats_safe() {
        let k = key("v9:10.0.0.1:2055/0", TemplateKind::V9Data, 256);
        let rendered = NatsKvTemplateStore::render_key(&k);
        assert_eq!(rendered, "v9_10_0_0_1_2055_0.v9d.256");
        // Round-trip through the NATS subject grammar: every char must be
        // alnum / dash / underscore / dot / equals / slash.
        assert!(
            rendered
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '=' | '/' | '.'))
        );
    }

    #[test]
    fn render_ipv6_scope_strips_brackets_and_colons() {
        let k = key("ipfix:[fe80::1]:4739/42", TemplateKind::IpfixData, 300);
        let rendered = NatsKvTemplateStore::render_key(&k);
        assert_eq!(rendered, "ipfix__fe80__1__4739_42.ipd.300");
        assert!(!rendered.contains([':', '[', ']']));
    }

    /// The worker's runtime must keep polling spawned tasks while it is
    /// waiting for the next request, not only while an operation is in
    /// flight.
    ///
    /// This is the property `async_nats` depends on: it spawns its connection
    /// handler as a background task, and a current-thread runtime only drives
    /// spawned tasks while it is being polled. An earlier version of this
    /// worker awaited requests on a *blocking* std channel, so between
    /// operations the runtime was parked and the handler never ran -- the
    /// client stopped answering server PINGs and NATS dropped it after about
    /// two ping intervals. On a collector with sparse exporter traffic that
    /// idle window is the normal case, so the connection died in steady state
    /// and every later KV call timed out.
    #[test]
    fn worker_runtime_keeps_driving_background_tasks_while_idle() {
        let ticks = Arc::new(AtomicUsize::new(0));
        let ticks_in_task = Arc::clone(&ticks);

        // Never send a request: the worker sits idle for the whole test, which
        // is exactly the condition that used to freeze the runtime.
        let _sender = spawn_driven_worker("test-idle-worker", 4, move |mut rx| async move {
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                    ticks_in_task.fetch_add(1, Ordering::SeqCst);
                }
            });
            while let Some(()) = rx.recv().await {}
        })
        .expect("spawn worker");

        thread::sleep(Duration::from_millis(150));

        assert!(
            ticks.load(Ordering::SeqCst) > 0,
            "background task on the worker runtime made no progress while idle; \
             the runtime is not being driven between requests"
        );
    }

    /// A full-queue send must fail fast rather than block the parser, which
    /// calls this while holding the parser mutex.
    #[test]
    fn worker_try_send_fails_fast_when_queue_is_full() {
        // Body never drains, so the queue fills and stays full.
        let sender = spawn_driven_worker("test-full-worker", 1, |mut rx| async move {
            tokio::time::sleep(Duration::from_secs(30)).await;
            while let Some(()) = rx.recv().await {}
        })
        .expect("spawn worker");
        let worker = SyncWorker::from_sender(sender);

        // Capacity 1 plus tokio's buffering: push until it reports Full.
        let mut saw_would_block = false;
        for _ in 0..64 {
            if let Err(error) = worker.try_send(()) {
                assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
                saw_would_block = true;
                break;
            }
        }
        assert!(saw_would_block, "expected a full queue to reject a send");
    }

    #[test]
    fn empty_scope_renders_as_default() {
        let k = key("", TemplateKind::V9Options, 257);
        let rendered = NatsKvTemplateStore::render_key(&k);
        assert_eq!(rendered, "default.v9o.257");
    }

    #[test]
    fn distinct_scopes_render_distinctly() {
        let a = key("v9:10.0.0.1:2055/0", TemplateKind::V9Data, 256);
        let b = key("v9:10.0.0.2:2055/0", TemplateKind::V9Data, 256);
        assert_ne!(
            NatsKvTemplateStore::render_key(&a),
            NatsKvTemplateStore::render_key(&b)
        );
    }

    #[test]
    fn distinct_kinds_render_distinctly() {
        let a = key("scope", TemplateKind::V9Data, 256);
        let b = key("scope", TemplateKind::V9Options, 256);
        let c = key("scope", TemplateKind::IpfixData, 256);
        assert_ne!(
            NatsKvTemplateStore::render_key(&a),
            NatsKvTemplateStore::render_key(&b)
        );
        assert_ne!(
            NatsKvTemplateStore::render_key(&a),
            NatsKvTemplateStore::render_key(&c)
        );
        assert_ne!(
            NatsKvTemplateStore::render_key(&b),
            NatsKvTemplateStore::render_key(&c)
        );
    }
}
