//! A Flowgger output that publishes every log record to a NATS JetStream subject.
//! Enable with `--features nats-output`.

#[cfg(all(feature = "nats-output", feature = "gelf"))]
use serde_json::Value;
#[cfg(feature = "nats-output")]
use {
    super::Output,
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
async fn receive_record(arx: Arc<Mutex<Receiver<Vec<u8>>>>) -> Result<Option<Vec<u8>>, String> {
    tokio::task::spawn_blocking(move || {
        let receiver = arx
            .lock()
            .map_err(|_| "Flowgger NATS output queue mutex is poisoned".to_string())?;

        match receiver.recv() {
            Ok(bytes) => Ok(Some(bytes)),
            Err(_) => Ok(None),
        }
    })
    .await
    .map_err(|err| format!("Flowgger NATS output queue task failed: {err}"))?
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
    subject: String,
    stream: String,
    stream_replicas: usize,
    partition: String,
    timeout: Duration,
    tls_cert: Option<PathBuf>,
    tls_key: Option<PathBuf>,
    tls_ca: Option<PathBuf>,
    creds_file: Option<PathBuf>,
    connect_attempts: u32,
    connect_initial_backoff: Duration,
    connect_max_backoff: Duration,
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
                subject,
                stream,
                stream_replicas,
                partition,
                timeout,
                tls_cert,
                tls_key,
                tls_ca,
                creds_file,
                connect_attempts,
                connect_initial_backoff,
                connect_max_backoff,
            },
            workers,
        }
    }
}

#[cfg(feature = "nats-output")]
struct NATSWorker {
    arx: Arc<Mutex<Receiver<Vec<u8>>>>,
    cfg: NATSConfig,
    merger: Option<Box<dyn Merger + Send>>,
}

#[cfg(feature = "nats-output")]
impl NATSWorker {
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
        let client = options.connect(&self.cfg.url).await?;
        let js = ContextBuilder::new()
            .timeout(self.cfg.timeout)
            .ack_timeout(self.cfg.timeout)
            .build(client.clone());

        match js.get_stream(&self.cfg.stream).await {
            Ok(mut stream) => {
                let info = stream.info().await?;
                let mut updated_config = info.config.clone();
                let mut changed = false;

                // Skip the append when an existing subject (e.g. `logs.>` on the shared
                // `events` stream) already covers ours — a literal `logs.syslog` append
                // would self-overlap and JetStream rejects the UPDATE (10052, #4302).
                if !updated_config
                    .subjects
                    .iter()
                    .any(|existing| subject_covers(existing, &self.cfg.subject))
                {
                    updated_config.subjects.push(self.cfg.subject.clone());
                    changed = true;
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
                    subjects: vec![self.cfg.subject.clone()],
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
        publish: PublishMessage,
    ) -> Result<(), PublishFailure> {
        // Start the dedupe clock before handing the request to async-nats. If
        // send_publish succeeds, the server could persist the record at any
        // point after this instant even when its ACK never reaches us.
        let possible_store_started = Instant::now();
        let ack: PublishAckFuture = js
            .send_publish(self.cfg.subject.clone(), publish)
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
        connection: &mut NATSConnection,
        publish: PublishMessage,
        message_id: &str,
        payload_size: usize,
    ) -> Result<(), String> {
        let mut retry_count = 0_u64;
        let mut first_possible_store = None;
        let mut retry_deadline = None;
        let mut backoff = min(
            self.cfg.connect_initial_backoff,
            self.cfg.connect_max_backoff,
        );

        loop {
            if let Some(deadline) = retry_deadline {
                remaining_retry_budget(deadline, Instant::now()).ok_or_else(|| {
                    format!(
                        "NATS acknowledgment retry horizon exhausted for message_id={message_id} subject={} (duplicate_window={:?}); refusing an unsafe duplicate retry",
                        self.cfg.subject, connection.duplicate_window
                    )
                })?;
            }

            match self.publish_once(&connection.js, publish.clone()).await {
                Ok(()) => return Ok(()),
                Err(failure) if permanent_publish_error(failure.error.kind()) => {
                    eprintln!(
                        "Dropping NATS record message_id={message_id} subject={} bytes={payload_size}: permanent {} error: {}",
                        self.cfg.subject, failure.stage, failure.error
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
                                self.cfg.subject,
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
                                        self.cfg.subject, failure.stage, failure.error
                                    )
                                })?;
                            retry_delay(backoff, remaining).ok_or_else(|| {
                                format!(
                                    "NATS acknowledgment retry horizon has only {remaining:?} remaining for message_id={message_id} subject={}, less than retry backoff {backoff:?}; refusing an unsafe duplicate retry",
                                    self.cfg.subject
                                )
                            })?
                        }
                        None => backoff,
                    };
                    eprintln!(
                        "NATS {} failed for message_id={message_id} subject={} (retry {retry_count}): {}. Reconnecting in {:?}...",
                        failure.stage, self.cfg.subject, failure.error, delay
                    );

                    sleep(delay).await;
                    let new_connection = match retry_deadline {
                        Some(deadline) => {
                            let remaining = remaining_retry_budget(deadline, Instant::now())
                                .ok_or_else(|| {
                                    format!(
                                        "NATS acknowledgment retry horizon exhausted while reconnecting message_id={message_id} subject={}",
                                        self.cfg.subject
                                    )
                                })?;
                            timeout(remaining, self.connect_with_retry())
                                .await
                                .map_err(|_| {
                                    format!(
                                        "NATS reconnect exceeded the remaining {remaining:?} acknowledgment retry horizon for message_id={message_id} subject={}",
                                        self.cfg.subject
                                    )
                                })?
                        }
                        // A send-stage failure cannot have reached the NATS
                        // server. Until an ACK-ambiguous attempt occurs, retain
                        // the configured unlimited reconnect behavior.
                        None => self.connect_with_retry().await,
                    }
                    .map_err(|err| {
                        format!(
                            "NATS reconnect failed while retaining message_id={message_id} for retry: {err}"
                        )
                    })?;

                    if let Some(first_store) = first_possible_store {
                        let candidate_deadline = ack_retry_deadline(
                            first_store,
                            new_connection.duplicate_window,
                            self.cfg.timeout,
                        )
                        .ok_or_else(|| {
                            format!(
                                "NATS reconnected for message_id={message_id}, but stream duplicate_window={:?} no longer leaves a safe acknowledgment retry horizon",
                                new_connection.duplicate_window
                            )
                        })?;
                        retry_deadline = Some(match retry_deadline {
                            Some(existing) => min(existing, candidate_deadline),
                            None => candidate_deadline,
                        });
                    }

                    *connection = new_connection;
                    backoff = next_backoff(backoff, self.cfg.connect_max_backoff);
                }
            }
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

    async fn run(self) -> Result<(), String> {
        let mut connection = self.connect_with_retry().await.map_err(|err| {
            if self.cfg.connect_attempts == 0 {
                format!("NATS connection failed after unlimited retries: {err}")
            } else {
                format!(
                    "NATS connection failed after {} attempts: {err}",
                    self.cfg.connect_attempts
                )
            }
        })?;

        loop {
            // The Flowgger queue is synchronous. Receive it on Tokio's blocking
            // pool so async-nats heartbeat and reconnect tasks keep running while
            // syslog traffic is idle.
            let mut bytes = match receive_record(Arc::clone(&self.arx)).await? {
                Some(bytes) => bytes,
                None => {
                    self.flush_on_close(&connection).await;
                    return Ok(());
                }
            };

            #[cfg(feature = "gelf")]
            {
                if let Ok(mut v) = serde_json::from_slice::<Value>(&bytes)
                    && let Some(obj) = v.as_object_mut()
                {
                    if let Some(addr_val) = obj.get_mut("_remote_addr")
                        && let Some(s) = addr_val.as_str()
                    {
                        *addr_val = Value::String(format!("{}:{}", self.cfg.partition, s));
                    }
                    bytes = serde_json::to_vec(&v).unwrap_or(bytes);
                }
            }

            if let Some(m) = &self.merger {
                m.frame(&mut bytes);
            }

            // An ACK failure is ambiguous: JetStream may already have persisted
            // the record. Reuse one message ID across safe retries so the
            // stream's duplicate window suppresses a second stored copy.
            let payload_size = bytes.len();
            let message_id = new_message_id();
            let publish = PublishMessage::build()
                .payload(bytes.into())
                .message_id(&message_id);

            self.publish_with_retry(&mut connection, publish, &message_id, payload_size)
                .await?;
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
mod tests {
    use super::*;
    use std::sync::mpsc::sync_channel;

    #[test]
    fn idle_queue_does_not_block_current_thread_runtime() {
        let runtime = RtBuilder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let (tx, rx) = sync_channel(1);
        let arx = Arc::new(Mutex::new(rx));

        runtime.block_on(async move {
            let receive_task = tokio::spawn(receive_record(arx));

            timeout(Duration::from_secs(1), sleep(Duration::from_millis(10)))
                .await
                .expect("the current-thread runtime must remain live while the queue is idle");
            assert!(!receive_task.is_finished());

            drop(tx);
            assert_eq!(receive_task.await.unwrap().unwrap(), None);
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
