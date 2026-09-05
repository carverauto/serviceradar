use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use tokio::{
    net::{UnixListener, UnixStream},
    sync::mpsc::error::{TryRecvError, TrySendError},
    sync::{Mutex, broadcast, mpsc, watch},
    time::{Instant, timeout},
};

use crate::{
    capabilities,
    capture::service::{AfPacketActivator, BlockSender, CaptureService, StartedSession},
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
        ConfigAck, DeviceCensusSnapshot, ErrorFrame, ExternalFlowAck, ExternalFlowRecord,
        FlowAttributionEvent, FlowAttributionEventBatch, MdnsSnapshot, NetprobeFrame, PcapngBlock,
        PingAck, StartRemoteCapture, netprobe_frame,
    },
    runtime_config::RuntimeConfig,
};

/// How many encoded pcapng blocks may sit between the capture thread and the
/// socket writer.
///
/// Bounded on purpose, and the backpressure is the point: a slow client makes
/// the capture thread wait, the ring fills, and the kernel's drop counter
/// records it -- which the terminal block reports as an incomplete capture.
/// Dropping blocks instead would corrupt the pcapng stream silently, because a
/// reader has no way to tell that a block is missing from the middle of a file.
const CAPTURE_BLOCK_QUEUE: usize = 64;

const FLOW_ATTRIBUTION_IPC_BATCH_MAX: usize = 256;
// NetFlow correlation is delayed by exporter flush cadence, so sub-second IPC
// latency is acceptable. A wider window turns busy worker attribution bursts
// into fewer Unix socket writes and protobuf encodes without dropping events.
const FLOW_ATTRIBUTION_IPC_BATCH_WAIT: Duration = Duration::from_millis(250);

pub struct IpcServer {
    socket_path: PathBuf,
    active_client: Arc<AtomicBool>,
    flow_attribution_events: EventSender<Arc<FlowAttributionEvent>>,
    flow_attribution_rx: Arc<Mutex<EventReceiver<Arc<FlowAttributionEvent>>>>,
    census_snapshots: broadcast::Sender<DeviceCensusSnapshot>,
    mdns_snapshots: broadcast::Sender<MdnsSnapshot>,
    external_flow_matcher: SharedExternalFlowMatcher,
    runtime_config: RuntimeConfig,
    metrics: Metrics,
    /// `None` when netprobe holds no pre-opened capture descriptors, which is
    /// the normal state with an empty `capture_interfaces`. A capture request
    /// is then refused with a reason naming that, rather than failing deeper
    /// with something an operator has to decode.
    capture: Option<Arc<CaptureService<AfPacketActivator>>>,
}

impl IpcServer {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        socket_path: impl Into<PathBuf>,
        flow_attribution_events: EventSender<Arc<FlowAttributionEvent>>,
        flow_attribution_rx: EventReceiver<Arc<FlowAttributionEvent>>,
        census_snapshots: broadcast::Sender<DeviceCensusSnapshot>,
        mdns_snapshots: broadcast::Sender<MdnsSnapshot>,
        external_flow_matcher: SharedExternalFlowMatcher,
        runtime_config: RuntimeConfig,
        metrics: Metrics,
        capture: Option<Arc<CaptureService<AfPacketActivator>>>,
    ) -> Self {
        Self {
            socket_path: socket_path.into(),
            capture,
            active_client: Arc::new(AtomicBool::new(false)),
            flow_attribution_events,
            flow_attribution_rx: Arc::new(Mutex::new(flow_attribution_rx)),
            census_snapshots,
            mdns_snapshots,
            external_flow_matcher,
            runtime_config,
            metrics,
        }
    }

    pub async fn run(self, mut shutdown: watch::Receiver<bool>) -> Result<()> {
        prepare_socket(&self.socket_path)?;
        let listener = UnixListener::bind(&self.socket_path)
            .with_context(|| format!("failed to bind {}", self.socket_path.display()))?;
        // Applied after bind, because the socket does not exist before it.
        // Until this landed the mode was whatever the umask produced -- 0755
        // under the usual 022, which is connectable by every local account.
        crate::uds::restrict_to_owner(&self.socket_path, "the netprobe IPC socket")?;

        loop {
            tokio::select! {
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        return Ok(());
                    }
                }
                accepted = listener.accept() => {
                    let (stream, _) = accepted?;
                    let peer = crate::uds::peer_credentials(&stream);
                    if self.active_client.swap(true, Ordering::SeqCst) {
                        tokio::spawn(async move {
                            let _ = reject_concurrent_client(stream).await;
                        });
                        continue;
                    }

                    let active_client = Arc::clone(&self.active_client);
                    let flow_attribution_tx = self.flow_attribution_events.clone();
                    let flow_attribution_rx = Arc::clone(&self.flow_attribution_rx);
                    let census_snapshot_rx = self.census_snapshots.subscribe();
                    let mdns_snapshot_rx = self.mdns_snapshots.subscribe();
                    let external_flow_matcher = self.external_flow_matcher.clone();
                    let runtime_config = self.runtime_config.clone();
                    let metrics = self.metrics.clone();
                    let capture = self.capture.clone();
                    match peer {
                        // Evidence, not authorization -- see
                        // `crate::uds::PeerCredentials`. Logged at connect so
                        // the journal on a captured host can say which local
                        // process held the socket, independently of anything
                        // the control plane records.
                        Some(peer) => log::info!("netprobe IPC client connected: {peer}"),
                        None => log::info!(
                            "netprobe IPC client connected: peer credentials unavailable"
                        ),
                    }

                    tokio::spawn(async move {
                        let _guard = ActiveClientGuard(active_client);
                        let result = handle_client(
                            stream,
                            flow_attribution_tx,
                            flow_attribution_rx,
                            census_snapshot_rx,
                            mdns_snapshot_rx,
                            external_flow_matcher,
                            runtime_config,
                            metrics,
                            capture,
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
    flow_attribution_tx: EventSender<Arc<FlowAttributionEvent>>,
    flow_attribution_events: Arc<Mutex<EventReceiver<Arc<FlowAttributionEvent>>>>,
    mut census_snapshots: broadcast::Receiver<DeviceCensusSnapshot>,
    mut mdns_snapshots: broadcast::Receiver<MdnsSnapshot>,
    external_flows: SharedExternalFlowMatcher,
    runtime_config: RuntimeConfig,
    metrics: Metrics,
    capture: Option<Arc<CaptureService<AfPacketActivator>>>,
) -> Result<()> {
    let (mut reader, mut writer) = stream.into_split();
    let mut encode_buffer = Vec::new();

    // Always present, even with no capture service, so the select below has one
    // shape. An idle receiver costs a channel; an `Option` in a `select!` arm
    // costs a guard on every branch and a way to get it wrong.
    let (capture_tx, mut capture_blocks) = mpsc::channel::<PcapngBlock>(CAPTURE_BLOCK_QUEUE);
    // Holding this is what keeps the session alive: dropping it cancels, so a
    // client that disconnects tears the capture down without a separate path
    // that has to remember to.
    let mut active_capture: Option<StartedSession> = None;

    loop {
        tokio::select! {
            frame = read_frame(&mut reader) => {
                let Some(frame) = frame? else {
                    return Ok(());
                };
                if let Some(netprobe_frame::Payload::StartRemoteCapture(request)) = frame.payload {
                    let response = start_capture(
                        capture.as_deref(),
                        &capture_tx,
                        &mut active_capture,
                        frame.sequence,
                        request,
                    );
                    write_reused_frame(&mut writer, &response, &mut encode_buffer, &metrics).await?;
                    continue;
                }
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
            block = capture_blocks.recv() => {
                let Some(block) = block else {
                    // Only reachable if every sender is gone, which cannot
                    // happen while `capture_tx` is alive in this scope.
                    return Ok(());
                };
                let terminal = block.r#final;
                let frame = NetprobeFrame {
                    sequence: 0,
                    payload: Some(netprobe_frame::Payload::PcapngBlock(block)),
                };
                write_reused_frame(&mut writer, &frame, &mut encode_buffer, &metrics).await?;
                if terminal {
                    // Released here rather than left to the client, so the
                    // interface is available again the moment the session ends
                    // instead of when its client happens to disconnect.
                    active_capture = None;
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
            snapshot = mdns_snapshots.recv() => {
                match snapshot {
                    Ok(snapshot) => {
                        write_mdns_snapshot_frames(
                            &mut writer,
                            snapshot,
                            &mut encode_buffer,
                            &metrics,
                        ).await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        // Superseded, not lost: each snapshot completely
                        // replaces the last.
                        log::debug!("netprobe IPC client lagged; skipped {skipped} superseded mdns snapshot(s)");
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

/// Write one mDNS snapshot, split across frames when it does not fit.
///
/// Chunking lives in `mdns::chunk_mdns_snapshot` for the same reason the
/// census's does: chunk_count rides on every chunk, so the set must be computed
/// before the first frame goes out, and keeping it pure makes it testable
/// without an async socket harness.
async fn write_mdns_snapshot_frames<W>(
    writer: &mut W,
    snapshot: MdnsSnapshot,
    encode_buffer: &mut Vec<u8>,
    metrics: &Metrics,
) -> Result<(), crate::framing::FramingError>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    let (chunks, dropped) = crate::mdns::chunk_mdns_snapshot(snapshot, census_max_payload_len());
    if dropped > 0 {
        log::warn!("dropped {dropped} oversized mdns device(s)");
    }
    let chunk_count = chunks.len();
    for chunk in chunks {
        let frame = NetprobeFrame {
            sequence: 0,
            payload: Some(netprobe_frame::Payload::MdnsSnapshot(chunk)),
        };
        write_reused_frame(writer, &frame, encode_buffer, metrics).await?;
    }
    if chunk_count > 1 {
        log::debug!("split mdns snapshot into {chunk_count} IPC frame(s)");
    }
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

/// Start a capture, or say why not.
///
/// Returns the frame to send back: the pcapng header carried on the request's
/// own sequence number, so a client learns its request succeeded and gets the
/// section header in one round trip, or an `ErrorFrame` with a stable code.
/// Every subsequent block is unsolicited, at sequence 0.
fn start_capture(
    capture: Option<&CaptureService<AfPacketActivator>>,
    blocks: &mpsc::Sender<PcapngBlock>,
    active: &mut Option<StartedSession>,
    sequence: u64,
    request: StartRemoteCapture,
) -> NetprobeFrame {
    let Some(service) = capture else {
        return capture_error_frame(
            sequence,
            "capture_unavailable",
            "this netprobe holds no pre-opened capture descriptors; set capture_interfaces and restart it".to_string(),
        );
    };

    // Checked here as well as in the service because this client already has a
    // session: the service's own cap would refuse it, but with a message about
    // some other session rather than about the one the client is already
    // running.
    if let Some(running) = active.as_ref() {
        return capture_error_frame(
            sequence,
            "capture_session_active",
            format!(
                "this connection is already running capture session {}; one session at a time",
                running.session_id
            ),
        );
    }

    match service.start(&request, CaptureBlockSink(blocks.clone())) {
        Ok(started) => {
            let header = PcapngBlock {
                session_id: started.session_id.clone(),
                bytes: started.header.bytes.clone(),
                ..Default::default()
            };
            *active = Some(started);
            NetprobeFrame {
                sequence,
                payload: Some(netprobe_frame::Payload::PcapngBlock(header)),
            }
        }
        Err(err) => {
            // Logged on the host as well as answered on the wire (design.md
            // D8.6): a refusal is exactly the event an operator wants to see
            // when someone is probing what this netprobe will capture.
            log::warn!("capture session {} refused: {err:#}", request.session_id);
            capture_error_frame(sequence, err.code(), format!("{err}"))
        }
    }
}

fn capture_error_frame(sequence: u64, code: &str, message: String) -> NetprobeFrame {
    NetprobeFrame {
        sequence,
        payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
            code: code.to_string(),
            message,
        })),
    }
}

/// Carries encoded blocks from the capture thread to this client's writer.
///
/// `blocking_send` rather than `try_send`: the capture thread is a plain OS
/// thread, so blocking it is safe, and blocking is the correct response to a
/// slow client. Dropping a block instead would leave a hole in the middle of a
/// pcapng file that no reader can detect.
struct CaptureBlockSink(mpsc::Sender<PcapngBlock>);

impl BlockSender for CaptureBlockSink {
    fn send(&mut self, block: PcapngBlock) -> bool {
        self.0.blocking_send(block).is_ok()
    }
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
            // The apply error is KEPT rather than discarded with `.ok()`.
            //
            // It used to collapse every failure into "visibility config is
            // missing or invalid" with no log line -- so a refusal that says
            // exactly which field needs a restart reached neither the operator
            // nor any telemetry, and there was no way to tell a malformed config
            // from a legitimate one this process cannot become.
            let result = match apply.config {
                None => Err(anyhow::anyhow!("visibility config is missing")),
                Some(config) => runtime_config.apply(config),
            };

            match result {
                Ok(config_hash) => Ok(Some(NetprobeFrame {
                    sequence,
                    payload: Some(netprobe_frame::Payload::ConfigAck(ConfigAck {
                        config_hash,
                    })),
                })),
                Err(err) => {
                    log::warn!("rejected ApplyConfig: {err:#}");

                    Ok(Some(NetprobeFrame {
                        sequence,
                        payload: Some(netprobe_frame::Payload::Error(ErrorFrame {
                            code: "invalid_config".to_string(),
                            message: format!("{err:#}"),
                        })),
                    }))
                }
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

    use tempfile::TempDir;
    use tokio::{
        net::UnixStream,
        sync::{broadcast, watch},
    };

    use super::{
        AfPacketActivator, CaptureService, ErrorFrame, IpcServer, StartRemoteCapture,
        ingest_external_flow_record,
    };
    use crate::external_flow::SharedExternalFlowMatcher;
    use crate::{
        config::Config,
        fingerprint::{
            JA4_BASE_SPEC_REVISION, MUONFP_CORPUS_REVISION, P0F_CORPUS_REVISION,
            RECOG_CORPUS_REVISION, SATORI_CORPUS_REVISION, SERVICERADAR_ADDITIONS_REVISION,
            SERVICERADAR_RECOG_ADDITIONS_REVISION,
        },
        framing::{read_frame, write_frame},
        metrics::Metrics,
        proto::netprobe::{
            ApplyConfig, DeviceCensusSnapshot, ExternalFlowRecord, FlowAttributionEvent,
            MdnsSnapshot, NetprobeFrame, Ping, VisibilityAgentConfig, netprobe_frame,
        },
        runtime_config::RuntimeConfig,
    };

    #[tokio::test]
    async fn responds_to_ping() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx,
            mdns_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx,
            mdns_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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
    async fn streams_flow_attribution_events_to_connected_client() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let matcher = test_external_flow_matcher();
        matcher.observe_attribution(&flow_attribution_event());
        let server = IpcServer::new(
            &socket,
            flow_tx.clone(),
            flow_rx,
            census_tx,
            mdns_tx,
            matcher,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let matcher = SharedExternalFlowMatcher::new(0);
        let server = IpcServer::new(
            &socket,
            flow_tx.clone(),
            flow_rx,
            census_tx,
            mdns_tx,
            matcher.clone(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let matcher = test_external_flow_matcher();
        matcher.observe_attribution(&flow_attribution_event());
        let server = IpcServer::new(
            &socket,
            flow_tx.clone(),
            flow_rx,
            census_tx,
            mdns_tx,
            matcher,
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx,
            mdns_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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

    #[tokio::test]
    async fn streams_mdns_snapshots_to_connected_client() {
        // Proves the wiring: the payload encodes on the new oneof tag, survives
        // the frame writer, and decodes on the client as the right variant. The
        // chunking unit tests would all pass even if this were wired to the
        // wrong tag or never dispatched.
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx,
            mdns_tx.clone(),
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
        );
        let task = tokio::spawn(server.run(shutdown_rx));

        wait_for_socket(&socket).await;
        let mut client = UnixStream::connect(&socket).await.unwrap();
        wait_for_event_receiver(&mdns_tx).await;
        mdns_tx.send(mdns_snapshot()).unwrap();

        // Bounded on purpose. Without a timeout, a missing dispatch arm makes
        // this block forever instead of failing, and a hanging test in CI is
        // worse than a failing one -- it burns a runner slot and reports
        // nothing. Verified: deleting the mdns select arm makes this fail here
        // rather than hang.
        let response =
            tokio::time::timeout(std::time::Duration::from_secs(10), read_frame(&mut client))
                .await
                .expect("timed out waiting for an mdns frame; is the select arm wired?")
                .unwrap()
                .unwrap();
        let Some(netprobe_frame::Payload::MdnsSnapshot(snapshot)) = response.payload else {
            panic!("expected mdns snapshot");
        };
        assert_eq!(snapshot.snapshot_id, "eth0-1");
        assert!(
            snapshot.complete,
            "a single-frame snapshot must declare itself complete"
        );
        assert_eq!(snapshot.devices.len(), 1);
        assert_eq!(snapshot.devices[0].models, vec!["B620AP"]);
        // The distinction the wire format exists to preserve.
        assert!(snapshot.devices[0].txt[0].has_value);

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    fn mdns_snapshot() -> MdnsSnapshot {
        MdnsSnapshot {
            devices: vec![crate::proto::netprobe::MdnsDevice {
                mac: "48:e1:5c:a8:2b:58".to_owned(),
                ip: String::new(),
                interface_index: 2,
                service_types: vec!["_airplay._tcp".to_owned()],
                txt: vec![crate::proto::netprobe::MdnsTxtPair {
                    key: "model".to_owned(),
                    value: "B620AP".to_owned(),
                    has_value: true,
                }],
                models: vec!["B620AP".to_owned()],
                ambiguous_model: false,
                first_seen_unix_nano: 1,
                last_seen_unix_nano: 2,
                truncated: false,
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
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx.clone(),
            mdns_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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
    async fn applies_visibility_config() {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx,
            mdns_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
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

    /// The legacy IPC socket carries capture control, so its mode is the whole
    /// local access control on it -- and until this test existed it was
    /// whatever the umask happened to be.
    ///
    /// Pinned rather than trusted: a socket left at the default 0755 is
    /// connectable by every local account, and nothing about that is visible
    /// at runtime. `addon_service.rs` already pins its own socket this way and
    /// its comment names this one as the gap.
    #[tokio::test]
    async fn the_ipc_socket_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx,
            mdns_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            None,
        );
        let task = tokio::spawn(server.run(shutdown_rx));
        wait_for_socket(&socket).await;

        let mode = std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "the IPC socket must not be reachable by other local accounts"
        );

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
    }

    /// A capture service holding no descriptors.
    ///
    /// Buildable anywhere, including hosts with no AF_PACKET, because an empty
    /// allowlist opens nothing. That is enough to exercise every refusal that
    /// happens before a descriptor is touched -- which is all of them that an
    /// operator can trigger by sending a bad request.
    fn empty_capture_service() -> Arc<CaptureService<AfPacketActivator>> {
        let handles = crate::capture::open_allowlisted_interfaces(
            &Config::default(),
            &crate::capture::AfPacketOpener,
        )
        .expect("an empty allowlist opens no sockets");
        Arc::new(CaptureService::new(
            Arc::new(std::sync::Mutex::new(handles)),
            AfPacketActivator::default(),
        ))
    }

    fn capture_request() -> StartRemoteCapture {
        StartRemoteCapture {
            session_id: "01JQ0000000000000000000000".to_string(),
            actor: "operator@example.com".to_string(),
            interfaces: vec!["eth0".to_string()],
            filter: Some(
                crate::proto::netprobe::start_remote_capture::Filter::FilterExpression(
                    "tcp port 22".to_string(),
                ),
            ),
            ..Default::default()
        }
    }

    /// Drives one `StartRemoteCapture` over a real socket and returns the reply.
    async fn capture_reply(
        capture: Option<Arc<CaptureService<AfPacketActivator>>>,
        request: StartRemoteCapture,
    ) -> NetprobeFrame {
        let dir = TempDir::new().unwrap();
        let socket = dir.path().join("ipc.sock");
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (flow_tx, flow_rx) = crate::event_queue::bounded(16);
        let (census_tx, _) = broadcast::channel(16);
        let (mdns_tx, _) = broadcast::channel(16);
        let server = IpcServer::new(
            &socket,
            flow_tx,
            flow_rx,
            census_tx,
            mdns_tx,
            test_external_flow_matcher(),
            RuntimeConfig::new(&Config::default()),
            Metrics::new().unwrap(),
            capture,
        );
        let task = tokio::spawn(server.run(shutdown_rx));
        wait_for_socket(&socket).await;

        let mut client = UnixStream::connect(&socket).await.unwrap();
        write_frame(
            &mut client,
            &NetprobeFrame {
                sequence: 77,
                payload: Some(netprobe_frame::Payload::StartRemoteCapture(request)),
            },
        )
        .await
        .unwrap();
        let response = read_frame(&mut client).await.unwrap().unwrap();

        shutdown_tx.send(true).unwrap();
        task.await.unwrap().unwrap();
        response
    }

    fn expect_capture_error(frame: &NetprobeFrame) -> &ErrorFrame {
        match frame.payload.as_ref() {
            Some(netprobe_frame::Payload::Error(err)) => err,
            other => panic!("expected an ErrorFrame, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_capture_request_is_answered_rather_than_dropped() {
        // The arm exists in the proto but nothing routed it until now. A frame
        // that reaches no handler produces no reply at all, and a client
        // waiting on one hangs instead of failing.
        let response = capture_reply(Some(empty_capture_service()), capture_request()).await;
        assert_eq!(
            response.sequence, 77,
            "the reply carries the request's sequence so a client can correlate it"
        );
        expect_capture_error(&response);
    }

    #[tokio::test]
    async fn a_capture_on_an_interface_that_is_not_allowlisted_is_refused() {
        let response = capture_reply(Some(empty_capture_service()), capture_request()).await;
        let error = expect_capture_error(&response);
        assert_eq!(error.code, "capture_interface_denied");
        assert!(
            error.message.contains("eth0"),
            "the refusal names the interface: {}",
            error.message
        );
    }

    #[tokio::test]
    async fn an_unattributed_capture_request_is_refused_over_ipc() {
        // design.md D8.7. Checked before the interface, so a request that
        // bypassed the control plane is refused for that reason rather than
        // for whatever else is also wrong with it.
        let mut request = capture_request();
        request.session_id = String::new();
        let response = capture_reply(Some(empty_capture_service()), request).await;
        assert_eq!(expect_capture_error(&response).code, "capture_unattributed");
    }

    #[tokio::test]
    async fn a_netprobe_with_no_capture_descriptors_says_so() {
        // The common misconfiguration: `capture_interfaces` was never set, so
        // nothing was opened during the privileged phase. Without this the
        // failure surfaces as an allowlist denial, which sends an operator to
        // edit a list that is not the problem.
        let response = capture_reply(None, capture_request()).await;
        let error = expect_capture_error(&response);
        assert_eq!(error.code, "capture_unavailable");
        assert!(
            error.message.contains("restart"),
            "the message must say a restart is needed, since descriptors open only while privileged: {}",
            error.message
        );
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

    // Exercises the deprecated-but-still-supported tcp evidence path.
    #[allow(deprecated)]
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
}
