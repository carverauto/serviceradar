//! A Flowgger output that publishes every log record to a NATS JetStream subject.
//! Enable with `--features nats-output`.

#[cfg(feature = "nats-output")]
use serde_json::Value;
#[cfg(feature = "nats-output")]
use {
    super::Output,
    crate::flowgger::normalized::{
        self, Normalization,
        batch::{Batch, Batcher, Limits},
        frame,
    },
    crate::flowgger::{config::Config, merger::Merger},
    async_nats::jetstream::{
        context::{ContextBuilder, PublishAckFuture, PublishError, PublishErrorKind},
        message::PublishMessage,
        stream::StorageType,
    },
    async_nats::{Client, ConnectOptions, jetstream},
    std::{
        any::Any,
        cmp::{max, min},
        panic::{AssertUnwindSafe, catch_unwind},
        path::PathBuf,
        sync::{Arc, Mutex, mpsc::Receiver},
        thread,
        time::{Duration, Instant},
    },
    tokio::{
        runtime::Builder as RtBuilder,
        sync::{Mutex as AsyncMutex, mpsc},
        task::JoinSet,
        time::{sleep, timeout},
    },
};

/// Whether an existing stream `pattern` subject already covers `subject` under
/// NATS wildcard semantics (`*` = one token, `>` = tail). Used to skip a literal
/// subject append already covered (e.g. `logs.syslog` under `logs.>`): appending
/// it anyway makes JetStream reject the STREAM.UPDATE with a subject-overlap error
/// (10052) — exactly fj #4302.
#[cfg(feature = "nats-output")]
fn subject_covers(pattern: &str, subject: &str) -> bool {
    let pattern_tokens: Vec<&str> = pattern.split('.').collect();
    let subject_tokens: Vec<&str> = subject.split('.').collect();

    let mut subject_index = 0;
    for (idx, token) in pattern_tokens.iter().enumerate() {
        match *token {
            ">" => return idx == pattern_tokens.len() - 1,
            "*" => {
                if subject_index >= subject_tokens.len() {
                    return false;
                }
                subject_index += 1;
            }
            literal => {
                if subject_index >= subject_tokens.len() || subject_tokens[subject_index] != literal
                {
                    return false;
                }
                subject_index += 1;
            }
        }
    }

    subject_index == subject_tokens.len()
}

#[cfg(feature = "nats-output")]
fn next_backoff(current: Duration, maximum: Duration) -> Duration {
    min(current.checked_mul(2).unwrap_or(maximum), maximum)
}

#[cfg(feature = "nats-output")]
const MAX_ACK_RETRY_HORIZON: Duration = Duration::from_secs(90);

#[cfg(feature = "nats-output")]
fn ack_retry_horizon(duplicate_window: Duration, publish_timeout: Duration) -> Option<Duration> {
    // Keep one full publish timeout between the last retry and expiration of
    // JetStream's duplicate window. This gives a retry already accepted by the
    // client time to reach the server before its message ID stops being safe.
    // Cap the horizon so an unusually large server window cannot head-of-line
    // block fresh syslog records for an operationally unbounded period.
    let safety_margin = max(publish_timeout, Duration::from_millis(1));
    duplicate_window
        .checked_sub(safety_margin)
        .map(|horizon| min(horizon, MAX_ACK_RETRY_HORIZON))
        .filter(|horizon| !horizon.is_zero())
}

#[cfg(feature = "nats-output")]
fn ack_retry_deadline(
    possible_store_started: Instant,
    duplicate_window: Duration,
    publish_timeout: Duration,
) -> Option<Instant> {
    possible_store_started.checked_add(ack_retry_horizon(duplicate_window, publish_timeout)?)
}

#[cfg(feature = "nats-output")]
fn remaining_retry_budget(deadline: Instant, now: Instant) -> Option<Duration> {
    deadline
        .checked_duration_since(now)
        .filter(|remaining| !remaining.is_zero())
}

#[cfg(feature = "nats-output")]
fn retry_delay(backoff: Duration, remaining: Duration) -> Option<Duration> {
    (backoff < remaining).then_some(backoff)
}

#[cfg(feature = "nats-output")]
fn new_message_id() -> String {
    format!("flowgger-{:032x}", rand::random::<u128>())
}

#[cfg(feature = "nats-output")]
fn permanent_publish_error(kind: PublishErrorKind) -> bool {
    matches!(
        kind,
        PublishErrorKind::MaxPayloadExceeded
            | PublishErrorKind::WrongLastMessageId
            | PublishErrorKind::WrongLastSequence
    )
}

#[cfg(feature = "nats-output")]
#[derive(Clone, Copy, Debug)]
enum PublishStage {
    Send,
    Acknowledgment,
}

#[cfg(feature = "nats-output")]
impl std::fmt::Display for PublishStage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Send => f.write_str("send"),
            Self::Acknowledgment => f.write_str("acknowledgment"),
        }
    }
}

#[cfg(feature = "nats-output")]
#[derive(Debug)]
struct PublishFailure {
    stage: PublishStage,
    error: PublishError,
    possible_store_started: Option<Instant>,
}

#[cfg(feature = "nats-output")]
struct NATSConnection {
    cert_policy: Option<serviceradar_cert_policy::nats::Guard>,
    client: Client,
    js: jetstream::Context,
    duplicate_window: Duration,
}

#[cfg(feature = "nats-output")]
fn panic_message(payload: &Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "non-string panic payload".to_string()
    }
}

#[cfg(feature = "nats-output")]
fn receive_records(
    arx: Arc<Mutex<Receiver<Vec<u8>>>>,
) -> Result<mpsc::Receiver<Result<Vec<u8>, String>>, String> {
    let (tx, rx) = mpsc::channel(1);
    thread::Builder::new()
        .name("flowgger-nats-queue".into())
        .spawn(move || {
            loop {
                let record = match arx.lock() {
                    Ok(receiver) => match receiver.recv() {
                        Ok(bytes) => Ok(bytes),
                        Err(_) => break,
                    },
                    Err(_) => {
                        let _ = tx.blocking_send(Err(
                            "Flowgger NATS output queue mutex is poisoned".into(),
                        ));
                        break;
                    }
                };
                // Release the shared receiver lock before applying backpressure so
                // other configured NATS workers can continue receiving records.
                if tx.blocking_send(record).is_err() {
                    break;
                }
            }
        })
        .map_err(|error| format!("Failed to start Flowgger NATS queue bridge: {error}"))?;
    Ok(rx)
}

#[cfg(feature = "nats-output")]
fn positive_size(cfg: &Config, key: &str, default: usize) -> usize {
    match cfg.lookup(key) {
        None => default,
        Some(value) => match value.as_integer().and_then(|n| usize::try_from(n).ok()) {
            Some(n) if n > 0 => n,
            _ => panic!("{key} must be a positive integer"),
        },
    }
}

#[cfg(feature = "nats-output")]
pub struct NATSOutput {
    cfg: NATSConfig,
    workers: u32,
}

#[cfg(feature = "nats-output")]
#[derive(Clone)]
struct NATSConfig {
    url: String,
    domain: Option<String>,
    subject: String,
    stream: String,
    stream_replicas: usize,
    partition: String,
    timeout: Duration,
    tls_cert: Option<PathBuf>,
    tls_key: Option<PathBuf>,
    tls_ca: Option<PathBuf>,
    cert_policy_file: Option<PathBuf>,
    cert_policy_local_leaf_file: Option<PathBuf>,
    creds_file: Option<PathBuf>,
    connect_attempts: u32,
    connect_initial_backoff: Duration,
    connect_max_backoff: Duration,
    max_inflight: usize,
    max_inflight_bytes: usize,
    /// Set when records arrive framed by the normalizing encoder: where
    /// normalized batches are published, and how they are bounded.
    normalized: Option<(String, Limits)>,
}

#[cfg(feature = "nats-output")]
impl NATSConfig {
    /// Every subject this output publishes on.
    fn subjects(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.subject.as_str())
            .chain(self.normalized.iter().map(|(subject, _)| subject.as_str()))
    }
}

/// One NATS message ready to publish. `ruleset` is set on a batch of
/// normalized records.
#[cfg(feature = "nats-output")]
struct Outgoing {
    payload: Vec<u8>,
    ruleset: Option<String>,
}

#[cfg(feature = "nats-output")]
impl From<Batch> for Outgoing {
    fn from(batch: Batch) -> Self {
        Self {
            payload: batch.payload,
            ruleset: Some(batch.ruleset),
        }
    }
}

#[cfg(feature = "nats-output")]
impl NATSOutput {
    pub fn new(cfg: &Config) -> Self {
        // ---- mandatory ----
        let url = cfg
            .lookup("output.nats_url")
            .expect("output.nats_url is required")
            .as_str()
            .unwrap()
            .to_owned();
        let domain = cfg.lookup("output.nats_domain").map(|value| {
            value
                .as_str()
                .expect("output.nats_domain must be a string")
                .to_owned()
        });
        let subject = cfg
            .lookup("output.nats_subject")
            .unwrap_or_else(|| panic!("output.nats_subject is required"))
            .as_str()
            .unwrap()
            .to_owned();

        // ---- optional w/ sane defaults ----
        let stream = cfg
            .lookup("output.nats_stream")
            .map_or("events".into(), |v| v.as_str().unwrap().to_owned());
        let stream_replicas = cfg
            .lookup("output.nats_stream_replicas")
            .map_or(1, |v| v.as_integer().unwrap() as usize);
        let partition = cfg
            .lookup("output.partition")
            .map_or("default".into(), |v| v.as_str().unwrap().to_owned());
        let timeout = Duration::from_millis(
            cfg.lookup("output.nats_timeout")
                .map_or(30_000, |v| v.as_integer().unwrap() as u64),
        );

        let cert_policy_file = cfg.lookup("output.nats_cert_policy_file").map(|v| {
            PathBuf::from(
                v.as_str()
                    .expect("output.nats_cert_policy_file must be a path"),
            )
        });
        let cert_policy_local_leaf_file = cfg
            .lookup("output.nats_cert_policy_local_leaf_file")
            .map(|v| {
                PathBuf::from(
                    v.as_str()
                        .expect("output.nats_cert_policy_local_leaf_file must be a path"),
                )
            });
        let tls_cert = cfg
            .lookup("output.nats_tls_cert")
            .map(|v| PathBuf::from(v.as_str().unwrap()));
        let tls_key = cfg
            .lookup("output.nats_tls_key")
            .map(|v| PathBuf::from(v.as_str().unwrap()));
        let tls_ca = cfg
            .lookup("output.nats_tls_ca_file")
            .map(|v| PathBuf::from(v.as_str().unwrap()));
        let creds_file = cfg.lookup("output.nats_creds_file").and_then(|v| {
            let value = v.as_str().unwrap().trim();
            if value.is_empty() {
                None
            } else {
                Some(PathBuf::from(value))
            }
        });

        let workers = cfg
            .lookup("output.nats_threads")
            .map_or(1, |v| v.as_integer().unwrap() as u32);
        let connect_attempts = cfg
            .lookup("output.nats_connect_attempts")
            .map_or(0, |v| v.as_integer().unwrap() as u32);
        let mut connect_initial_backoff = Duration::from_millis(
            cfg.lookup("output.nats_connect_initial_backoff_ms")
                .map_or(500, |v| v.as_integer().unwrap() as u64),
        );
        let mut connect_max_backoff = Duration::from_millis(
            cfg.lookup("output.nats_connect_max_backoff_ms")
                .map_or(30_000, |v| v.as_integer().unwrap() as u64),
        );
        if connect_initial_backoff.is_zero() {
            connect_initial_backoff = Duration::from_millis(1);
        }
        if connect_max_backoff.is_zero() {
            connect_max_backoff = connect_initial_backoff;
        }

        Self {
            cfg: NATSConfig {
                url,
                domain,
                subject,
                stream,
                stream_replicas,
                partition,
                timeout,
                tls_cert,
                tls_key,
                tls_ca,
                cert_policy_file,
                cert_policy_local_leaf_file,
                creds_file,
                connect_attempts,
                connect_initial_backoff,
                connect_max_backoff,
                max_inflight: positive_size(cfg, "output.nats_max_inflight", 32),
                max_inflight_bytes: positive_size(
                    cfg,
                    "output.nats_max_inflight_bytes",
                    8 * 1024 * 1024,
                ),
                normalized: None,
            },
            workers,
        }
    }

    /// The output for the normalizing encoder. Records normalized at the
    /// collector are published in batches on the normalized form of
    /// `output.nats_subject`; records that arrived before a ruleset did are
    /// published one by one on `output.nats_subject`, as GELF. A batch closes
    /// at `output.nats_batch_max_records` records (default 256),
    /// `output.nats_batch_max_bytes` bytes (default 256 KiB, and never more
    /// than one worker may have in flight) or `output.nats_batch_max_age_ms`
    /// after its first record (default 100).
    pub fn normalized(cfg: &Config) -> Self {
        let mut output = Self::new(cfg);
        let subject =
            Normalization::subject(&output.cfg.subject).unwrap_or_else(|error| panic!("{error}"));
        let limits = Limits {
            records: positive_size(cfg, "output.nats_batch_max_records", 256),
            bytes: positive_size(cfg, "output.nats_batch_max_bytes", 256 * 1024)
                .min(output.cfg.max_inflight_bytes),
            age: Duration::from_millis(
                positive_size(cfg, "output.nats_batch_max_age_ms", 100) as u64
            ),
        };
        output.cfg.normalized = Some((subject, limits));
        output
    }
}

#[cfg(feature = "nats-output")]
struct NATSWorker {
    arx: Arc<Mutex<Receiver<Vec<u8>>>>,
    cfg: NATSConfig,
    merger: Option<Box<dyn Merger + Send>>,
}

#[cfg(feature = "nats-output")]
struct NATSPublisher {
    cfg: NATSConfig,
}

#[cfg(feature = "nats-output")]
impl NATSPublisher {
    async fn connect_once(&self) -> Result<NATSConnection, async_nats::Error> {
        // Start with default connect options.
        // The outer worker owns long-lived reconnect policy. Keeping each
        // async-nats client to one automatic reconnect prevents an abandoned
        // client from retaining an ambiguous publish indefinitely.
        let mut options = ConnectOptions::new().max_reconnects(1);

        if let Some(creds_file) = &self.cfg.creds_file {
            options = options.credentials_file(creds_file).await?;
        }

        // Apply CA file if provided, to verify the server's certificate.
        if let Some(ca_file) = &self.cfg.tls_ca {
            options = options.add_root_certificates(ca_file.clone());
        }

        // Apply client certificate and key for mTLS client authentication.
        if let (Some(cert_file), Some(key_file)) = (&self.cfg.tls_cert, &self.cfg.tls_key) {
            options = options.add_client_certificate(cert_file.clone(), key_file.clone());
        }

        // Connect to the server using the constructed options.
        let (client, cert_policy) = serviceradar_cert_policy::nats::connect(
            options,
            &self.cfg.url,
            self.cfg.cert_policy_file.as_deref(),
            self.cfg.cert_policy_local_leaf_file.as_deref(),
            self.cfg.tls_ca.as_deref(),
            self.cfg.tls_cert.as_deref(),
            self.cfg.tls_key.as_deref(),
        )
        .await?;
        let builder = ContextBuilder::new()
            .timeout(self.cfg.timeout)
            .ack_timeout(self.cfg.timeout);
        let js = match &self.cfg.domain {
            Some(domain) => builder.domain(domain.clone()).build(client.clone()),
            None => builder.build(client.clone()),
        };

        match js.get_stream(&self.cfg.stream).await {
            Ok(mut stream) => {
                let info = stream.info().await?;
                let mut updated_config = info.config.clone();
                let mut changed = false;

                // Skip the append when an existing subject (e.g. `logs.>` on the shared
                // `events` stream) already covers ours — a literal `logs.syslog` append
                // would self-overlap and JetStream rejects the UPDATE (10052, #4302).
                for subject in self.cfg.subjects() {
                    if !updated_config
                        .subjects
                        .iter()
                        .any(|existing| subject_covers(existing, subject))
                    {
                        updated_config.subjects.push(subject.to_owned());
                        changed = true;
                    }
                }
                if updated_config.num_replicas != self.cfg.stream_replicas {
                    updated_config.num_replicas = self.cfg.stream_replicas;
                    changed = true;
                }

                if changed {
                    let _ = js.update_stream(updated_config).await?;
                }
            }
            Err(_) => {
                let stream_config = jetstream::stream::Config {
                    name: self.cfg.stream.clone(),
                    subjects: self.cfg.subjects().map(str::to_owned).collect(),
                    storage: StorageType::File,
                    num_replicas: self.cfg.stream_replicas,
                    ..Default::default()
                };
                let _ = js.get_or_create_stream(stream_config).await?;
            }
        }

        // Read back the server-normalized stream configuration. A zero value in
        // a create request becomes the server's configured default duplicate
        // window, and that actual window defines the safe ACK retry horizon.
        let mut stream = js.get_stream(&self.cfg.stream).await?;
        let duplicate_window = stream.info().await?.config.duplicate_window;

        Ok(NATSConnection {
            cert_policy,
            client,
            js,
            duplicate_window,
        })
    }

    async fn connect_with_retry(&self) -> Result<NATSConnection, async_nats::Error> {
        let mut attempt: u32 = 0;
        let mut backoff = min(
            self.cfg.connect_initial_backoff,
            self.cfg.connect_max_backoff,
        );

        loop {
            attempt += 1;
            match self.connect_once().await {
                Ok(conn) => return Ok(conn),
                Err(err) => {
                    let limit = self.cfg.connect_attempts;

                    if limit != 0 && attempt >= limit {
                        eprintln!(
                            "NATS connection attempt {attempt} failed: {err}. Giving up after {limit} attempts."
                        );
                        return Err(err);
                    }

                    eprintln!(
                        "NATS connection attempt {attempt} failed: {err}. Retrying in {:?}...",
                        backoff
                    );
                    sleep(backoff).await;

                    backoff = next_backoff(backoff, self.cfg.connect_max_backoff);
                }
            }
        }
    }

    async fn publish_once(
        &self,
        js: &jetstream::Context,
        subject: &str,
        publish: PublishMessage,
    ) -> Result<(), PublishFailure> {
        // Start the dedupe clock before handing the request to async-nats. If
        // send_publish succeeds, the server could persist the record at any
        // point after this instant even when its ACK never reaches us.
        let possible_store_started = Instant::now();
        let ack: PublishAckFuture =
            js.send_publish(subject.to_owned(), publish)
                .await
                .map_err(|error| PublishFailure {
                    stage: PublishStage::Send,
                    error,
                    possible_store_started: None,
                })?;

        ack.await.map(|_| ()).map_err(|error| PublishFailure {
            stage: PublishStage::Acknowledgment,
            error,
            possible_store_started: Some(possible_store_started),
        })
    }

    async fn publish_with_retry(
        &self,
        shared: &AsyncMutex<Arc<NATSConnection>>,
        subject: &str,
        publish: PublishMessage,
        message_id: &str,
        payload_size: usize,
    ) -> Result<(), String> {
        let mut connection = shared.lock().await.clone();
        let mut retry_count = 0_u64;
        let mut first_possible_store = None;
        let mut retry_deadline = None;
        let mut backoff = min(
            self.cfg.connect_initial_backoff,
            self.cfg.connect_max_backoff,
        );

        loop {
            if let Some(first_store) = first_possible_store {
                let candidate_deadline = ack_retry_deadline(
                    first_store,
                    connection.duplicate_window,
                    self.cfg.timeout,
                )
                .ok_or_else(|| {
                    format!(
                        "NATS reconnected for message_id={message_id}, but stream duplicate_window={:?} no longer leaves a safe acknowledgment retry horizon",
                        connection.duplicate_window
                    )
                })?;
                retry_deadline = Some(match retry_deadline {
                    Some(existing) => min(existing, candidate_deadline),
                    None => candidate_deadline,
                });
            }
            if let Some(deadline) = retry_deadline {
                remaining_retry_budget(deadline, Instant::now()).ok_or_else(|| {
                    format!(
                        "NATS acknowledgment retry horizon exhausted for message_id={message_id} subject={} (duplicate_window={:?}); refusing an unsafe duplicate retry",
                        subject, connection.duplicate_window
                    )
                })?;
            }

            if connection
                .cert_policy
                .as_ref()
                .is_some_and(|guard| guard.ensure_authorized().is_err())
            {
                let delay = match retry_deadline {
                    Some(deadline) => remaining_retry_budget(deadline, Instant::now())
                        .and_then(|remaining| retry_delay(backoff, remaining))
                        .ok_or(
                            "NATS policy reconnect would exceed the acknowledgment retry horizon",
                        )?,
                    None => backoff,
                };
                sleep(delay).await;
                connection = self.reconnect(shared, &connection, retry_deadline).await?;
                continue;
            }
            match self
                .publish_once(&connection.js, subject, publish.clone())
                .await
            {
                Ok(()) => return Ok(()),
                Err(failure) if permanent_publish_error(failure.error.kind()) => {
                    eprintln!(
                        "Dropping NATS record message_id={message_id} subject={} bytes={payload_size}: permanent {} error: {}",
                        subject, failure.stage, failure.error
                    );
                    return Ok(());
                }
                Err(failure) => {
                    if let Some(possible_store_started) = failure.possible_store_started {
                        let first_store =
                            *first_possible_store.get_or_insert(possible_store_started);
                        let candidate_deadline = ack_retry_deadline(
                            first_store,
                            connection.duplicate_window,
                            self.cfg.timeout,
                        )
                        .ok_or_else(|| {
                            format!(
                                "NATS {} failed for message_id={message_id} subject={}, but stream duplicate_window={:?} does not leave a safe retry horizon beyond publish timeout {:?}: {}",
                                failure.stage,
                                subject,
                                connection.duplicate_window,
                                self.cfg.timeout,
                                failure.error
                            )
                        })?;
                        retry_deadline = Some(match retry_deadline {
                            Some(existing) => min(existing, candidate_deadline),
                            None => candidate_deadline,
                        });
                    }

                    retry_count = retry_count.saturating_add(1);
                    let delay = match retry_deadline {
                        Some(deadline) => {
                            let remaining = remaining_retry_budget(deadline, Instant::now())
                                .ok_or_else(|| {
                                    format!(
                                        "NATS acknowledgment retry horizon exhausted for message_id={message_id} subject={} after {} error: {}",
                                        subject, failure.stage, failure.error
                                    )
                                })?;
                            retry_delay(backoff, remaining).ok_or_else(|| {
                                format!(
                                    "NATS acknowledgment retry horizon has only {remaining:?} remaining for message_id={message_id} subject={}, less than retry backoff {backoff:?}; refusing an unsafe duplicate retry",
                                    subject
                                )
                            })?
                        }
                        None => backoff,
                    };
                    eprintln!(
                        "NATS {} failed for message_id={message_id} subject={} (retry {retry_count}): {}. Reconnecting in {:?}...",
                        failure.stage, subject, failure.error, delay
                    );

                    sleep(delay).await;
                    let new_connection =
                        self.reconnect(shared, &connection, retry_deadline).await?;

                    connection = new_connection;
                    backoff = next_backoff(backoff, self.cfg.connect_max_backoff);
                }
            }
        }
    }

    async fn reconnect(
        &self,
        shared: &AsyncMutex<Arc<NATSConnection>>,
        previous: &Arc<NATSConnection>,
        deadline: Option<Instant>,
    ) -> Result<Arc<NATSConnection>, String> {
        let reconnect = async {
            let mut current = shared.lock().await;
            // A different record may already have replaced the failed client.
            // Reconnect once, while existing ACK futures keep being polled.
            if Arc::ptr_eq(&current, previous) {
                *current = Arc::new(self.connect_with_retry().await.map_err(|err| {
                    format!("NATS reconnect failed while retaining pending records: {err}")
                })?);
            }
            Ok(current.clone())
        };
        match deadline {
            Some(deadline) => {
                let remaining = remaining_retry_budget(deadline, Instant::now())
                    .ok_or("NATS acknowledgment retry horizon exhausted before reconnect")?;
                timeout(remaining, reconnect).await.map_err(|_| {
                    format!("NATS reconnect exceeded the remaining {remaining:?} acknowledgment retry horizon")
                })?
            }
            // Before a possibly stored attempt, preserve configured reconnect
            // behavior, including unlimited connection attempts.
            None => reconnect.await,
        }
    }

    async fn flush_on_close(&self, connection: &NATSConnection) {
        match timeout(self.cfg.timeout, connection.client.flush()).await {
            Ok(Ok(())) => {}
            Ok(Err(err)) => {
                eprintln!("Failed to flush NATS connection while closing output queue: {err}");
            }
            Err(_) => {
                eprintln!(
                    "NATS flush timed out after {:?} while closing output queue",
                    self.cfg.timeout
                );
            }
        }
    }
}

/// Puts the sender address of a GELF record under the collector's partition.
#[cfg(feature = "nats-output")]
pub(crate) fn partition_remote_addr(bytes: Vec<u8>, partition: &str) -> Vec<u8> {
    if let Ok(mut v) = serde_json::from_slice::<Value>(&bytes)
        && let Some(obj) = v.as_object_mut()
    {
        if let Some(addr_val) = obj.get_mut("_remote_addr")
            && let Some(s) = addr_val.as_str()
        {
            *addr_val = Value::String(format!("{partition}:{s}"));
        }
        return serde_json::to_vec(&v).unwrap_or(bytes);
    }
    bytes
}

#[cfg(feature = "nats-output")]
impl NATSWorker {
    fn prepare_record(&self, bytes: Vec<u8>) -> Vec<u8> {
        let mut bytes = partition_remote_addr(bytes, &self.cfg.partition);
        if let Some(m) = &self.merger {
            m.frame(&mut bytes);
        }
        bytes
    }

    /// Takes one record from the queue. Returns the message it completed: the
    /// record itself, or the batch of normalized records it closed.
    fn admit(
        &self,
        bytes: Vec<u8>,
        batcher: &mut Option<Batcher>,
    ) -> Result<Option<Outgoing>, String> {
        let fits = |size: usize| {
            if size > self.cfg.max_inflight_bytes {
                Err(format!(
                    "NATS encoded record has {size} bytes, exceeding output.nats_max_inflight_bytes={}; refusing to drop it or exceed the publish budget",
                    self.cfg.max_inflight_bytes,
                ))
            } else {
                Ok(())
            }
        };
        let Some(batcher) = batcher else {
            let payload = self.prepare_record(bytes);
            fits(payload.len())?;
            return Ok(Some(Outgoing {
                payload,
                ruleset: None,
            }));
        };
        fits(bytes.len())?;
        match frame::decode(&bytes)? {
            // Encoded before any ruleset arrived: published as it is, for
            // EventWriter to normalize.
            ("", record) => Ok(Some(Outgoing {
                payload: record.to_vec(),
                ruleset: None,
            })),
            _ => {
                let closed = batcher.push(&bytes, tokio::time::Instant::now())?;
                Ok(closed.map(Outgoing::from))
            }
        }
    }

    async fn run(self) -> Result<(), String> {
        let publisher = Arc::new(NATSPublisher {
            cfg: self.cfg.clone(),
        });
        let connection = Arc::new(AsyncMutex::new(Arc::new(
            publisher
                .connect_with_retry()
                .await
                .map_err(|err| format!("NATS initial connection failed: {err}"))?,
        )));
        let mut records = receive_records(Arc::clone(&self.arx))?;
        let mut pending = JoinSet::new();
        let mut pending_bytes = 0usize;
        let mut staged: Option<Outgoing> = None;
        let mut batcher = self
            .cfg
            .normalized
            .as_ref()
            .map(|(_, limits)| Batcher::new(*limits));
        let mut closed = false;
        // The first fatal error, and when to stop waiting for the records
        // already admitted. Nothing more is admitted once it is set.
        let mut fatal: Option<(String, tokio::time::Instant)> = None;

        loop {
            if let Some(message) = staged.as_ref()
                && pending.len() < self.cfg.max_inflight
                && message.payload.len() <= self.cfg.max_inflight_bytes - pending_bytes
            {
                let Outgoing { payload, ruleset } = staged.take().unwrap();
                let payload_size = payload.len();
                let message_id = new_message_id();
                let mut publish = PublishMessage::build()
                    .payload(payload.into())
                    .message_id(&message_id);
                let mut subject = self.cfg.subject.clone();
                if let (Some(ruleset), Some((normalized_subject, _))) =
                    (ruleset, &self.cfg.normalized)
                {
                    subject.clone_from(normalized_subject);
                    let (schema, schema_value) = normalized::SCHEMA_HEADER;
                    let (version, version_value) = normalized::NORMALIZATION_VERSION_HEADER;
                    let (epoch, epoch_value) = normalized::ROUTING_EPOCH_HEADER;
                    publish = publish
                        .header("Content-Type", "application/x-protobuf")
                        .header(schema, schema_value)
                        .header(version, version_value)
                        .header(normalized::RULESET_HEADER, ruleset.as_str())
                        .header(epoch, epoch_value);
                }
                let publisher = Arc::clone(&publisher);
                let connection = Arc::clone(&connection);
                pending_bytes += payload_size;
                pending.spawn(async move {
                    let result = publisher
                        .publish_with_retry(
                            &connection,
                            &subject,
                            publish,
                            &message_id,
                            payload_size,
                        )
                        .await;
                    (payload_size, result)
                });
                continue;
            }
            // The source has closed, so no record will complete the open batch.
            if closed
                && staged.is_none()
                && fatal.is_none()
                && let Some(batch) = batcher.as_mut().and_then(Batcher::flush)
            {
                staged = Some(batch.into());
                continue;
            }
            if staged.is_none() && pending.is_empty() && (closed || fatal.is_some()) {
                let current = connection.lock().await.clone();
                publisher.flush_on_close(&current).await;
                return match fatal {
                    Some((error, _)) => Err(error),
                    None => Ok(()),
                };
            }
            let drain_deadline = fatal.as_ref().map(|(_, deadline)| *deadline);
            let batch_deadline = batcher.as_ref().and_then(Batcher::deadline);
            let mut failure = None;
            tokio::select! {
                // Surface failures before accepting more records when both are
                // ready. Completed tasks still occupy their admission slots.
                biased;
                completion = pending.join_next(), if !pending.is_empty() => {
                    let (size, result) = completion.unwrap()
                        .map_err(|err| format!("Flowgger NATS publish task failed: {err}"))?;
                    pending_bytes -= size;
                    failure = result.err();
                }
                // select! evaluates this expression even when the branch is disabled.
                _ = tokio::time::sleep_until(drain_deadline.unwrap_or_else(tokio::time::Instant::now)), if drain_deadline.is_some() => {
                    let (error, _) = fatal.take().unwrap();
                    return Err(format!(
                        "{error}; abandoned {} pending and {} staged NATS records after waiting {:?} for their acknowledgments",
                        pending.len(), usize::from(staged.is_some()), self.cfg.timeout,
                    ));
                }
                // The oldest record of the open batch has waited long enough.
                _ = tokio::time::sleep_until(batch_deadline.unwrap_or_else(tokio::time::Instant::now)), if batch_deadline.is_some() && fatal.is_none() && staged.is_none() => {
                    staged = batcher.as_mut().and_then(Batcher::flush).map(Outgoing::from);
                }
                record = records.recv(), if fatal.is_none() && !closed && staged.is_none() && pending.len() < self.cfg.max_inflight => {
                    match record {
                        Some(Ok(bytes)) => match self.admit(bytes, &mut batcher) {
                            Ok(message) => staged = message,
                            Err(error) => failure = Some(error),
                        },
                        Some(Err(err)) => failure = Some(err),
                        None => closed = true,
                    }
                }
            }
            match (failure, &fatal) {
                // The output still fails. Records already admitted get one
                // publish timeout to be acknowledged first, so the exit is
                // bounded even when reconnects are unlimited.
                (Some(error), None) => {
                    fatal = Some((error, tokio::time::Instant::now() + self.cfg.timeout));
                }
                (Some(error), Some(_)) => {
                    eprintln!("NATS publish failed while the output was already failing: {error}");
                }
                (None, _) => {}
            }
        }
    }
}

#[cfg(feature = "nats-output")]
impl Output for NATSOutput {
    fn start(&self, arx: Arc<Mutex<Receiver<Vec<u8>>>>, merger: Option<Box<dyn Merger>>) {
        for _ in 0..self.workers {
            let arx = Arc::clone(&arx);
            let cfg = self.cfg.clone();
            let merger = merger.as_ref().map(|m| m.clone_boxed());

            thread::spawn(move || {
                let result = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
                    let rt = RtBuilder::new_current_thread()
                        .enable_all()
                        .build()
                        .map_err(|err| {
                            format!("Failed to create Flowgger NATS Tokio runtime: {err}")
                        })?;

                    rt.block_on(async { NATSWorker { arx, cfg, merger }.run().await })
                }));

                match result {
                    Ok(Ok(())) => {}
                    Ok(Err(err)) => {
                        eprintln!("Flowgger NATS output worker failed: {err}");
                        std::process::exit(1);
                    }
                    Err(payload) => {
                        eprintln!(
                            "Flowgger NATS output worker panicked: {}",
                            panic_message(&payload)
                        );
                        std::process::exit(1);
                    }
                }
            });
        }
    }
}

#[cfg(all(test, feature = "nats-output"))]
#[path = "nats_output_integration_tests.rs"]
mod integration_tests;

#[cfg(all(test, feature = "nats-output"))]
mod tests {
    use super::*;
    use std::sync::mpsc::sync_channel;

    #[test]
    fn enrolled_domain_is_retained_in_output_configuration() {
        let config = Config::from_string(
            r#"
[output]
nats_url = "nats://localhost:4222"
nats_subject = "logs.syslog"
nats_domain = "synthetic_edge"
"#,
        )
        .unwrap();
        assert_eq!(
            NATSOutput::new(&config).cfg.domain.as_deref(),
            Some("synthetic_edge")
        );
    }

    #[test]
    fn idle_queue_does_not_block_current_thread_runtime() {
        let runtime = RtBuilder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let (tx, rx) = sync_channel(1);
        let arx = Arc::new(Mutex::new(rx));

        runtime.block_on(async move {
            let mut records = receive_records(arx).unwrap();
            let receive_task = tokio::spawn(async move { records.recv().await });

            timeout(Duration::from_secs(1), sleep(Duration::from_millis(10)))
                .await
                .expect("the current-thread runtime must remain live while the queue is idle");
            assert!(!receive_task.is_finished());

            drop(tx);
            assert_eq!(receive_task.await.unwrap(), None);
        });
    }

    #[test]
    fn retry_backoff_is_capped() {
        let maximum = Duration::from_secs(30);
        assert_eq!(next_backoff(Duration::from_secs(16), maximum), maximum);
        assert_eq!(next_backoff(maximum, maximum), maximum);
    }

    #[test]
    fn acknowledgment_retry_horizon_reserves_a_publish_timeout() {
        assert_eq!(
            ack_retry_horizon(Duration::from_secs(120), Duration::from_secs(30)),
            Some(Duration::from_secs(90))
        );
        assert_eq!(
            ack_retry_horizon(Duration::from_secs(600), Duration::from_secs(30)),
            Some(Duration::from_secs(90))
        );
        assert_eq!(
            ack_retry_horizon(Duration::from_secs(60), Duration::from_secs(30)),
            Some(Duration::from_secs(30))
        );
        assert_eq!(
            ack_retry_horizon(Duration::from_secs(30), Duration::from_secs(30)),
            None
        );
        assert_eq!(
            ack_retry_horizon(Duration::ZERO, Duration::from_secs(30)),
            None
        );
    }

    #[test]
    fn retry_budget_expires_and_rejects_backoff_that_consumes_it() {
        let started = Instant::now();
        let deadline =
            ack_retry_deadline(started, Duration::from_secs(120), Duration::from_secs(30)).unwrap();

        assert_eq!(
            remaining_retry_budget(deadline, started + Duration::from_secs(30)),
            Some(Duration::from_secs(60))
        );
        assert_eq!(
            retry_delay(Duration::from_secs(10), Duration::from_secs(60)),
            Some(Duration::from_secs(10))
        );
        assert_eq!(
            retry_delay(Duration::from_secs(60), Duration::from_secs(60)),
            None
        );
        assert_eq!(remaining_retry_budget(deadline, deadline), None);
        assert_eq!(
            remaining_retry_budget(deadline, deadline + Duration::from_millis(1)),
            None
        );
    }

    #[test]
    fn only_per_record_publish_errors_are_permanent() {
        assert!(permanent_publish_error(
            PublishErrorKind::MaxPayloadExceeded
        ));
        assert!(permanent_publish_error(
            PublishErrorKind::WrongLastMessageId
        ));
        assert!(permanent_publish_error(PublishErrorKind::WrongLastSequence));

        for kind in [
            PublishErrorKind::StreamNotFound,
            PublishErrorKind::TimedOut,
            PublishErrorKind::BrokenPipe,
            PublishErrorKind::MaxAckPending,
            PublishErrorKind::Other,
        ] {
            assert!(!permanent_publish_error(kind));
        }
    }

    #[test]
    fn generated_message_id_is_stable_header_safe_hex() {
        let message_id = new_message_id();
        let suffix = message_id
            .strip_prefix("flowgger-")
            .expect("message ID prefix");

        assert_eq!(suffix.len(), 32);
        assert!(suffix.bytes().all(|byte| byte.is_ascii_hexdigit()));
    }
}
