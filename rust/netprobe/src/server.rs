use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use prost::Message;
use tokio::{
    net::{UnixListener, UnixStream},
    sync::mpsc::error::{TryRecvError, TrySendError},
    sync::{Mutex, broadcast, watch},
    time::{Instant, timeout},
};

use crate::{
    capabilities,
    event_queue::{EventReceiver, EventSender},
    external_flow::{ExternalFlowIngest, SharedExternalFlowMatcher},
    fingerprint::{
        FINGERPRINT_ENGINE_VERSION, JA4_BASE_SPEC_REVISION, MUONFP_CORPUS_REVISION,
        P0F_CORPUS_REVISION, RECOG_CORPUS_REVISION, SATORI_CORPUS_REVISION,
        SERVICERADAR_ADDITIONS_REVISION, SERVICERADAR_RECOG_ADDITIONS_REVISION,
    },
    framing::{MAX_FRAME_SIZE, read_frame, write_frame, write_frame_with_buffer},
    ipc::match_banner,
    metrics::Metrics,
    proto::netprobe::{
        ConfigAck, DeviceCensusSnapshot, DpiEvent, ErrorFrame, ExternalFlowAck, ExternalFlowRecord,
        FingerprintEvent, FlowAttributionEvent, FlowAttributionEventBatch, NetprobeFrame, PingAck,
        ProcessSnapshot, ProcessSnapshotEntry, netprobe_frame,
    },
    runtime_config::RuntimeConfig,
};

const FLOW_ATTRIBUTION_IPC_BATCH_MAX: usize = 256;
// NetFlow correlation is delayed by exporter flush cadence, so sub-second IPC
// latency is acceptable. A wider window turns busy worker attribution bursts
// into fewer Unix socket writes and protobuf encodes without dropping events.
const FLOW_ATTRIBUTION_IPC_BATCH_WAIT: Duration = Duration::from_millis(250);

pub struct IpcServer {
    socket_path: PathBuf,
    active_client: Arc<AtomicBool>,
    fingerprint_events: Arc<Mutex<EventReceiver<FingerprintEvent>>>,
    dpi_events: Arc<Mutex<EventReceiver<DpiEvent>>>,
    flow_attribution_events: EventSender<Arc<FlowAttributionEvent>>,
    flow_attribution_rx: Arc<Mutex<EventReceiver<Arc<FlowAttributionEvent>>>>,
    process_snapshots: broadcast::Sender<ProcessSnapshot>,
    census_snapshots: broadcast::Sender<DeviceCensusSnapshot>,
    external_flow_matcher: SharedExternalFlowMatcher,
    runtime_config: RuntimeConfig,
    metrics: Metrics,
}

impl IpcServer {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        socket_path: impl Into<PathBuf>,
        fingerprint_event_rx: EventReceiver<FingerprintEvent>,
        dpi_event_rx: EventReceiver<DpiEvent>,
        flow_attribution_events: EventSender<Arc<FlowAttributionEvent>>,
        flow_attribution_rx: EventReceiver<Arc<FlowAttributionEvent>>,
        process_snapshots: broadcast::Sender<ProcessSnapshot>,
        census_snapshots: broadcast::Sender<DeviceCensusSnapshot>,
        external_flow_matcher: SharedExternalFlowMatcher,
        runtime_config: RuntimeConfig,
        metrics: Metrics,
    ) -> Self {
        Self {
            socket_path: socket_path.into(),
            active_client: Arc::new(AtomicBool::new(false)),
            fingerprint_events: Arc::new(Mutex::new(fingerprint_event_rx)),
            dpi_events: Arc::new(Mutex::new(dpi_event_rx)),
            flow_attribution_events,
            flow_attribution_rx: Arc::new(Mutex::new(flow_attribution_rx)),
            process_snapshots,
            census_snapshots,
            external_flow_matcher,
            runtime_config,
            metrics,
        }
    }

    pub async fn run(self, mut shutdown: watch::Receiver<bool>) -> Result<()> {
        prepare_socket(&self.socket_path)?;
        let listener = UnixListener::bind(&self.socket_path)
            .with_context(|| format!("failed to bind {}", self.socket_path.display()))?;

        loop {
            tokio::select! {
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        return Ok(());
                    }
                }
                accepted = listener.accept() => {
                    let (stream, _) = accepted?;
                    if self.active_client.swap(true, Ordering::SeqCst) {
                        tokio::spawn(async move {
                            let _ = reject_concurrent_client(stream).await;
                        });
                        continue;
                    }

                    let active_client = Arc::clone(&self.active_client);
                    let fingerprint_rx = Arc::clone(&self.fingerprint_events);
                    let dpi_rx = Arc::clone(&self.dpi_events);
                    let flow_attribution_tx = self.flow_attribution_events.clone();
                    let flow_attribution_rx = Arc::clone(&self.flow_attribution_rx);
                    let process_snapshot_rx = self.process_snapshots.subscribe();
                    let census_snapshot_rx = self.census_snapshots.subscribe();
                    let external_flow_matcher = self.external_flow_matcher.clone();
                    let runtime_config = self.runtime_config.clone();
                    let metrics = self.metrics.clone();
                    tokio::spawn(async move {
                        let _guard = ActiveClientGuard(active_client);
                        let result = handle_client(
                            stream,
                            fingerprint_rx,
                            dpi_rx,
                            flow_attribution_tx,
                            flow_attribution_rx,
                            process_snapshot_rx,
                            census_snapshot_rx,
                            external_flow_matcher,
                            runtime_config,
                            metrics,
                        )
                        .await;
                        if let Err(err) = result {
                            log::warn!("netprobe IPC client disconnected with error: {err:#}");
                        }
                    });
                }
            }
        }
    }
}

struct ActiveClientGuard(Arc<AtomicBool>);

impl Drop for ActiveClientGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

fn prepare_socket(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create socket dir {}", parent.display()))?;
    }

    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to remove stale socket {}", path.display()))?;
    }

    Ok(())
}

async fn reject_concurrent_client(mut stream: UnixStream) -> Result<()> {
    let frame = NetprobeFrame {
        sequence: 0,
        payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
            code: "client_already_connected".to_string(),
            message: "netprobe accepts only one agent client".to_string(),
        })),
    };
    write_frame(&mut stream, &frame).await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn handle_client(
    stream: UnixStream,
    fingerprint_events: Arc<Mutex<EventReceiver<FingerprintEvent>>>,
    dpi_events: Arc<Mutex<EventReceiver<DpiEvent>>>,
    flow_attribution_tx: EventSender<Arc<FlowAttributionEvent>>,
    flow_attribution_events: Arc<Mutex<EventReceiver<Arc<FlowAttributionEvent>>>>,
    mut process_snapshots: broadcast::Receiver<ProcessSnapshot>,
    mut census_snapshots: broadcast::Receiver<DeviceCensusSnapshot>,
    external_flows: SharedExternalFlowMatcher,
    runtime_config: RuntimeConfig,
    metrics: Metrics,
) -> Result<()> {
    let (mut reader, mut writer) = stream.into_split();
    let mut encode_buffer = Vec::new();

    loop {
        tokio::select! {
            frame = read_frame(&mut reader) => {
                let Some(frame) = frame? else {
                    return Ok(());
                };
                if let Some(response) = response_for_frame(
                    frame,
                    &runtime_config,
                    &external_flows,
                    &metrics,
                    &flow_attribution_tx,
                ).await? {
                    write_reused_frame(&mut writer, &response, &mut encode_buffer, &metrics).await?;
                }
            }
            event = recv_event(&fingerprint_events) => {
                match event {
                    Some(event) => {
                        let frame = NetprobeFrame {
                            sequence: 0,
                            payload: Some(netprobe_frame::Payload::FingerprintEvent(event)),
                        };
                        write_reused_frame(&mut writer, &frame, &mut encode_buffer, &metrics).await?;
                    }
                    None => return Ok(()),
                }
            }
            event = recv_event(&dpi_events) => {
                match event {
                    Some(event) => {
                        let frame = NetprobeFrame {
                            sequence: 0,
                            payload: Some(netprobe_frame::Payload::DpiEvent(event)),
                        };
                        write_reused_frame(&mut writer, &frame, &mut encode_buffer, &metrics).await?;
                    }
                    None => return Ok(()),
                }
            }
            event = recv_event(&flow_attribution_events) => {
                match event {
                    Some(event) => {
                        if runtime_config.flow_attribution_ipc_batch_enabled() {
                            write_flow_attribution_batch_frame(
                                &mut writer,
                                event,
                                &flow_attribution_events,
                                &mut encode_buffer,
                                &metrics,
                            ).await?;
                        } else {
                            let frame = NetprobeFrame {
                                sequence: 0,
                                payload: Some(netprobe_frame::Payload::FlowAttributionEvent((*event).clone())),
                            };
                            write_reused_frame(&mut writer, &frame, &mut encode_buffer, &metrics).await?;
                        }
                    }
                    None => return Ok(()),
                }
            }
            snapshot = process_snapshots.recv() => {
                match snapshot {
                    Ok(snapshot) => {
                        write_process_snapshot_frames(
                            &mut writer,
                            snapshot,
                            &mut encode_buffer,
                            &metrics,
                        ).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        metrics.inc_process_snapshot_events_dropped("lagged_receiver", skipped);
                        log::warn!("netprobe IPC client lagged; skipped {skipped} process snapshot(s)");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        return Ok(());
                    }
                }
            }
            snapshot = census_snapshots.recv() => {
                match snapshot {
                    Ok(snapshot) => {
                        write_census_snapshot_frames(
                            &mut writer,
                            snapshot,
                            &mut encode_buffer,
                            &metrics,
                        ).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        // Dropping stale census snapshots is CORRECT, not a
                        // degradation: each one is a complete replacement for
                        // the last, so the newest carries everything the
                        // skipped ones would have said.
                        metrics.inc_device_census_snapshot_events_dropped("lagged_receiver", skipped);
                        log::debug!("netprobe IPC client lagged; skipped {skipped} superseded census snapshot(s)");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        return Ok(());
                    }
                }
            }
        }
    }
}

async fn recv_event<T>(receiver: &Arc<Mutex<EventReceiver<T>>>) -> Option<T> {
    receiver.lock().await.recv().await
}

async fn write_flow_attribution_batch_frame<W>(
    writer: &mut W,
    first: Arc<FlowAttributionEvent>,
    flow_attribution_events: &Arc<Mutex<EventReceiver<Arc<FlowAttributionEvent>>>>,
    encode_buffer: &mut Vec<u8>,
    metrics: &Metrics,
) -> Result<(), crate::framing::FramingError>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    let batch_start_unix_nano = now_unix_nano();
    let deadline = Instant::now() + FLOW_ATTRIBUTION_IPC_BATCH_WAIT;
    let mut events = Vec::with_capacity(FLOW_ATTRIBUTION_IPC_BATCH_MAX.min(64));

    events.push((*first).clone());

    while events.len() < FLOW_ATTRIBUTION_IPC_BATCH_MAX {
        {
            let mut receiver = flow_attribution_events.lock().await;
            loop {
                if events.len() >= FLOW_ATTRIBUTION_IPC_BATCH_MAX {
                    break;
                }
                match receiver.try_recv() {
                    Ok(event) => events.push((*event).clone()),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => break,
                }
            }
        }

        if events.len() >= FLOW_ATTRIBUTION_IPC_BATCH_MAX {
            break;
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }

        match timeout(remaining, recv_event(flow_attribution_events)).await {
            Ok(Some(event)) => events.push((*event).clone()),
            Ok(None) | Err(_) => break,
        }
    }

    let frame = NetprobeFrame {
        sequence: 0,
        payload: Some(netprobe_frame::Payload::FlowAttributionBatch(
            FlowAttributionEventBatch {
                events,
                batch_start_unix_nano,
                batch_end_unix_nano: now_unix_nano(),
                dropped_since_last: 0,
            },
        )),
    };
    write_reused_frame(writer, &frame, encode_buffer, metrics).await
}

async fn write_reused_frame<W>(
    writer: &mut W,
    frame: &NetprobeFrame,
    encode_buffer: &mut Vec<u8>,
    metrics: &Metrics,
) -> Result<(), crate::framing::FramingError>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    if write_frame_with_buffer(writer, frame, encode_buffer).await? {
        metrics.inc_encode_buffer_reuses();
    }
    Ok(())
}

async fn write_process_snapshot_frames<W>(
    writer: &mut W,
    snapshot: ProcessSnapshot,
    encode_buffer: &mut Vec<u8>,
    metrics: &Metrics,
) -> Result<(), crate::framing::FramingError>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    if process_snapshot_frame_len(&snapshot) <= MAX_FRAME_SIZE {
        let frame = process_snapshot_frame(snapshot);
        write_reused_frame(writer, &frame, encode_buffer, metrics).await?;
        return Ok(());
    }

    let ProcessSnapshot {
        fingerprint,
        observed_at_unix_nano,
        entries,
    } = snapshot;

    let base_payload_len = process_snapshot_base_payload_len(&fingerprint, observed_at_unix_nano);
    let mut current_payload_len = base_payload_len;
    let mut current = ProcessSnapshot {
        fingerprint: fingerprint.clone(),
        observed_at_unix_nano,
        entries: Vec::new(),
    };
    let mut chunks = 0u64;
    let mut dropped_entries = 0u64;

    for entry in entries {
        let entry_wire_len = process_snapshot_entry_wire_len(&entry);

        if process_snapshot_frame_len_from_payload_len(current_payload_len + entry_wire_len)
            <= MAX_FRAME_SIZE
        {
            current.entries.push(entry);
            current_payload_len += entry_wire_len;
            continue;
        }

        if !current.entries.is_empty() {
            let frame = process_snapshot_frame(current);
            write_reused_frame(writer, &frame, encode_buffer, metrics).await?;
            chunks += 1;
        }

        current = ProcessSnapshot {
            fingerprint: fingerprint.clone(),
            observed_at_unix_nano,
            entries: Vec::new(),
        };
        current_payload_len = base_payload_len;

        if process_snapshot_frame_len_from_payload_len(base_payload_len + entry_wire_len)
            > MAX_FRAME_SIZE
        {
            dropped_entries += 1;
        } else {
            current.entries.push(entry);
            current_payload_len += entry_wire_len;
        }
    }

    if !current.entries.is_empty() {
        let frame = process_snapshot_frame(current);
        write_reused_frame(writer, &frame, encode_buffer, metrics).await?;
        chunks += 1;
    }

    if dropped_entries > 0 {
        metrics.inc_process_snapshot_events_dropped("oversized_entry", dropped_entries);
        log::warn!("dropped {dropped_entries} oversized process snapshot entrie(s)");
    }

    log::debug!("split oversized process snapshot into {chunks} IPC frame(s)");
    Ok(())
}

/// Write one census snapshot, split across frames when it does not fit.
///
/// Chunking lives in `census::chunk_snapshot` rather than here because the
/// chunk set has to be computed before the first frame goes out (chunk_count is
/// on every chunk), and because that makes it a pure function this module can
/// test without an async socket harness.
async fn write_census_snapshot_frames<W>(
    writer: &mut W,
    snapshot: DeviceCensusSnapshot,
    encode_buffer: &mut Vec<u8>,
    metrics: &Metrics,
) -> Result<(), crate::framing::FramingError>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    let (chunks, dropped) = crate::census::chunk_snapshot(snapshot, census_max_payload_len());
    if dropped > 0 {
        metrics
            .inc_device_census_snapshot_events_dropped("oversized_observation", u64::from(dropped));
        log::warn!("dropped {dropped} oversized census observation(s)");
    }
    let chunk_count = chunks.len();
    for chunk in chunks {
        let frame = NetprobeFrame {
            sequence: 0,
            payload: Some(netprobe_frame::Payload::DeviceCensusSnapshot(chunk)),
        };
        write_reused_frame(writer, &frame, encode_buffer, metrics).await?;
        metrics.inc_device_census_snapshot_events();
    }
    if chunk_count > 1 {
        log::debug!("split census snapshot into {chunk_count} IPC frame(s)");
    }
    Ok(())
}

/// The largest census payload that still fits inside MAX_FRAME_SIZE once the
/// enclosing oneof field (tag 30) and its length prefix are added.
fn census_max_payload_len() -> usize {
    // Reserve the field key plus the widest length delimiter the payload could
    // need. Subtracting a fixed worst case is deliberate: solving for the exact
    // boundary would make the budget depend on the very length being budgeted.
    const ENVELOPE_WORST_CASE: usize = 16;
    MAX_FRAME_SIZE.saturating_sub(ENVELOPE_WORST_CASE)
}

fn process_snapshot_frame(snapshot: ProcessSnapshot) -> NetprobeFrame {
    NetprobeFrame {
        sequence: 0,
        payload: Some(netprobe_frame::Payload::ProcessSnapshot(snapshot)),
    }
}

fn process_snapshot_frame_len(snapshot: &ProcessSnapshot) -> usize {
    process_snapshot_frame_len_from_payload_len(process_snapshot_payload_len(snapshot))
}

fn process_snapshot_frame_len_from_payload_len(payload_len: usize) -> usize {
    length_delimited_field_len(22, payload_len)
}

fn process_snapshot_payload_len(snapshot: &ProcessSnapshot) -> usize {
    let mut len =
        process_snapshot_base_payload_len(&snapshot.fingerprint, snapshot.observed_at_unix_nano);
    for entry in &snapshot.entries {
        len += process_snapshot_entry_wire_len(entry);
    }
    len
}

fn process_snapshot_base_payload_len(fingerprint: &str, observed_at_unix_nano: i64) -> usize {
    let fingerprint_len = if fingerprint.is_empty() {
        0
    } else {
        length_delimited_field_len(1, fingerprint.len())
    };
    let observed_len = if observed_at_unix_nano == 0 {
        0
    } else {
        key_len(2, 0) + varint_len(observed_at_unix_nano as u64)
    };
    fingerprint_len + observed_len
}

fn process_snapshot_entry_wire_len(entry: &ProcessSnapshotEntry) -> usize {
    length_delimited_field_len(3, entry.encoded_len())
}

fn length_delimited_field_len(field_number: u32, payload_len: usize) -> usize {
    key_len(field_number, 2) + prost::length_delimiter_len(payload_len) + payload_len
}

fn key_len(field_number: u32, wire_type: u32) -> usize {
    varint_len(u64::from((field_number << 3) | wire_type))
}

fn varint_len(mut value: u64) -> usize {
    let mut len = 1;
    while value >= 0x80 {
        value >>= 7;
        len += 1;
    }
    len
}

async fn response_for_frame(
    frame: NetprobeFrame,
    runtime_config: &RuntimeConfig,
    external_flows: &SharedExternalFlowMatcher,
    metrics: &Metrics,
    flow_attribution_events: &EventSender<Arc<FlowAttributionEvent>>,
) -> Result<Option<NetprobeFrame>, crate::framing::FramingError> {
    let sequence = frame.sequence;
    match frame.payload {
        Some(netprobe_frame::Payload::Ping(ping)) => Ok(Some(NetprobeFrame {
            sequence,
            payload: Some(netprobe_frame::Payload::PingAck(PingAck {
                sent_at_unix_nano: ping.sent_at_unix_nano,
                acked_at_unix_nano: now_unix_nano(),
                fingerprint_engine_version: FINGERPRINT_ENGINE_VERSION.to_string(),
                running_as_root: capabilities::running_as_root(),
                p0f_corpus_revision: P0F_CORPUS_REVISION.to_string(),
                serviceradar_additions_revision: SERVICERADAR_ADDITIONS_REVISION.to_string(),
                ja4_spec_revision: JA4_BASE_SPEC_REVISION.to_string(),
                muonfp_corpus_revision: MUONFP_CORPUS_REVISION.to_string(),
                recog_corpus_revision: RECOG_CORPUS_REVISION.to_string(),
                satori_corpus_revision: SATORI_CORPUS_REVISION.to_string(),
                serviceradar_recog_additions_revision: SERVICERADAR_RECOG_ADDITIONS_REVISION
                    .to_string(),
                recog_corpus_loaded: true,
            })),
        })),
        Some(netprobe_frame::Payload::ApplyConfig(apply)) => {
            match apply
                .config
                .and_then(|config| runtime_config.apply(config).ok())
            {
                Some(config_hash) => Ok(Some(NetprobeFrame {
                    sequence,
                    payload: Some(netprobe_frame::Payload::ConfigAck(ConfigAck {
                        config_hash,
                    })),
                })),
                None => Ok(Some(NetprobeFrame {
                    sequence,
                    payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
                        code: "invalid_config".to_string(),
                        message: "visibility config is missing or invalid".to_string(),
                    })),
                })),
            }
        }
        Some(netprobe_frame::Payload::BannerBatch(batch)) => Ok(Some(NetprobeFrame {
            sequence,
            payload: Some(netprobe_frame::Payload::BannerMatchBatch(
                match_banner::match_banner_batch(&batch),
            )),
        })),
        Some(netprobe_frame::Payload::ExternalFlowRecord(record)) => {
            external_flows.set_match_window_ms(runtime_config.external_flow_match_window_ms());
            let ack = ingest_external_flow_record(
                record,
                external_flows,
                metrics,
                flow_attribution_events,
            );
            if sequence == 0 {
                Ok(None)
            } else {
                Ok(Some(NetprobeFrame {
                    sequence,
                    payload: Some(netprobe_frame::Payload::ExternalFlowAck(ack)),
                }))
            }
        }
        _ => Ok(Some(NetprobeFrame {
            sequence,
            payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
                code: "unsupported_frame".to_string(),
                message: "frame type is not supported by the Phase 1 skeleton".to_string(),
            })),
        })),
    }
}

fn ingest_external_flow_record(
    record: ExternalFlowRecord,
    external_flows: &SharedExternalFlowMatcher,
    metrics: &Metrics,
    flow_attribution_events: &EventSender<Arc<FlowAttributionEvent>>,
) -> ExternalFlowAck {
    match external_flows.ingest(&record, now_unix_nano()) {
        ExternalFlowIngest::Matched(event) => {
            metrics.inc_flow_attribution_events();
            metrics.inc_external_flow_matched();
            match flow_attribution_events.try_send(Arc::new(event)) {
                Ok(()) => {}
                Err(TrySendError::Full(_)) => {
                    metrics.inc_flow_attribution_events_dropped("queue_full", 1);
                }
                Err(TrySendError::Closed(_)) => {
                    metrics.inc_flow_attribution_events_dropped("no_receiver", 1);
                }
            }
            ExternalFlowAck {
                accepted: 1,
                matched: 1,
                ..Default::default()
            }
        }
        ExternalFlowIngest::Unmatched => {
            metrics.inc_external_flow_unmatched();
            ExternalFlowAck {
                accepted: 1,
                unmatched: 1,
                ..Default::default()
            }
        }
        ExternalFlowIngest::Invalid => {
            metrics.inc_external_flow_invalid();
            ExternalFlowAck {
                invalid: 1,
                ..Default::default()
            }
        }
    }
}

fn now_unix_nano() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use prost::Message;
    use tempfile::TempDir;
    use tokio::{
        io::duplex,
        net::UnixStream,
        sync::{broadcast, watch},
    };

    use super::{
        IpcServer, ingest_external_flow_record, process_snapshot_frame_len,
        write_process_snapshot_frames,
    };
    use crate::external_flow::SharedExternalFlowMatcher;
    use crate::{
        config::Config,
        fingerprint::{
            JA4_BASE_SPEC_REVISION, MUONFP_CORPUS_REVISION, P0F_CORPUS_REVISION,
            RECOG_CORPUS_REVISION, SATORI_CORPUS_REVISION, SERVICERADAR_ADDITIONS_REVISION,
            SERVICERADAR_RECOG_ADDITIONS_REVISION,
        },
        framing::{MAX_FRAME_SIZE, read_frame, write_frame},
        metrics::Metrics,
        proto::netprobe::{
            ApplyConfig, DeviceCensusSnapshot, DpiEvent, ExternalFlowRecord, FingerprintEvent,
            FlowAttributionEvent, NetprobeFrame, Ping, ProcessSnapshot, ProcessSnapshotEntry,
            TcpFingerprint, VisibilityAgentConfig, fingerprint_event, netprobe_frame,
        },
        runtime_config::RuntimeConfig,
    };

    #[tokio::test]
    async fn responds_to_ping() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 1,
                payload: Some(netprobe_frame::Payload::Ping(Ping {
                    sent_at_unix_nano: 99,
                })),
            },
        )
        .await
        .unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 1);
        let Some(netprobe_frame::Payload::PingAck(ack)) = response.payload else {
            panic!("expected ping ack");
        };
        assert_eq!(ack.p0f_corpus_revision, P0F_CORPUS_REVISION);
        assert_eq!(
            ack.serviceradar_additions_revision,
            SERVICERADAR_ADDITIONS_REVISION
        );
        assert_eq!(ack.ja4_spec_revision, JA4_BASE_SPEC_REVISION);
        assert_eq!(ack.muonfp_corpus_revision, MUONFP_CORPUS_REVISION);
        assert_eq!(ack.recog_corpus_revision, RECOG_CORPUS_REVISION);
        assert_eq!(ack.satori_corpus_revision, SATORI_CORPUS_REVISION);
        assert_eq!(
            ack.serviceradar_recog_additions_revision,
            SERVICERADAR_RECOG_ADDITIONS_REVISION
        );
        assert!(ack.recog_corpus_loaded);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn rejects_concurrent_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let _first = UnixStream::connect(&socket).await.unwrap();
        let mut second = UnixStream::connect(&socket).await.unwrap();
        let response = read_frame(&mut second).await.unwrap().unwrap();
        assert!(matches!(
            response.payload,
            Some(netprobe_frame::Payload::Error(_))
        ));

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_fingerprint_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        event_tx.try_send(fingerprint_event()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::FingerprintEvent(event)) = response.payload else {
            panic!("expected fingerprint event");
        };
        assert_eq!(event.ip, "192.0.2.10");
        assert_eq!(event.interface_name, "eth0");

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_dpi_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        dpi_tx.try_send(dpi_event()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::DpiEvent(event)) = response.payload else {
            panic!("expected DPI event");
        };
        assert_eq!(event.protocol, "dns");
        assert_eq!(event.interface_name, "eth0");

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_flow_attribution_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let matcher = test_external_flow_matcher();
        matcher.observe_attribution(&flow_attribution_event());
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx.clone(),
            flow_rx,
            process_tx,
            census_tx,
            matcher,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        flow_tx
            .try_send(Arc::new(flow_attribution_event()))
            .unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let event = first_flow_attribution_event(response);
        assert_eq!(event.local_ip, "192.0.2.10");
        assert_eq!(event.pid, 123);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn batches_flow_attribution_events_when_client_opts_in() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let matcher = SharedExternalFlowMatcher::new(0);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx.clone(),
            flow_rx,
            process_tx,
            census_tx,
            matcher.clone(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 7,
                payload: Some(netprobe_frame::Payload::ApplyConfig(ApplyConfig {
                    config: Some(VisibilityAgentConfig {
                        flow_attribution_ipc_batch: true,
                        ..Default::default()
                    }),
                })),
            },
        )
        .await
        .unwrap();
        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 7);
        assert!(matches!(
            response.payload,
            Some(netprobe_frame::Payload::ConfigAck(_))
        ));

        for pid in [123, 124, 125] {
            let mut event = flow_attribution_event();
            event.pid = pid;
            flow_tx.try_send(Arc::new(event)).unwrap();
        }

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::FlowAttributionBatch(batch)) = response.payload else {
            panic!("expected flow attribution batch");
        };
        let pids = batch
            .events
            .iter()
            .map(|event| event.pid)
            .collect::<Vec<_>>();
        assert_eq!(pids, vec![123, 124, 125]);
        assert!(batch.batch_start_unix_nano <= batch.batch_end_unix_nano);
        assert!(matches!(
            matcher.ingest(&external_flow_record(), 123),
            crate::external_flow::ExternalFlowIngest::Unmatched
        ));

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn ingests_external_flow_record_and_acks_match() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let matcher = test_external_flow_matcher();
        matcher.observe_attribution(&flow_attribution_event());
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx.clone(),
            flow_rx,
            process_tx,
            census_tx,
            matcher,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        flow_tx
            .try_send(Arc::new(flow_attribution_event()))
            .unwrap();

        let local = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(first_flow_attribution_event(local).pid, 123);

        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 9,
                payload: Some(netprobe_frame::Payload::ExternalFlowRecord(
                    external_flow_record(),
                )),
            },
        )
        .await
        .unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 9);
        let Some(netprobe_frame::Payload::ExternalFlowAck(ack)) = response.payload else {
            panic!("expected matched external flow ack");
        };
        assert_eq!(ack.accepted, 1);
        assert_eq!(ack.matched, 1);
        assert_eq!(ack.unmatched, 0);
        assert_eq!(ack.invalid, 0);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn acks_unmatched_external_flow_record_requests() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 99,
                payload: Some(netprobe_frame::Payload::ExternalFlowRecord(
                    external_flow_record(),
                )),
            },
        )
        .await
        .unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 99);
        let Some(netprobe_frame::Payload::ExternalFlowAck(ack)) = response.payload else {
            panic!("expected external flow ack");
        };
        assert_eq!(ack.accepted, 1);
        assert_eq!(ack.matched, 0);
        assert_eq!(ack.unmatched, 1);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    fn census_snapshot() -> DeviceCensusSnapshot {
        DeviceCensusSnapshot {
            observations: vec![crate::proto::netprobe::DeviceCensusObservation {
                mac: "aa:bb:cc:dd:ee:ff".to_owned(),
                ip: "192.168.1.10".to_owned(),
                interface_index: 2,
                kind: crate::proto::netprobe::DeviceCensusKind::ArpReply as i32,
                first_seen_unix_nano: 1,
                last_seen_unix_nano: 2,
                randomized_mac: false,
                off_segment: false,
            }],
            snapshot_id: "eth0-1".to_owned(),
            interface_name: "eth0".to_owned(),
            generated_at_unix_nano: 3,
            complete: true,
            chunk_index: 0,
            chunk_count: 1,
            dropped_since_last: 0,
        }
    }

    #[tokio::test]
    async fn streams_census_snapshots_to_connected_client() {
        // Proves the whole emit path: the new oneof tag encodes, survives the
        // frame writer, and decodes on the client as the right variant. A unit
        // test of chunk_snapshot alone would pass even if the payload were
        // wired to the wrong tag.
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx.clone(),
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&census_tx).await;
        census_tx.send(census_snapshot()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        let Some(netprobe_frame::Payload::DeviceCensusSnapshot(snapshot)) = response.payload else {
            panic!("expected device census snapshot");
        };
        assert_eq!(snapshot.snapshot_id, "eth0-1");
        assert_eq!(snapshot.interface_name, "eth0");
        assert_eq!(snapshot.observations.len(), 1);
        assert_eq!(snapshot.observations[0].mac, "aa:bb:cc:dd:ee:ff");
        // A single-frame snapshot must still declare itself complete, or a
        // receiver that waits for the flag applies nothing at all.
        assert!(snapshot.complete);
        assert_eq!(snapshot.chunk_count, 1);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn streams_process_snapshots_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx.clone(),
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&process_tx).await;
        process_tx.send(process_snapshot()).unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 0);
        let Some(netprobe_frame::Payload::ProcessSnapshot(snapshot)) = response.payload else {
            panic!("expected process snapshot");
        };
        assert_eq!(snapshot.fingerprint, "fp-1");
        assert_eq!(snapshot.entries.len(), 1);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn splits_oversized_process_snapshots_to_fit_ipc_frames() {
        let metrics = Metrics::new().unwrap();
        let large_cmdline = "x".repeat(768 * 1024);
        let entries = (0..10)
            .map(|idx| ProcessSnapshotEntry {
                local_ip: "10.42.221.137".to_string(),
                local_port: 10_000 + (idx % 50),
                transport_protocol: "tcp".to_string(),
                pid: 100_000 + idx,
                tgid: 100_000 + idx,
                uid: 1000,
                gid: 1000,
                comm: "longhorn-instan".to_string(),
                redacted_cmdline: vec![large_cmdline.clone()],
                container_id: format!("{idx:064x}"),
                workload_identity: None,
            })
            .collect::<Vec<_>>();
        let snapshot = ProcessSnapshot {
            fingerprint: "large-snapshot".to_string(),
            observed_at_unix_nano: 42,
            entries,
        };
        assert!(process_snapshot_frame_len(&snapshot) > MAX_FRAME_SIZE);

        let (mut writer, mut reader) = duplex(64 * 1024);
        let writer_task = tokio::spawn(async move {
            let mut buffer = Vec::new();
            write_process_snapshot_frames(&mut writer, snapshot, &mut buffer, &metrics)
                .await
                .unwrap();
        });

        let mut chunks = 0;
        let mut total_entries = 0;
        while let Some(frame) = read_frame(&mut reader).await.unwrap() {
            assert!(frame.encoded_len() <= MAX_FRAME_SIZE);
            let Some(netprobe_frame::Payload::ProcessSnapshot(chunk)) = frame.payload else {
                panic!("expected process snapshot chunk");
            };
            assert_eq!(chunk.fingerprint, "large-snapshot");
            assert_eq!(chunk.observed_at_unix_nano, 42);
            chunks += 1;
            total_entries += chunk.entries.len();
        }

        writer_task.await.unwrap();
        assert!(chunks > 1, "expected oversized snapshot to split");
        assert_eq!(total_entries, 10);
    }

    #[cfg(feature = "remote-capture")]
    #[tokio::test]
    async fn streams_fixture_traffic_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();

        let mut engine = crate::fingerprint::FingerprintEngine::phase1().unwrap();
        for event in engine.analyze_packet("eth0", 789, &tls_server_hello_packet()) {
            event_tx.try_send(event).unwrap();
        }

        let (event, tls) = read_tls_fixture_event(&mut client).await;
        assert_eq!(event.ip, "198.51.100.40");
        assert_eq!(event.interface_name, "eth0");
        assert_eq!(tls.ja4, "");
        assert_eq!(tls.ja4s, "t1302h2_1301_b9a491fefe05");

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn applies_visibility_config() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (_event_tx, event_rx) = crate::event_queue::bounded(16);
        let (_dpi_tx, dpi_rx) = crate::event_queue::bounded(16);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (process_tx, _) = broadcast::channel(16);
        let (census_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            event_rx,
            dpi_rx,
            flow_tx,
            flow_rx,
            process_tx,
            census_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 7,
                payload: Some(netprobe_frame::Payload::ApplyConfig(ApplyConfig {
                    config: Some(VisibilityAgentConfig {
                        enabled: true,
                        default_sample_interval_ms: 1_000,
                        ..Default::default()
                    }),
                })),
            },
        )
        .await
        .unwrap();

        let response = read_frame(&mut client).await.unwrap().unwrap();
        assert_eq!(response.sequence, 7);
        assert!(matches!(
            response.payload,
            Some(netprobe_frame::Payload::ConfigAck(_))
        ));

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    async fn wait_for_socket(socket: &std::path::Path) {
        for _ in 0..50 {
            if socket.exists() {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("socket did not appear");
    }

    fn test_external_flow_matcher() -> SharedExternalFlowMatcher {
        SharedExternalFlowMatcher::new(0)
    }

    async fn wait_for_event_receiver<T: Clone>(event_tx: &broadcast::Sender<T>) {
        for _ in 0..50 {
            if event_tx.receiver_count() > 0 {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("server did not subscribe to fingerprint events");
    }

    #[cfg(feature = "remote-capture")]
    async fn read_tls_fixture_event(
        client: &mut UnixStream,
    ) -> (FingerprintEvent, crate::proto::netprobe::TlsFingerprint) {
        for _ in 0..5 {
            let response =
                tokio::time::timeout(std::time::Duration::from_secs(1), read_frame(client))
                    .await
                    .expect("timed out waiting for fixture event")
                    .unwrap()
                    .unwrap();
            if let Some(netprobe_frame::Payload::FingerprintEvent(event)) = response.payload {
                if let Some(fingerprint_event::Evidence::Tls(tls)) = event.evidence.clone() {
                    return (event, tls);
                }
            }
        }

        panic!("expected TLS fingerprint event");
    }

    // Exercises the deprecated-but-still-supported tcp evidence path.
    #[allow(deprecated)]
    fn fingerprint_event() -> FingerprintEvent {
        FingerprintEvent {
            ip: "192.0.2.10".to_string(),
            profile_id: "profile-1".to_string(),
            interface_name: "eth0".to_string(),
            observed_at_unix_nano: 123,
            evidence: Some(fingerprint_event::Evidence::Tcp(TcpFingerprint {
                signature: "sig".to_string(),
                os_family: "linux".to_string(),
                os_name: "Linux".to_string(),
                confidence: 1.0,
                ..Default::default()
            })),
        }
    }

    fn dpi_event() -> DpiEvent {
        DpiEvent {
            source_ip: "192.0.2.10".to_string(),
            destination_ip: "198.51.100.20".to_string(),
            source_port: 49_152,
            destination_port: 53,
            transport_protocol: "udp".to_string(),
            protocol: "dns".to_string(),
            confidence: 0.95,
            observed_at_unix_nano: 123,
            interface_name: "eth0".to_string(),
            dissector_id: "dns_header".to_string(),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn ingest_external_flow_record_emits_matched_via_queue_and_bumps_counter() {
        let metrics = Metrics::new().unwrap();
        let matcher = SharedExternalFlowMatcher::new(0);
        matcher.observe_attribution(&flow_attribution_event());
        let (event_tx, mut event_rx) = crate::event_queue::bounded(8);

        let ack =
            ingest_external_flow_record(external_flow_record(), &matcher, &metrics, &event_tx);

        assert_eq!(ack.accepted, 1);
        assert_eq!(ack.matched, 1);
        assert_eq!(ack.unmatched, 0);
        assert_eq!(ack.invalid, 0);

        let event = event_rx.try_recv().expect("queued event present");
        assert_eq!(event.source, "external_netflow");
        assert_eq!(event.external_flow_id, 42);

        assert_eq!(
            counter_value(
                &metrics,
                "serviceradar_netprobe_external_flow_matched_total"
            ),
            1
        );
        assert_eq!(
            counter_value(
                &metrics,
                "serviceradar_netprobe_external_flow_unmatched_total"
            ),
            0
        );
        assert_eq!(
            counter_value(
                &metrics,
                "serviceradar_netprobe_external_flow_invalid_total"
            ),
            0
        );
    }

    #[tokio::test]
    async fn ingest_external_flow_record_drops_unmatched_and_bumps_counter() {
        let metrics = Metrics::new().unwrap();
        // Empty matcher — no attribution observed — every well-formed
        // external record reports Unmatched.
        let matcher = SharedExternalFlowMatcher::new(0);
        let (event_tx, mut event_rx) = crate::event_queue::bounded(8);

        let ack =
            ingest_external_flow_record(external_flow_record(), &matcher, &metrics, &event_tx);

        assert_eq!(ack.accepted, 1);
        assert_eq!(ack.unmatched, 1);
        assert_eq!(ack.matched, 0);
        assert!(event_rx.try_recv().is_err());
        assert_eq!(
            counter_value(
                &metrics,
                "serviceradar_netprobe_external_flow_unmatched_total"
            ),
            1
        );
        assert_eq!(
            counter_value(
                &metrics,
                "serviceradar_netprobe_external_flow_matched_total"
            ),
            0
        );
    }

    #[tokio::test]
    async fn ingest_external_flow_record_drops_invalid_and_bumps_counter() {
        let metrics = Metrics::new().unwrap();
        let matcher = SharedExternalFlowMatcher::new(0);
        let (event_tx, mut event_rx) = crate::event_queue::bounded(8);

        // Default record has empty IP buffers, so `flow_key_from_external_record`
        // returns None and the matcher reports Invalid.
        let ack = ingest_external_flow_record(
            ExternalFlowRecord::default(),
            &matcher,
            &metrics,
            &event_tx,
        );

        assert_eq!(ack.invalid, 1);
        assert_eq!(ack.accepted, 0);
        assert!(event_rx.try_recv().is_err());
        assert_eq!(
            counter_value(
                &metrics,
                "serviceradar_netprobe_external_flow_invalid_total"
            ),
            1
        );
        assert_eq!(
            counter_value(
                &metrics,
                "serviceradar_netprobe_external_flow_matched_total"
            ),
            0
        );
    }

    fn counter_value(metrics: &Metrics, name: &str) -> u64 {
        metrics
            .registry()
            .gather()
            .into_iter()
            .find(|family| family.name() == name)
            .and_then(|family| family.get_metric().first().map(|m| m.get_counter().value()))
            .unwrap_or(0.0) as u64
    }

    fn first_flow_attribution_event(frame: NetprobeFrame) -> FlowAttributionEvent {
        match frame.payload {
            Some(netprobe_frame::Payload::FlowAttributionEvent(event)) => event,
            Some(netprobe_frame::Payload::FlowAttributionBatch(batch)) => batch
                .events
                .into_iter()
                .next()
                .expect("expected non-empty flow attribution batch"),
            other => panic!("expected flow attribution event or batch, got {other:?}"),
        }
    }

    fn flow_attribution_event() -> FlowAttributionEvent {
        FlowAttributionEvent {
            local_ip: "192.0.2.10".to_string(),
            local_port: 49_152,
            remote_ip: "198.51.100.20".to_string(),
            remote_port: 443,
            transport_protocol: "tcp".to_string(),
            pid: 123,
            tgid: 123,
            uid: 1000,
            gid: 1000,
            comm: "curl".to_string(),
            redacted_cmdline: vec![
                "/usr/bin/curl".to_string(),
                "[redacted 1 arg(s)]".to_string(),
            ],
            observed_at_unix_nano: 123,
            ..Default::default()
        }
    }

    fn external_flow_record() -> ExternalFlowRecord {
        ExternalFlowRecord {
            external_flow_id: 42,
            source_ip: vec![198, 51, 100, 20],
            destination_ip: vec![192, 0, 2, 10],
            source_port: 443,
            destination_port: 49_152,
            transport_protocol: "tcp".to_string(),
            time_flow_end_ns: 123,
            bytes: 4096,
            packets: 9,
            ..Default::default()
        }
    }

    fn process_snapshot() -> ProcessSnapshot {
        ProcessSnapshot {
            fingerprint: "fp-1".to_string(),
            observed_at_unix_nano: 123,
            entries: vec![crate::proto::netprobe::ProcessSnapshotEntry {
                local_ip: "192.0.2.10".to_string(),
                local_port: 443,
                transport_protocol: "tcp".to_string(),
                pid: 123,
                tgid: 123,
                uid: 1000,
                gid: 1000,
                comm: "nginx".to_string(),
                redacted_cmdline: vec!["/usr/sbin/nginx".to_string()],
                ..Default::default()
            }],
        }
    }

    #[cfg(feature = "remote-capture")]
    fn tls_server_hello_packet() -> Vec<u8> {
        ipv4_tcp_packet(
            [198, 51, 100, 40],
            [192, 0, 2, 22],
            443,
            49_153,
            &tls_server_hello_payload(),
        )
    }

    #[cfg(feature = "remote-capture")]
    fn tls_server_hello_payload() -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]);
        body.extend_from_slice(&[0u8; 32]);
        body.push(0x00);
        body.extend_from_slice(&0x1301u16.to_be_bytes());
        body.push(0x00);

        let mut extensions = Vec::new();
        extensions.extend_from_slice(&0x002bu16.to_be_bytes());
        extensions.extend_from_slice(&2u16.to_be_bytes());
        extensions.extend_from_slice(&0x0304u16.to_be_bytes());
        extensions.extend_from_slice(&0x0010u16.to_be_bytes());
        extensions.extend_from_slice(&5u16.to_be_bytes());
        extensions.extend_from_slice(&3u16.to_be_bytes());
        extensions.push(2);
        extensions.extend_from_slice(b"h2");

        body.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
        body.extend_from_slice(&extensions);

        let body_len = body.len() as u32;
        let mut handshake = vec![
            0x02,
            ((body_len >> 16) & 0xff) as u8,
            ((body_len >> 8) & 0xff) as u8,
            (body_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&body);

        let record_len = handshake.len() as u16;
        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&record_len.to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    #[cfg(feature = "remote-capture")]
    fn ipv4_tcp_packet(
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
        source_port: u16,
        destination_port: u16,
        payload: &[u8],
    ) -> Vec<u8> {
        let total_len = 20 + 20 + payload.len();
        let mut packet = Vec::with_capacity(total_len);
        packet.extend_from_slice(&[
            0x45,
            0x00,
            ((total_len >> 8) & 0xff) as u8,
            (total_len & 0xff) as u8,
            0x12,
            0x34,
            0x40,
            0x00,
            0x40,
            0x06,
            0x00,
            0x00,
        ]);
        packet.extend_from_slice(&source_ip);
        packet.extend_from_slice(&destination_ip);
        packet.extend_from_slice(&source_port.to_be_bytes());
        packet.extend_from_slice(&destination_port.to_be_bytes());
        packet.extend_from_slice(&[0x01, 0x02, 0x03, 0x04]);
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        packet.extend_from_slice(&[0x50, 0x18]);
        packet.extend_from_slice(&0xfa_f0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(payload);
        packet
    }
}
