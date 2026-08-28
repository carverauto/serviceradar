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
use std::io;
use std::sync::Once;
use std::sync::mpsc::{self, SyncSender};
use std::thread;
use std::time::Duration;
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
const KV_REPLY_TIMEOUT: Duration = Duration::from_millis(600);
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
    worker: SyncWorker<KvOperation>,
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
        })
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
) -> Result<SyncWorker<KvOperation>> {
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
            while let Some(operation) = receiver.recv().await {
                handle_operation(&kv, operation).await;
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
fn timed_out(op: &str, key: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::TimedOut,
        format!("NATS KV {op} for '{key}' exceeded {KV_OP_TIMEOUT:?}"),
    )
}

fn worker_error(error: impl std::fmt::Display) -> TemplateStoreError {
    TemplateStoreError::Backend(Box::new(io::Error::other(error.to_string())))
}

fn wait_for_reply<T>(reply: mpsc::Receiver<WorkerResult<T>>) -> Result<T, TemplateStoreError> {
    match reply.recv_timeout(KV_REPLY_TIMEOUT) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(worker_error(error)),
        Err(mpsc::RecvTimeoutError::Timeout) => Err(worker_error(format!(
            "NATS KV worker reply exceeded {KV_REPLY_TIMEOUT:?}"
        ))),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            Err(worker_error("NATS KV worker reply channel closed"))
        }
    }
}

async fn handle_operation(kv: &Store, operation: KvOperation) {
    match operation {
        KvOperation::Get { key, reply } => {
            let result = match tokio::time::timeout(KV_OP_TIMEOUT, kv.get(&key)).await {
                Ok(Ok(Some(bytes))) => Ok(Some(bytes.to_vec())),
                Ok(Ok(None)) => Ok(None),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err(timed_out("get", &key).to_string()),
            };
            let _ = reply.try_send(result);
        }
        KvOperation::Put { key, value, reply } => {
            let result = match tokio::time::timeout(KV_OP_TIMEOUT, kv.put(&key, value)).await {
                Ok(Ok(_revision)) => Ok(()),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err(timed_out("put", &key).to_string()),
            };
            let _ = reply.try_send(result);
        }
        KvOperation::Remove { key, reply } => {
            let result = match tokio::time::timeout(KV_OP_TIMEOUT, kv.delete(&key)).await {
                Ok(Ok(())) => Ok(()),
                Ok(Err(error)) => Err(error.to_string()),
                Err(_) => Err(timed_out("remove", &key).to_string()),
            };
            let _ = reply.try_send(result);
        }
    }
}

impl TemplateStore for NatsKvTemplateStore {
    fn get(&self, key: &TemplateStoreKey) -> Result<Option<Vec<u8>>, TemplateStoreError> {
        let nats_key = Self::render_key(key);
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.worker
            .try_send(KvOperation::Get {
                key: nats_key,
                reply: reply_tx,
            })
            .map_err(worker_error)?;
        wait_for_reply(reply_rx)
    }

    fn put(&self, key: &TemplateStoreKey, value: &[u8]) -> Result<(), TemplateStoreError> {
        let nats_key = Self::render_key(key);
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.worker
            .try_send(KvOperation::Put {
                key: nats_key,
                value: bytes::Bytes::copy_from_slice(value),
                reply: reply_tx,
            })
            .map_err(worker_error)?;
        wait_for_reply(reply_rx)
    }

    fn remove(&self, key: &TemplateStoreKey) -> Result<(), TemplateStoreError> {
        let nats_key = Self::render_key(key);
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.worker
            .try_send(KvOperation::Remove {
                key: nats_key,
                reply: reply_tx,
            })
            .map_err(worker_error)?;
        wait_for_reply(reply_rx)
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
