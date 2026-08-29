use anyhow::Result;
use log::{debug, info, warn};
use std::collections::HashMap;
use std::fmt::Write as _;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio::time::{interval, timeout};

pub struct ListenerMetrics {
    pub protocol: &'static str,
    pub listen_addr: String,
    pub packets_received: AtomicU64,
    pub flows_converted: AtomicU64,
    /// Total flows discarded *before* the publisher channel (currently only
    /// degenerate flows with 0 bytes and 0 packets).
    pub flows_dropped: AtomicU64,
    /// Flows rejected by `mpsc::try_send` because the per-listener publisher
    /// channel was at capacity. Tracked separately from `flows_dropped` so
    /// operators can tell parser-side filtering from backpressure overflow.
    pub channel_full_drops: AtomicU64,
    pub parse_errors: AtomicU64,
    /// Datagrams that could not be recognised as this protocol at all (wrong
    /// version, too short to scope). A UDP listener on a well-known port
    /// receives arbitrary internet noise -- a stray DNS reply, a port scan --
    /// so this is expected traffic, not a fault, and is counted apart from
    /// `parse_errors` so one stray packet cannot make a healthy listener look
    /// permanently broken.
    pub undecodable_datagrams: AtomicU64,
    /// Templates restored from the secondary `TemplateStore` on a primary
    /// cache miss. Mirrored from the netflow parser's `CacheMetrics` —
    /// always 0 for sFlow listeners (sFlow is template-less).
    pub template_store_restored: AtomicU64,
    /// Corrupted/un-decodable secondary-store payloads. Non-zero rate
    /// indicates a wire-format mismatch or operator-injected garbage.
    pub template_store_codec_errors: AtomicU64,
    /// Backend (NATS) failures from get/put/remove. Non-zero rate
    /// indicates the secondary tier is unhealthy. Parsing degrades
    /// gracefully — packets fall back to the local-only behavior.
    pub template_store_backend_errors: AtomicU64,
    /// Number of distinct exporters (sources) currently tracked by the
    /// AutoScopedParser for this listener. NetFlow only.
    pub source_count: AtomicU64,
}

impl ListenerMetrics {
    pub fn new(protocol: &'static str, listen_addr: String) -> Self {
        Self {
            protocol,
            listen_addr,
            packets_received: AtomicU64::new(0),
            flows_converted: AtomicU64::new(0),
            flows_dropped: AtomicU64::new(0),
            channel_full_drops: AtomicU64::new(0),
            parse_errors: AtomicU64::new(0),
            undecodable_datagrams: AtomicU64::new(0),
            template_store_restored: AtomicU64::new(0),
            template_store_codec_errors: AtomicU64::new(0),
            template_store_backend_errors: AtomicU64::new(0),
            source_count: AtomicU64::new(0),
        }
    }
}

/// Per-subject drop counter. Records how many messages destined for a given
/// NATS subject were rejected because the per-listener publisher channel was
/// full. Operators consult this to identify which listener/subject combo is
/// overflowing.
///
/// This is intentionally a separate registry from `HostSliceMetricsRegistry`
/// because we want to track drops on *any* subject (the raw protocol subject
/// as well as host-slice fan-out subjects), not just the host-slice subset
/// that has a pre-allocated `HostSliceMetrics`.
#[derive(Default)]
pub struct SubjectDropRegistry {
    counters: RwLock<HashMap<String, Arc<AtomicU64>>>,
}

impl SubjectDropRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Increment the drop counter for `subject`, creating it if it does not
    /// yet exist. Returns the new value.
    pub fn record_drop(&self, subject: &str) -> u64 {
        // Fast path: subject already known.
        if let Some(counter) = self
            .counters
            .read()
            .expect("subject drop lock poisoned")
            .get(subject)
        {
            return counter.fetch_add(1, Ordering::Relaxed) + 1;
        }

        // Slow path: insert a new counter under the write lock.
        let mut guard = self.counters.write().expect("subject drop lock poisoned");
        let counter = guard
            .entry(subject.to_string())
            .or_insert_with(|| Arc::new(AtomicU64::new(0)))
            .clone();
        drop(guard);
        counter.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// Returns a sorted snapshot of `(subject, total_drops)` pairs.
    pub fn snapshot(&self) -> Vec<(String, u64)> {
        let guard = self.counters.read().expect("subject drop lock poisoned");
        let mut entries: Vec<(String, u64)> = guard
            .iter()
            .map(|(subject, counter)| (subject.clone(), counter.load(Ordering::Relaxed)))
            .collect();
        drop(guard);
        entries.sort_by(|left, right| left.0.cmp(&right.0));
        entries
    }
}

pub struct HostSliceMetrics {
    pub agent_id: String,
    pub subject: String,
    pub records_published: AtomicU64,
    pub bytes_published: AtomicU64,
    pub subscribers_active: AtomicU64,
}

impl HostSliceMetrics {
    pub fn new(agent_id: String, subject: String, subscribers_active: u64) -> Self {
        Self {
            agent_id,
            subject,
            records_published: AtomicU64::new(0),
            bytes_published: AtomicU64::new(0),
            subscribers_active: AtomicU64::new(subscribers_active),
        }
    }

    pub fn record_published(&self, bytes: usize) {
        self.records_published.fetch_add(1, Ordering::Relaxed);
        self.bytes_published
            .fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

#[derive(Default)]
pub struct HostSliceMetricsRegistry {
    by_subject: HashMap<String, Arc<HostSliceMetrics>>,
}

impl HostSliceMetricsRegistry {
    pub fn new(slices: Vec<(String, String)>) -> Self {
        let by_subject = slices
            .into_iter()
            .map(|(agent_id, subject)| {
                (
                    subject.clone(),
                    Arc::new(HostSliceMetrics::new(agent_id, subject, 1)),
                )
            })
            .collect();

        Self { by_subject }
    }

    pub fn record_publish(&self, subject: &str, bytes: usize) {
        if let Some(metrics) = self.by_subject.get(subject) {
            metrics.record_published(bytes);
        }
    }

    pub fn all(&self) -> Vec<Arc<HostSliceMetrics>> {
        let mut metrics: Vec<_> = self.by_subject.values().cloned().collect();
        metrics.sort_by(|left, right| left.subject.cmp(&right.subject));
        metrics
    }
}

pub struct MetricsReporter;

impl MetricsReporter {
    pub async fn run(
        listeners: Vec<Arc<ListenerMetrics>>,
        host_slices: Arc<HostSliceMetricsRegistry>,
        subject_drops: Arc<SubjectDropRegistry>,
    ) {
        let mut ticker = interval(Duration::from_secs(30));

        loop {
            ticker.tick().await;

            for metrics in &listeners {
                let packets = metrics.packets_received.load(Ordering::Relaxed);
                let flows = metrics.flows_converted.load(Ordering::Relaxed);
                let dropped = metrics.flows_dropped.load(Ordering::Relaxed);
                let channel_full = metrics.channel_full_drops.load(Ordering::Relaxed);
                let errors = metrics.parse_errors.load(Ordering::Relaxed);
                let undecodable = metrics.undecodable_datagrams.load(Ordering::Relaxed);
                let restored = metrics.template_store_restored.load(Ordering::Relaxed);
                let codec = metrics.template_store_codec_errors.load(Ordering::Relaxed);
                let backend = metrics
                    .template_store_backend_errors
                    .load(Ordering::Relaxed);
                let sources = metrics.source_count.load(Ordering::Relaxed);

                info!(
                    "[{}@{}] packets_received: {}, flows_converted: {}, flows_dropped: {}, \
                     channel_full_drops: {}, parse_errors: {}, undecodable_datagrams: {}, \
                     sources: {}, template_store_restored: {}, \
                     template_store_codec_errors: {}, template_store_backend_errors: {}",
                    metrics.protocol,
                    metrics.listen_addr,
                    packets,
                    flows,
                    dropped,
                    channel_full,
                    errors,
                    undecodable,
                    sources,
                    restored,
                    codec,
                    backend,
                );
            }

            for metrics in host_slices.all() {
                let records = metrics.records_published.load(Ordering::Relaxed);
                let bytes = metrics.bytes_published.load(Ordering::Relaxed);
                let subscribers = metrics.subscribers_active.load(Ordering::Relaxed);

                info!(
                    "[host-slice:{}@{}] records_published_total: {}, bytes_published_total: {}, subscribers_active: {}",
                    metrics.agent_id, metrics.subject, records, bytes, subscribers
                );
            }

            for (subject, drops) in subject_drops.snapshot() {
                if drops > 0 {
                    info!(
                        "[subject-drop:{}] channel_full_drops_total: {}",
                        subject, drops
                    );
                }
            }
        }
    }
}

/// Escape a Prometheus label value per the exposition format spec:
/// `\` -> `\\`, `"` -> `\"`, `\n` -> `\n`. Today our label values are
/// `host:port` strings that have none of these characters, but the
/// contract is "anything an operator puts in JSON ends up here" and we
/// don't want a future IPv6 zone identifier or unusual address format
/// to break the exposition.
fn escape_label(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '\\' => out.push_str(r"\\"),
            '"' => out.push_str(r#"\""#),
            '\n' => out.push_str(r"\n"),
            other => out.push(other),
        }
    }
    out
}

/// Render the current ListenerMetrics snapshot in Prometheus text exposition
/// format (https://prometheus.io/docs/instrumenting/exposition_formats/).
///
/// Hand-rolled rather than pulling in the `prometheus` crate because we
/// have a small fixed set of metrics and no need for histograms / summaries.
pub fn render_prometheus(listeners: &[Arc<ListenerMetrics>]) -> String {
    let mut out = String::with_capacity(1024);

    macro_rules! help_type {
        ($name:expr, $help:expr, $type:expr) => {{
            let _ = writeln!(out, "# HELP {} {}", $name, $help);
            let _ = writeln!(out, "# TYPE {} {}", $name, $type);
        }};
    }

    /// Emit one row per listener. `filter` lets a metric opt out of
    /// listeners where it's structurally always zero (e.g. sFlow has no
    /// templates, so template_store_* rows would be noise).
    fn emit(
        out: &mut String,
        name: &str,
        ms: &[Arc<ListenerMetrics>],
        filter: impl Fn(&ListenerMetrics) -> bool,
        get: impl Fn(&ListenerMetrics) -> u64,
    ) {
        for m in ms {
            if !filter(m) {
                continue;
            }
            let _ = writeln!(
                out,
                "{}{{protocol=\"{}\",listen_addr=\"{}\"}} {}",
                name,
                escape_label(m.protocol),
                escape_label(&m.listen_addr),
                get(m),
            );
        }
    }
    let any = |_: &ListenerMetrics| true;
    let netflow_only = |m: &ListenerMetrics| m.protocol == "netflow";

    help_type!(
        "flow_collector_packets_received_total",
        "Total UDP datagrams received by the listener",
        "counter"
    );
    emit(
        &mut out,
        "flow_collector_packets_received_total",
        listeners,
        any,
        |m| m.packets_received.load(Ordering::Relaxed),
    );

    help_type!(
        "flow_collector_flows_converted_total",
        "Total flow records successfully decoded and forwarded to NATS",
        "counter"
    );
    emit(
        &mut out,
        "flow_collector_flows_converted_total",
        listeners,
        any,
        |m| m.flows_converted.load(Ordering::Relaxed),
    );

    help_type!(
        "flow_collector_flows_dropped_total",
        "Total flow records dropped (degenerate, channel full, etc.)",
        "counter"
    );
    emit(
        &mut out,
        "flow_collector_flows_dropped_total",
        listeners,
        any,
        |m| m.flows_dropped.load(Ordering::Relaxed),
    );

    help_type!(
        "flow_collector_parse_errors_total",
        "Total UDP datagrams that failed to parse",
        "counter"
    );
    emit(
        &mut out,
        "flow_collector_parse_errors_total",
        listeners,
        any,
        |m| m.parse_errors.load(Ordering::Relaxed),
    );

    help_type!(
        "flow_collector_sources",
        "Distinct exporter sources currently tracked by the parser",
        "gauge"
    );
    emit(
        &mut out,
        "flow_collector_sources",
        listeners,
        netflow_only,
        |m| m.source_count.load(Ordering::Relaxed),
    );

    help_type!(
        "flow_collector_template_store_restored_total",
        "Templates restored from the secondary store on cache miss",
        "counter"
    );
    emit(
        &mut out,
        "flow_collector_template_store_restored_total",
        listeners,
        netflow_only,
        |m| m.template_store_restored.load(Ordering::Relaxed),
    );

    help_type!(
        "flow_collector_template_store_codec_errors_total",
        "Corrupted secondary-store payloads (wire-format mismatch or garbage)",
        "counter"
    );
    emit(
        &mut out,
        "flow_collector_template_store_codec_errors_total",
        listeners,
        netflow_only,
        |m| m.template_store_codec_errors.load(Ordering::Relaxed),
    );

    help_type!(
        "flow_collector_template_store_backend_errors_total",
        "Backend (NATS KV) get/put/remove failures",
        "counter"
    );
    emit(
        &mut out,
        "flow_collector_template_store_backend_errors_total",
        listeners,
        netflow_only,
        |m| m.template_store_backend_errors.load(Ordering::Relaxed),
    );

    out
}

/// Maximum simultaneous in-flight `/metrics` connections. Prometheus
/// scrape rates rarely exceed 1 conn/sec; the cap is a defensive ceiling
/// against a misbehaving or hostile scraper holding many connections
/// open. Excess connections are rejected immediately so the FD is freed,
/// rather than queued (which would let an attacker exhaust file
/// descriptors by just opening sockets).
const MAX_CONCURRENT_CONNECTIONS: usize = 64;

/// Maximum bytes read from a single `/metrics` request (request line +
/// headers). A correctly formed Prometheus scrape is under 1 KiB; 8 KiB
/// leaves room for verbose `User-Agent` headers without enabling abuse.
/// Anything larger is treated as malformed and the connection is dropped
/// without a response.
const MAX_REQUEST_BYTES: u64 = 8 * 1024;

/// Per-read deadline for the request line and each header line. A
/// well-behaved scraper writes the entire request in one TCP segment;
/// 3 seconds is generous for any realistic network path while bounding
/// the cost of slowloris-style dribbling.
const READ_TIMEOUT: Duration = Duration::from_secs(3);

/// Deadline for writing the response. The exposition is small (typically
/// a few KiB) so 5 seconds is plenty even on a slow link; bounded so a
/// client with a closed receive window cannot pin a server task forever.
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);

/// Spawn a tiny HTTP server on `addr` that serves the Prometheus
/// exposition at `GET /metrics` and publisher readiness at `GET /readyz`.
/// Any other path returns 404. Hand-rolled HTTP/1.1 to avoid pulling
/// axum/hyper in for two endpoints.
///
/// `/readyz` is deliberately NOT the same signal as "this server is
/// answering": it reports `200` only while `ready_path` exists on disk
/// (the same file `Publisher::mark_publisher_ready`/`clear_publisher_ready`
/// write), and `503` otherwise. The HTTP server itself binds independently
/// of the publisher (see `main.rs`), so `/metrics` alone would report a pod
/// Ready before it has ever connected to NATS -- this is what the Helm
/// readinessProbe checks instead.
///
/// Defensive measures:
/// * Per-connection read/write timeouts (see [`READ_TIMEOUT`],
///   [`WRITE_TIMEOUT`]).
/// * Bounded total request size (see [`MAX_REQUEST_BYTES`]) so a
///   slowloris client can't keep a connection alive by trickling
///   bytes within the per-read timeout.
/// * Bounded concurrent connections (see [`MAX_CONCURRENT_CONNECTIONS`])
///   via a semaphore. New connections beyond the cap are dropped
///   immediately rather than queued, so a hostile scraper cannot
///   exhaust file descriptors just by opening sockets.
pub async fn run_prometheus_server(
    addr: String,
    listeners: Vec<Arc<ListenerMetrics>>,
    ready_path: PathBuf,
) -> Result<()> {
    let socket = TcpListener::bind(&addr)
        .await
        .map_err(|e| anyhow::anyhow!("bind metrics server on {}: {}", addr, e))?;
    info!(
        "Prometheus metrics endpoint listening on http://{}/metrics (max_concurrent={})",
        addr, MAX_CONCURRENT_CONNECTIONS
    );

    let limiter = Arc::new(Semaphore::new(MAX_CONCURRENT_CONNECTIONS));

    loop {
        let (conn, peer) = match socket.accept().await {
            Ok(v) => v,
            Err(e) => {
                warn!("metrics accept error: {}", e);
                continue;
            }
        };

        // Fast-fail when we're at capacity — drop the connection so the FD
        // is released immediately. Queueing would let an attacker exhaust
        // ulimit by opening N+1 sockets and walking away.
        let permit = match Arc::clone(&limiter).try_acquire_owned() {
            Ok(p) => p,
            Err(_) => {
                debug!(
                    "metrics server at concurrency limit ({}); dropping conn from {}",
                    MAX_CONCURRENT_CONNECTIONS, peer
                );
                drop(conn);
                continue;
            }
        };

        let listeners = listeners.clone();
        let ready_path = ready_path.clone();
        tokio::spawn(async move {
            // Permit is held for the lifetime of this task and released on
            // drop, regardless of how serve_one exits.
            let _permit = permit;
            if let Err(e) = serve_one(conn, &listeners, &ready_path).await {
                warn!("metrics conn from {} error: {}", peer, e);
            }
        });
    }
}

async fn serve_one(
    conn: tokio::net::TcpStream,
    listeners: &[Arc<ListenerMetrics>],
    ready_path: &Path,
) -> io::Result<()> {
    let (read_half, mut write_half) = conn.into_split();
    // `take` caps how many bytes the BufReader can pull from the socket.
    // After MAX_REQUEST_BYTES the reader returns EOF, which the read_line
    // calls below treat as "client disconnected" and bail without
    // responding. This bounds slowloris-style attacks even within the
    // per-read timeout window.
    let bounded = read_half.take(MAX_REQUEST_BYTES);
    let mut reader = BufReader::new(bounded);

    // Request line, with both a per-read timeout and (via `bounded`) a
    // bytes cap.
    let mut request_line = String::new();
    let n = match timeout(READ_TIMEOUT, reader.read_line(&mut request_line)).await {
        Ok(r) => r?,
        Err(_) => {
            debug!("metrics request-line read timed out");
            return Ok(());
        }
    };
    if n == 0 {
        // EOF before request line — client disconnected or hit MAX_REQUEST_BYTES.
        return Ok(());
    }

    // Drain headers (until empty line) so we don't leave the socket in a
    // weird half-read state. Same per-line timeout and the same shared
    // bytes cap as the request line.
    loop {
        let mut header = String::new();
        let m = match timeout(READ_TIMEOUT, reader.read_line(&mut header)).await {
            Ok(r) => r?,
            Err(_) => {
                debug!("metrics header read timed out");
                return Ok(());
            }
        };
        if m == 0 || header == "\r\n" || header == "\n" {
            break;
        }
    }

    let path = request_line.split_whitespace().nth(1).unwrap_or("/");
    let (status, body) = if path.starts_with("/readyz") {
        // Same file Publisher::mark_publisher_ready/clear_publisher_ready
        // write on the connect/disconnect path -- this is what makes the
        // probe reflect true publisher readiness rather than just "the
        // metrics HTTP server has bound its socket".
        if ready_path.exists() {
            ("200 OK", "ready\n".to_string())
        } else {
            ("503 Service Unavailable", "not ready\n".to_string())
        }
    } else if path.starts_with("/metrics") {
        ("200 OK", render_prometheus(listeners))
    } else {
        debug!("metrics server returning 404 for path {:?}", path);
        ("404 Not Found", "not found\n".to_string())
    };

    let resp = format!(
        "HTTP/1.1 {}\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        status,
        body.len(),
        body,
    );

    // Write timeout protects against a client with a closed receive
    // window that would otherwise keep the task pinned indefinitely.
    match timeout(WRITE_TIMEOUT, async {
        write_half.write_all(resp.as_bytes()).await?;
        write_half.shutdown().await?;
        io::Result::Ok(())
    })
    .await
    {
        Ok(r) => r?,
        Err(_) => {
            debug!("metrics response write timed out");
            return Ok(());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn host_slice_registry_records_published_bytes_by_subject() {
        let registry = HostSliceMetricsRegistry::new(vec![(
            "agent-1".to_string(),
            "flow.host-slice.agent-1".to_string(),
        )]);

        registry.record_publish("flow.host-slice.agent-1", 128);
        registry.record_publish("flows.raw.netflow", 1024);

        let metrics = registry.all();

        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0].agent_id, "agent-1");
        assert_eq!(metrics[0].records_published.load(Ordering::Relaxed), 1);
        assert_eq!(metrics[0].bytes_published.load(Ordering::Relaxed), 128);
        assert_eq!(metrics[0].subscribers_active.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn subject_drop_registry_accumulates_per_subject() {
        let registry = SubjectDropRegistry::new();

        assert_eq!(registry.record_drop("flows.raw.sflow"), 1);
        assert_eq!(registry.record_drop("flows.raw.sflow"), 2);
        assert_eq!(registry.record_drop("flow.host-slice.agent-1"), 1);

        let snapshot = registry.snapshot();
        assert_eq!(
            snapshot,
            vec![
                ("flow.host-slice.agent-1".to_string(), 1),
                ("flows.raw.sflow".to_string(), 2),
            ]
        );
    }

    #[test]
    fn subject_drop_registry_snapshot_empty_when_no_drops() {
        let registry = SubjectDropRegistry::new();
        assert!(registry.snapshot().is_empty());
    }

    use super::*;
    use tokio::io::AsyncReadExt;
    use tokio::net::TcpStream;

    #[test]
    fn escape_label_handles_quotes_backslashes_newlines() {
        assert_eq!(escape_label("simple"), "simple");
        assert_eq!(escape_label(r#"with"quote"#), r#"with\"quote"#);
        assert_eq!(escape_label(r"with\back"), r"with\\back");
        assert_eq!(escape_label("with\nnewline"), r"with\nnewline");
        assert_eq!(escape_label("0.0.0.0:2055"), "0.0.0.0:2055");
    }

    #[test]
    fn template_store_metrics_only_emit_for_netflow_listeners() {
        let nf = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let sf = Arc::new(ListenerMetrics::new("sflow", "0.0.0.0:6343".into()));
        let out = render_prometheus(&[nf, sf]);
        // Both should appear for packets_received
        assert!(out.contains(r#"flow_collector_packets_received_total{protocol="netflow""#));
        assert!(out.contains(r#"flow_collector_packets_received_total{protocol="sflow""#));
        // sFlow should NOT appear in template_store_* rows
        assert!(out.contains(r#"flow_collector_template_store_restored_total{protocol="netflow""#));
        assert!(!out.contains(r#"flow_collector_template_store_restored_total{protocol="sflow""#));
        assert!(!out.contains(r#"flow_collector_sources{protocol="sflow""#));
    }

    /// Spawn the server bound to a random port and return the address +
    /// the JoinHandle so callers can abort if needed.
    async fn spawn_test_server(listeners: Vec<Arc<ListenerMetrics>>) -> std::net::SocketAddr {
        let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        drop(socket);
        let addr_str = addr.to_string();
        // These tests never touch /readyz; a path that never exists is fine.
        let ready_path = std::env::temp_dir().join("flow-collector-metrics-test-unused-ready");
        tokio::spawn(async move {
            let _ = run_prometheus_server(addr_str, listeners, ready_path).await;
        });
        // Tiny delay for the server's bind to land before tests connect.
        tokio::time::sleep(Duration::from_millis(50)).await;
        addr
    }

    /// Slow-client / slowloris defense: connect, never write a complete
    /// request line, verify the server closes the connection within the
    /// read timeout window instead of hanging forever.
    #[tokio::test(flavor = "multi_thread")]
    async fn http_server_drops_idle_connection_within_read_timeout() {
        let nf = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let addr = spawn_test_server(vec![nf]).await;

        // Connect, send nothing, then read until EOF. The server should
        // close us out around READ_TIMEOUT (3s); we give it 2x as a buffer
        // and assert close happens *before* the buffer expires.
        let mut s = TcpStream::connect(addr).await.unwrap();
        let close = tokio::time::timeout(READ_TIMEOUT * 2, async move {
            let mut buf = Vec::new();
            // read_to_end returns when the peer closes the write half.
            s.read_to_end(&mut buf).await.unwrap();
            buf
        })
        .await;
        assert!(
            close.is_ok(),
            "server should close idle connection within 2x READ_TIMEOUT, but did not"
        );
    }

    /// Concurrency cap: open more than MAX_CONCURRENT_CONNECTIONS slow
    /// connections, then verify a fresh `/metrics` request still gets
    /// served (i.e. the cap fast-fails new conns rather than queueing
    /// them — meaning the accept loop keeps running and a real scraper
    /// isn't starved by a slowloris flood).
    #[tokio::test(flavor = "multi_thread")]
    async fn http_server_concurrency_cap_fast_fails_excess_connections() {
        let nf = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let addr = spawn_test_server(vec![nf]).await;

        // Hold MAX_CONCURRENT_CONNECTIONS slow connections open. We don't
        // need to write anything — leaving them idle keeps the permits
        // taken until the server times them out.
        let mut hogs = Vec::with_capacity(MAX_CONCURRENT_CONNECTIONS);
        for _ in 0..MAX_CONCURRENT_CONNECTIONS {
            hogs.push(TcpStream::connect(addr).await.unwrap());
        }
        // Brief settle so the server's accept loop has run for each.
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Excess connection. The accept happens (TCP-level), then the
        // server fast-fails: it drops the conn, peer sees connection
        // closed before any response. Either way, we should NOT hang.
        let mut excess = TcpStream::connect(addr).await.unwrap();
        let _ = excess
            .write_all(b"GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n")
            .await;
        let mut resp = Vec::new();
        let read =
            tokio::time::timeout(Duration::from_secs(2), excess.read_to_end(&mut resp)).await;
        assert!(
            read.is_ok(),
            "excess connection should not hang past 2s — server should drop it fast"
        );
        // Either: we got dropped immediately (resp empty), or the server
        // happened to have a free permit by the time it processed us.
        // Both are acceptable; the failure mode is "task hangs forever".
        // Drop the hogs so the test cleans up promptly.
        drop(hogs);
    }

    /// End-to-end smoke test of `run_prometheus_server`: spin it up on a
    /// random port, hit `/metrics` and a 404 path, verify response shape.
    /// Catches partial-read regressions in the request reader.
    #[tokio::test(flavor = "multi_thread")]
    async fn http_server_serves_metrics_and_404() {
        let nf = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        nf.packets_received.store(123, Ordering::Relaxed);
        let listeners = vec![nf];

        // Bind ephemerally so tests run in parallel safely.
        let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        // Re-bind via run_prometheus_server for a fair test of its accept loop.
        drop(socket);
        let listeners_for_server = listeners.clone();
        let addr_str = addr.to_string();
        // This test only exercises /metrics and 404; /readyz has its own
        // dedicated test below.
        let ready_path = std::env::temp_dir().join("flow-collector-metrics-test-unused-ready");
        tokio::spawn(async move {
            let _ = run_prometheus_server(addr_str, listeners_for_server, ready_path).await;
        });
        // Tiny delay for the server to start listening.
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Happy path: GET /metrics
        let mut s = TcpStream::connect(addr).await.unwrap();
        s.write_all(b"GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n")
            .await
            .unwrap();
        let mut resp = String::new();
        s.read_to_string(&mut resp).await.unwrap();
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "resp={resp}");
        assert!(resp.contains("flow_collector_packets_received_total"));
        assert!(resp.contains(" 123"));

        // 404 path
        let mut s = TcpStream::connect(addr).await.unwrap();
        s.write_all(b"GET /nope HTTP/1.1\r\nHost: x\r\n\r\n")
            .await
            .unwrap();
        let mut resp = String::new();
        s.read_to_string(&mut resp).await.unwrap();
        assert!(resp.starts_with("HTTP/1.1 404 Not Found"), "resp={resp}");

        // Partial-read regression: write the request line in two chunks
        // with a brief pause. With the old single-1KB-read code this would
        // mis-parse and 404 intermittently; with BufReader::read_line it
        // should still serve /metrics.
        let mut s = TcpStream::connect(addr).await.unwrap();
        s.write_all(b"GET /metr").await.unwrap();
        s.flush().await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        s.write_all(b"ics HTTP/1.1\r\nHost: x\r\n\r\n")
            .await
            .unwrap();
        let mut resp = String::new();
        s.read_to_string(&mut resp).await.unwrap();
        assert!(
            resp.starts_with("HTTP/1.1 200 OK"),
            "split-read resp={resp}"
        );
        assert!(resp.contains("flow_collector_packets_received_total"));
    }

    /// `/readyz` must track the *marker file*, not just "the metrics server
    /// has bound its socket" -- that distinction is the whole point of the
    /// endpoint (see `run_prometheus_server` docs): a pod that has bound
    /// its metrics port but not yet connected to NATS must read 503, and
    /// only flip to 200 once `Publisher::mark_publisher_ready`'s marker
    /// file actually exists.
    #[tokio::test(flavor = "multi_thread")]
    async fn http_server_readyz_tracks_marker_file_not_socket_bind() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let ready_path = std::env::temp_dir().join(format!("flow-collector-readyz-test-{nanos}"));
        // Guarantee a clean slate even if a previous run of this test
        // process crashed before cleanup.
        let _ = std::fs::remove_file(&ready_path);

        let listeners: Vec<Arc<ListenerMetrics>> = vec![];
        let socket = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        drop(socket);
        let addr_str = addr.to_string();
        let ready_path_for_server = ready_path.clone();
        tokio::spawn(async move {
            let _ = run_prometheus_server(addr_str, listeners, ready_path_for_server).await;
        });
        tokio::time::sleep(Duration::from_millis(50)).await;

        async fn get_readyz(addr: std::net::SocketAddr) -> String {
            let mut s = TcpStream::connect(addr).await.unwrap();
            s.write_all(b"GET /readyz HTTP/1.1\r\nHost: x\r\n\r\n")
                .await
                .unwrap();
            let mut resp = String::new();
            s.read_to_string(&mut resp).await.unwrap();
            resp
        }

        // Marker absent: not ready.
        let resp = get_readyz(addr).await;
        assert!(
            resp.starts_with("HTTP/1.1 503 Service Unavailable"),
            "resp={resp}"
        );

        // Marker created (mirrors Publisher::mark_publisher_ready): ready.
        std::fs::write(&ready_path, b"ready\n").unwrap();
        let resp = get_readyz(addr).await;
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "resp={resp}");

        // Marker removed (mirrors Publisher::clear_publisher_ready): not
        // ready again -- the socket never stopped listening, proving this
        // is not just "the server is up".
        std::fs::remove_file(&ready_path).unwrap();
        let resp = get_readyz(addr).await;
        assert!(
            resp.starts_with("HTTP/1.1 503 Service Unavailable"),
            "resp={resp}"
        );
    }

    #[test]
    fn render_includes_all_listeners_and_metric_names() {
        let a = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let b = Arc::new(ListenerMetrics::new("sflow", "0.0.0.0:6343".into()));
        a.packets_received.store(42, Ordering::Relaxed);
        a.template_store_restored.store(7, Ordering::Relaxed);
        b.flows_converted.store(99, Ordering::Relaxed);

        let out = render_prometheus(&[a, b]);

        // Every metric name appears with HELP/TYPE
        for name in [
            "flow_collector_packets_received_total",
            "flow_collector_flows_converted_total",
            "flow_collector_flows_dropped_total",
            "flow_collector_parse_errors_total",
            "flow_collector_sources",
            "flow_collector_template_store_restored_total",
            "flow_collector_template_store_codec_errors_total",
            "flow_collector_template_store_backend_errors_total",
        ] {
            assert!(
                out.contains(&format!("# HELP {}", name)),
                "missing HELP for {name}\n{out}"
            );
            assert!(
                out.contains(&format!("# TYPE {}", name)),
                "missing TYPE for {name}\n{out}"
            );
        }

        // Both listeners are emitted with their labels
        assert!(out.contains(r#"protocol="netflow""#));
        assert!(out.contains(r#"protocol="sflow""#));
        assert!(out.contains(r#"listen_addr="0.0.0.0:2055""#));
        assert!(out.contains(r#"listen_addr="0.0.0.0:6343""#));

        // Counter values land on the right line
        assert!(
            out.contains(
                r#"flow_collector_packets_received_total{protocol="netflow",listen_addr="0.0.0.0:2055"} 42"#
            )
        );
        assert!(
            out.contains(
                r#"flow_collector_template_store_restored_total{protocol="netflow",listen_addr="0.0.0.0:2055"} 7"#
            )
        );
        assert!(
            out.contains(
                r#"flow_collector_flows_converted_total{protocol="sflow",listen_addr="0.0.0.0:6343"} 99"#
            )
        );
    }
}
