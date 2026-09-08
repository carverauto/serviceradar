//! netprobe served over the generic `AddonService` contract.
//!
//! This is the same gRPC contract every other native add-on speaks, on a second
//! Unix socket bound after `--drop-user`. The legacy `NetprobeFrame` IPC socket
//! is untouched: nothing cuts over until the agent is confirmed to consume this
//! one.
//!
//! ## Why a second socket instead of go-plugin
//!
//! go-plugin is a LAUNCH protocol -- the host starts the plugin and reads a
//! handshake line from its stdout to learn the socket path and the certificate
//! to pin. netprobe is started by systemd as root (it needs `CAP_BPF` and
//! friends to create eBPF maps, and running it as the agent's uid was tried and
//! reverted in 8bea8cac0b), so there is no stdout for the agent to read and no
//! launch for it to perform. The agent dials this socket instead.
//!
//! ## Why the payloads are opaque
//!
//! Census and mDNS snapshots ride as `DiscoveryEnvelope` payloads under one
//! telemetry payload kind, with the shape named by a `schema` STRING. The agent
//! forwards the bytes without decoding them, so adding an observation type here
//! costs one registry entry in the control plane and no agent change at all.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use addon_sdk::{
    Addon, CommandRequest, CommandResult, ConfigureResult, Health, HealthStatus, Info,
    TelemetryStream, discovery_pb, discovery_record, pb, serve_on_listener,
};
use anyhow::{Context, Result};
use async_trait::async_trait;
use prost::Message as _;
use tokio::net::UnixListener;
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::{Stream, StreamExt};

use crate::addon_config_json::AddonConfigJson;
use crate::banner_command;
use crate::capabilities;
use crate::fingerprint::{
    FINGERPRINT_ENGINE_VERSION, JA4_BASE_SPEC_REVISION, MUONFP_CORPUS_REVISION,
    P0F_CORPUS_REVISION, RECOG_CORPUS_REVISION, SATORI_CORPUS_REVISION,
    SERVICERADAR_ADDITIONS_REVISION, SERVICERADAR_RECOG_ADDITIONS_REVISION,
};
use crate::proto::netprobe::{
    DeviceCensusSnapshot, DpiEvent, DpiEventBatch, FingerprintEvent, FingerprintEventBatch,
    MdnsSnapshot, ProcessSnapshot, ProcessSnapshotBatch, VisibilityAgentConfig,
};
use crate::runtime_config::RuntimeConfig;

/// Schema names the control plane registers decoders and identity policy
/// against. Changing one of these strings is a contract break, not a rename:
/// an unregistered schema is dropped, loudly, rather than guessed at.
pub const CENSUS_SCHEMA: &str = "serviceradar.netprobe.census.v1";
pub const MDNS_SCHEMA: &str = "serviceradar.netprobe.mdns.v1";
pub const PROCESS_SCHEMA: &str = "serviceradar.netprobe.process.v1";
pub const FINGERPRINT_SCHEMA: &str = "serviceradar.netprobe.fingerprint.v1";
pub const DPI_SCHEMA: &str = "serviceradar.netprobe.dpi.v1";

const ADDON_ID: &str = "netprobe";

/// Batch caps for the event schemas. The size cap keeps a batch far below the Go
/// gRPC client's default 4 MiB receive limit -- which kills the WHOLE stream, not
/// one batch -- and the flush interval bounds the envelope rate when traffic is
/// heavy. Whichever comes first wins.
const MAX_EVENTS_PER_BATCH: usize = 512;
const EVENT_BATCH_FLUSH: std::time::Duration = std::time::Duration::from_secs(2);

/// The values netprobe actually booted with.
///
/// Needed because two fields can only take effect at startup, and the check has
/// to compare against what this PROCESS is running -- not against the last
/// config it was handed. `RuntimeConfig` already holds them for its own bail,
/// but it holds them privately and only compares; classifying the change needs
/// the values themselves so the refusal can say which field moved.
#[derive(Clone, Debug, Default)]
pub struct StartupSnapshot {
    pub capture_interfaces: Vec<String>,
    pub flow_table_max_entries: u32,
}

/// The five broadcast channels netprobe publishes telemetry on.
///
/// Grouped because they are one thing -- "where netprobe's telemetry comes from"
/// -- and passing them as five positional senders made every call site a place to
/// transpose two of the same type.
#[derive(Clone)]
pub struct TelemetryChannels {
    pub census: broadcast::Sender<DeviceCensusSnapshot>,
    pub mdns: broadcast::Sender<MdnsSnapshot>,
    pub process: broadcast::Sender<ProcessSnapshot>,
    pub fingerprint: broadcast::Sender<FingerprintEvent>,
    pub dpi: broadcast::Sender<DpiEvent>,
}

/// netprobe's `AddonService` implementation.
#[derive(Clone)]
pub struct NetprobeAddon {
    version: String,
    channels: TelemetryChannels,
    runtime_config: RuntimeConfig,
    startup: StartupSnapshot,
}

impl NetprobeAddon {
    pub fn new(
        version: impl Into<String>,
        channels: TelemetryChannels,
        runtime_config: RuntimeConfig,
        startup: StartupSnapshot,
    ) -> Self {
        Self {
            version: version.into(),
            channels,
            runtime_config,
            startup,
        }
    }
}

#[async_trait]
impl Addon for NetprobeAddon {
    async fn info(&self) -> Result<Info> {
        Ok(Info {
            id: ADDON_ID.to_owned(),
            version: self.version.clone(),
            capabilities: vec![addon_sdk::CAPABILITY_NATIVE_TELEMETRY_V1.to_owned()],
        })
    }

    async fn configure(&self, config_json: &[u8]) -> Result<ConfigureResult> {
        // Every refusal below returns Ok with accepted:false rather than Err.
        // An Err becomes a transport-level gRPC failure the agent retries; a
        // rejected config is a durable answer that retrying cannot improve, and
        // the reason has to reach the operator rather than a retry loop.
        let parsed: AddonConfigJson = match serde_json::from_slice(config_json) {
            Ok(parsed) => parsed,
            Err(err) => return Ok(rejected(format!("could not parse config json: {err}"))),
        };

        let config: VisibilityAgentConfig = parsed.into();

        if let Some(reason) = self.restart_required(&config) {
            // The config is VALID; this process just cannot become it. Reported
            // as not-accepted because nothing was applied -- claiming otherwise
            // would tell the control plane a setting took effect when the
            // running collector still has the old one.
            return Ok(rejected(reason));
        }

        match self.runtime_config.apply(config) {
            // Carry the whole error chain: RuntimeConfig::apply adds context
            // ("invalid capture interface allowlist") over the specific cause,
            // and only the pair identifies which field an operator got wrong.
            Err(err) => Ok(rejected(format!("{err:#}"))),
            Ok(config_hash) => Ok(ConfigureResult {
                config_hash,
                accepted: true,
                error: String::new(),
            }),
        }
    }

    async fn health(&self) -> Result<Health> {
        // The structured half of what PingAck reports today, read from the SAME
        // sources rather than snapshotted at construction: running_as_root is
        // evaluated per request there too, and privileges are dropped after
        // startup, so a value captured earlier would report the wrong thing.
        //
        // The agent turns these into the sweep banner-grab capability status,
        // so they have to survive the transport change or that capability
        // silently goes dark.
        let details = BTreeMap::from([
            (
                "running_as_root".to_owned(),
                capabilities::running_as_root().to_string(),
            ),
            (
                "fingerprint_engine_version".to_owned(),
                FINGERPRINT_ENGINE_VERSION.to_owned(),
            ),
            (
                "corpus_revision.p0f".to_owned(),
                P0F_CORPUS_REVISION.to_owned(),
            ),
            (
                "corpus_revision.ja4".to_owned(),
                JA4_BASE_SPEC_REVISION.to_owned(),
            ),
            (
                "corpus_revision.muonfp".to_owned(),
                MUONFP_CORPUS_REVISION.to_owned(),
            ),
            (
                "corpus_revision.recog".to_owned(),
                RECOG_CORPUS_REVISION.to_owned(),
            ),
            (
                "corpus_revision.satori".to_owned(),
                SATORI_CORPUS_REVISION.to_owned(),
            ),
            (
                "corpus_revision.serviceradar_additions".to_owned(),
                SERVICERADAR_ADDITIONS_REVISION.to_owned(),
            ),
            (
                "corpus_revision.serviceradar_recog_additions".to_owned(),
                SERVICERADAR_RECOG_ADDITIONS_REVISION.to_owned(),
            ),
        ]);

        Ok(Health {
            status: HealthStatus::Healthy,
            version: self.version.clone(),
            degradation_reason: String::new(),
            details,
        })
    }

    /// Corpus matching for the agent's ACTIVE sweep banner grabs.
    ///
    /// This is the generic-contract replacement for the `NetprobeFrame.BannerBatch`
    /// IPC arm -- the last functional request/response arm on the legacy socket, so
    /// this method is what lets that socket be retired.
    ///
    /// Unlike every other RPC here the agent is the DATA PRODUCER: it opens the TCP
    /// connections and reads the banners itself, and calls netprobe only for the
    /// corpora. The results are the agent's observations, not netprobe's, which is
    /// why they go back in the response rather than out on the telemetry stream.
    ///
    /// An unusable request is an unsuccessful result, never an `Err`: `Err` becomes
    /// a gRPC transport failure the agent retries, and a payload that does not parse
    /// will not parse the second time either.
    async fn run_command(&self, request: CommandRequest) -> Result<CommandResult> {
        if request.action_id != banner_command::MATCH_BANNERS_ACTION {
            return Ok(refused(format!(
                "unsupported action_id {:?}",
                request.action_id
            )));
        }

        // Checked rather than ignored: the schema names the payload shape, and a
        // caller sending a different one is asking for a contract this build does
        // not implement. Guessing would decode it as v1 and answer confidently.
        if request.schema != banner_command::MATCH_BANNERS_SCHEMA {
            return Ok(refused(format!(
                "unsupported schema {:?} for action {:?}",
                request.schema, request.action_id
            )));
        }

        match banner_command::handle_match_banners(&request.payload_json) {
            Ok(payload_json) => Ok(CommandResult {
                success: true,
                message: String::new(),
                payload_json,
                metadata: Default::default(),
            }),
            Err(message) => Ok(refused(message)),
        }
    }

    fn stream_telemetry(&self) -> TelemetryStream {
        let census = snapshot_stream(
            self.channels.census.subscribe(),
            CENSUS_SCHEMA,
            |snapshot: &DeviceCensusSnapshot| {
                (
                    snapshot.interface_name.clone(),
                    snapshot.snapshot_id.clone(),
                    snapshot.generated_at_unix_nano,
                    snapshot.encode_to_vec(),
                )
            },
        );

        let mdns = snapshot_stream(
            self.channels.mdns.subscribe(),
            MDNS_SCHEMA,
            |snapshot: &MdnsSnapshot| {
                (
                    snapshot.interface_name.clone(),
                    snapshot.snapshot_id.clone(),
                    snapshot.generated_at_unix_nano,
                    snapshot.encode_to_vec(),
                )
            },
        );

        // Events are BATCHED on a wall-clock cadence, unlike the snapshot schemas
        // which emit one envelope per snapshot. A fingerprint fires per SYN, and
        // there is no backpressure anywhere downstream -- the agent's sink is a
        // non-blocking drop-newest channel -- so one envelope per event would be
        // discarded at the agent rather than slowed at the producer. Bounding the
        // envelope rate by cadence keeps the volume a function of time, not of
        // traffic.
        let fingerprint = event_batch_stream(
            self.channels.fingerprint.subscribe(),
            FINGERPRINT_SCHEMA,
            |events: Vec<FingerprintEvent>| {
                let generated_at = events
                    .last()
                    .map(|event| event.observed_at_unix_nano)
                    .unwrap_or_default();

                (
                    generated_at,
                    FingerprintEventBatch {
                        events,
                        batch_end_unix_nano: generated_at,
                        ..Default::default()
                    }
                    .encode_to_vec(),
                )
            },
        );

        let dpi_collector_ip = self.runtime_config.collector_ip();
        let dpi = event_batch_stream(
            self.channels.dpi.subscribe(),
            DPI_SCHEMA,
            move |events: Vec<DpiEvent>| {
                let generated_at = events
                    .last()
                    .map(|event| event.observed_at_unix_nano)
                    .unwrap_or_default();
                let subject_ips = events
                    .iter()
                    .map(|event| dpi_subject_ip(event, &dpi_collector_ip))
                    .collect();

                (
                    generated_at,
                    DpiEventBatch {
                        events,
                        batch_end_unix_nano: generated_at,
                        subject_ips,
                        ..Default::default()
                    }
                    .encode_to_vec(),
                )
            },
        );

        // Resolved ONCE per stream: it can only change on a config apply, and
        // re-reading the lock per snapshot would buy nothing.
        let collector_ip = self.runtime_config.collector_ip();

        if collector_ip.is_empty() {
            // No subject, so the schema is not served at all -- rather than
            // served with an empty one. Core would have to guess which device a
            // process listing describes, and guessing wrong attaches a host's
            // processes to someone else's device. The agent stamps the address
            // (VisibilityAgentConfig.collector_ip); until it does, this is the
            // honest state.
            log::warn!(
                "{PROCESS_SCHEMA}: not served -- no collector_ip has been supplied, \
                 so a process listing cannot name the host it describes"
            );

            return Box::pin(census.merge(mdns).merge(fingerprint).merge(dpi));
        }

        let process = snapshot_stream(
            self.channels.process.subscribe(),
            PROCESS_SCHEMA,
            move |snapshot: &ProcessSnapshot| {
                (
                    // Scope IS set here, unlike the event schemas: a process
                    // listing completely replaces the host's previous one, so it
                    // SHOULD supersede by watermark, and there is exactly one
                    // listing per host.
                    collector_ip.clone(),
                    snapshot.fingerprint.clone(),
                    snapshot.observed_at_unix_nano,
                    ProcessSnapshotBatch {
                        snapshot: Some(snapshot.clone()),
                        // Carried IN the payload: a decoder is handed payload
                        // bytes and nothing else.
                        subject_ip: collector_ip.clone(),
                    }
                    .encode_to_vec(),
                )
            },
        );

        Box::pin(
            census
                .merge(mdns)
                .merge(process)
                .merge(fingerprint)
                .merge(dpi),
        )
    }
}

impl NetprobeAddon {
    /// Which startup-only field the requested config would change, if any.
    ///
    /// `capture_interfaces` decides which NICs eBPF programs were attached to,
    /// and `flow_table_max_entries` sizes an eBPF map at load time. Neither can
    /// move in a running process, so `RuntimeConfig::apply` bails on them --
    /// this classifies the same two first so the refusal can name the field
    /// rather than surfacing apply's generic message.
    fn restart_required(&self, config: &VisibilityAgentConfig) -> Option<String> {
        let requested: Vec<&str> = config
            .capture_interfaces
            .iter()
            .map(String::as_str)
            .collect();
        let running: Vec<&str> = self
            .startup
            .capture_interfaces
            .iter()
            .map(String::as_str)
            .collect();

        if requested != running {
            return Some(format!(
                "capture_interfaces requires a netprobe restart: running with [{}], requested [{}]",
                running.join(", "),
                requested.join(", ")
            ));
        }

        if config.flow_table_max_entries != 0
            && config.flow_table_max_entries != self.startup.flow_table_max_entries
        {
            return Some(format!(
                "flow_table_max_entries requires a netprobe restart: running with {}, requested {}",
                self.startup.flow_table_max_entries, config.flow_table_max_entries
            ));
        }

        None
    }
}

fn rejected(error: impl Into<String>) -> ConfigureResult {
    ConfigureResult {
        config_hash: String::new(),
        accepted: false,
        error: error.into(),
    }
}

/// A command this build cannot carry out, reported as a result rather than an
/// error. The distinction matters at this seam: an `Err` surfaces as a gRPC
/// status the agent treats as a transport fault and retries, while an
/// unsuccessful result is a durable answer that reaches the caller intact.
fn refused(message: impl Into<String>) -> CommandResult {
    CommandResult {
        success: false,
        message: message.into(),
        payload_json: Vec::new(),
        metadata: Default::default(),
    }
}

/// Wraps one broadcast of snapshots as a stream of single-record telemetry
/// batches.
///
/// A lagged receiver is NOT an error here. Each snapshot completely supersedes
/// the last, so falling behind means the older views are worth skipping -- and
/// the count of skipped ones is reported as `dropped_since_last` so a quiet
/// segment and a saturated producer stay distinguishable.
/// The device a DPI event describes.
///
/// The collector's own address wins when it is EITHER endpoint, then source,
/// then destination -- the rule the agent's Go translator applied, reproduced
/// here because it is the only side that knows the collector's address. Core can
/// only prefer source, which is why this choice cannot be deferred to it.
fn dpi_subject_ip(event: &DpiEvent, collector_ip: &str) -> String {
    let source = event.source_ip.trim();
    let destination = event.destination_ip.trim();
    let collector = collector_ip.trim();

    if !collector.is_empty() && (collector == source || collector == destination) {
        return collector.to_owned();
    }
    if !source.is_empty() {
        return source.to_owned();
    }

    destination.to_owned()
}

/// One envelope per BATCH of events, on a wall-clock cadence.
///
/// `snapshot_stream` emits one envelope per item, which is right for a snapshot
/// and wrong for an event: a fingerprint fires per SYN. See the call site for why
/// the rate has to be bounded by time rather than by traffic.
///
/// The envelope is framed as a single complete part with an EMPTY
/// `observation_scope`, which is what opts a payload out of supersession
/// (`buffer.ex:161`). Events are independent; a scope would make each batch
/// supersede the one before it by watermark and drop everything but the newest.
fn event_batch_stream<T, F>(
    receiver: broadcast::Receiver<T>,
    schema: &'static str,
    encode: F,
) -> impl Stream<Item = Result<pb::TelemetryBatch, tonic::Status>> + Send + 'static
where
    T: Clone + Send + 'static,
    F: Fn(Vec<T>) -> (i64, Vec<u8>) + Send + 'static,
{
    BroadcastStream::new(receiver)
        .filter_map(move |item| match item {
            Ok(event) => Some(event),
            Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(skipped)) => {
                log::debug!("{schema}: dropped {skipped} event(s) before they could be batched");
                None
            }
        })
        .chunks_timeout(MAX_EVENTS_PER_BATCH, EVENT_BATCH_FLUSH)
        .filter_map(move |events| {
            if events.is_empty() {
                return None;
            }

            let (generated_at, payload) = encode(events);

            Some(Ok(batch_for(
                schema,
                // Empty scope: opts out of supersession. See the doc comment.
                String::new(),
                String::new(),
                generated_at,
                payload,
                0,
            )))
        })
}

fn snapshot_stream<T, F>(
    receiver: broadcast::Receiver<T>,
    schema: &'static str,
    extract: F,
) -> impl Stream<Item = Result<pb::TelemetryBatch, tonic::Status>> + Send + 'static
where
    T: Clone + Send + 'static,
    F: Fn(&T) -> (String, String, i64, Vec<u8>) + Send + 'static,
{
    BroadcastStream::new(receiver).filter_map(move |item| match item {
        Ok(snapshot) => {
            let (scope, snapshot_id, generated_at, payload) = extract(&snapshot);
            Some(Ok(batch_for(
                schema,
                scope,
                snapshot_id,
                generated_at,
                payload,
                0,
            )))
        }
        Err(tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(skipped)) => {
            log::debug!("{schema}: skipped {skipped} superseded snapshot(s)");
            None
        }
    })
}

fn batch_for(
    schema: &str,
    observation_scope: String,
    snapshot_id: String,
    generated_at_unix_nano: i64,
    payload: Vec<u8>,
    dropped_since_last: u64,
) -> pb::TelemetryBatch {
    let envelope = discovery_pb::DiscoveryEnvelope {
        schema: schema.to_owned(),
        producer_id: ADDON_ID.to_owned(),
        observation_scope,
        snapshot_id: snapshot_id.clone(),
        // One part. A snapshot large enough to need splitting would be roughly
        // 73,000 L2 bindings on a single interface; the largest measured on a
        // live collector was 127. The envelope carries the fields so the
        // control plane can reassemble if that ever changes.
        part_index: 0,
        part_count: 1,
        complete: true,
        generated_at_unix_nano,
        dropped_since_last,
        payload,
    };

    pb::TelemetryBatch {
        source: Some(pb::TelemetrySource {
            source_type: ADDON_ID.to_owned(),
            source_instance: envelope.observation_scope.clone(),
            metadata: Default::default(),
        }),
        records: vec![discovery_record(
            snapshot_id,
            generated_at_unix_nano,
            generated_at_unix_nano,
            envelope,
        )],
        counters: None,
    }
}

/// Bind the add-on socket and serve `AddonService` on it.
///
/// Called AFTER privileges are dropped, so the socket is owned by the
/// unprivileged runtime user rather than root.
pub async fn serve(addon: NetprobeAddon, socket_path: PathBuf) -> Result<()> {
    let listener = bind_socket(&socket_path)
        .with_context(|| format!("failed to bind add-on socket {}", socket_path.display()))?;

    log::info!("serving AddonService on {}", socket_path.display());

    serve_on_listener(addon, listener, None)
        .await
        .map_err(|err| anyhow::anyhow!("add-on service terminated: {err}"))
}

fn bind_socket(path: &Path) -> Result<UnixListener> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    // A stale socket from a previous run refuses bind with EADDRINUSE even when
    // nothing is listening, so an unclean shutdown would otherwise wedge every
    // subsequent start.
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => {
            return Err(err).with_context(|| format!("failed to remove stale {}", path.display()));
        }
    }

    let listener = UnixListener::bind(path)?;
    restrict_socket_permissions(path)?;

    Ok(listener)
}

/// Owner-only. `AddonService` exposes `Configure` and `RunCommand`, so the socket
/// must not be reachable by any local process that happens to share the runtime
/// group.
///
/// THIS MODE IS THE WHOLE ACCESS CONTROL on this socket, so it is pinned by a
/// test rather than left to a umask or a future refactor. The legacy IPC socket
/// was the counterexample this comment used to name: it was left at the umask
/// default until it grew capture control, and `crate::uds` now applies the same
/// restriction to both.
///
/// It is deliberately NOT paired with an `SO_PEERCRED` uid check; the reasoning
/// is in [`crate::uds::PeerCredentials`], which is where the credentials are
/// read for the audit record instead.
///
/// What the mode does NOT do is distinguish THE AGENT from any other process
/// running as the same user, and on the shipped units those are the same user
/// (`User=serviceradar` in the agent unit, `--drop-user serviceradar` here). Only
/// mutual authentication separates them. The SDK implements mTLS
/// (`addon_sdk::tls::build_server_mtls`), but it is fed by go-plugin's AutoMTLS
/// handshake, and netprobe is systemd-supervised rather than agent-launched --
/// there is no handshake to carry a cert. Closing that gap needs cert
/// distribution for a supervised add-on, which is a larger change than this one.
#[cfg(test)]
fn restrict_socket_permissions_for_test(path: &Path) -> Result<()> {
    restrict_socket_permissions(path)
}

fn restrict_socket_permissions(path: &Path) -> Result<()> {
    crate::uds::restrict_to_owner(path, "AddonService")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Channels plus the senders a test needs to publish on.
    fn test_channels() -> (
        TelemetryChannels,
        broadcast::Sender<ProcessSnapshot>,
        broadcast::Sender<FingerprintEvent>,
        broadcast::Sender<DpiEvent>,
    ) {
        let (census, _) = broadcast::channel(8);
        let (mdns, _) = broadcast::channel(8);
        let (process, _) = broadcast::channel(8);
        let (fingerprint, _) = broadcast::channel(8);
        let (dpi, _) = broadcast::channel(8);

        (
            TelemetryChannels {
                census,
                mdns,
                process: process.clone(),
                fingerprint: fingerprint.clone(),
                dpi: dpi.clone(),
            },
            process,
            fingerprint,
            dpi,
        )
    }

    fn census_snapshot() -> DeviceCensusSnapshot {
        DeviceCensusSnapshot {
            observations: vec![],
            snapshot_id: "ens18-1700000000-1".to_owned(),
            interface_name: "ens18".to_owned(),
            generated_at_unix_nano: 1_700_000_060_000_000_000,
            complete: true,
            chunk_count: 1,
            ..Default::default()
        }
    }

    #[test]
    fn a_snapshot_becomes_one_discovery_record() {
        let snapshot = census_snapshot();
        let batch = batch_for(
            CENSUS_SCHEMA,
            snapshot.interface_name.clone(),
            snapshot.snapshot_id.clone(),
            snapshot.generated_at_unix_nano,
            snapshot.encode_to_vec(),
            0,
        );

        assert_eq!(batch.records.len(), 1);
        let record = &batch.records[0];
        assert_eq!(
            record.payload_kind,
            pb::TelemetryPayloadKind::DiscoveryV1 as i32
        );

        let envelope = discovery_pb::DiscoveryEnvelope::decode(record.payload.as_slice())
            .expect("payload is a DiscoveryEnvelope");
        assert_eq!(envelope.schema, CENSUS_SCHEMA);
        assert_eq!(envelope.observation_scope, "ens18");
        assert_eq!(envelope.snapshot_id, "ens18-1700000000-1");
        assert!(envelope.complete);
        assert_eq!(envelope.part_count, 1);

        // The payload is the census snapshot verbatim: the agent forwards these
        // bytes without decoding them.
        let decoded = DeviceCensusSnapshot::decode(envelope.payload.as_slice())
            .expect("envelope payload is the snapshot");
        assert_eq!(decoded.snapshot_id, snapshot.snapshot_id);
    }

    #[test]
    fn the_envelope_carries_no_identity() {
        // agent_id, gateway_id and partition are stamped by the control plane
        // from gateway-attested metadata. producer_id is for display only, and
        // TelemetrySource.metadata stays empty rather than becoming a place
        // where identity accidentally accretes.
        let snapshot = census_snapshot();
        let batch = batch_for(
            CENSUS_SCHEMA,
            snapshot.interface_name.clone(),
            snapshot.snapshot_id.clone(),
            snapshot.generated_at_unix_nano,
            snapshot.encode_to_vec(),
            0,
        );

        let source = batch.source.expect("source is set");
        assert!(source.metadata.is_empty());
        assert!(batch.records[0].metadata.is_empty());
    }

    #[tokio::test]
    async fn health_reports_the_capability_state_the_agent_reads() {
        let addon = NetprobeAddon::new(
            "0.2.44",
            test_channels().0,
            RuntimeConfig::new(&crate::config::Config::default()),
            StartupSnapshot::default(),
        );

        let health = addon.health().await.expect("health");

        // Every field push_loop_capabilities reads off PingAck today has a
        // carrier here. If one of these disappears, the sweep banner-grab
        // capability stops reporting and nothing else says so.
        for key in [
            "running_as_root",
            "fingerprint_engine_version",
            "corpus_revision.p0f",
            "corpus_revision.ja4",
            "corpus_revision.muonfp",
            "corpus_revision.recog",
            "corpus_revision.satori",
        ] {
            assert!(health.details.contains_key(key), "missing detail {key}");
        }

        assert_eq!(
            health
                .details
                .get("corpus_revision.p0f")
                .map(String::as_str),
            Some(P0F_CORPUS_REVISION)
        );
        // Prose stays out of details.
        assert!(health.degradation_reason.is_empty());
    }

    fn match_banners_request(payload_json: Vec<u8>) -> CommandRequest {
        CommandRequest {
            command_id: "cmd-1".to_owned(),
            command_type: "addon.run_command".to_owned(),
            action_id: banner_command::MATCH_BANNERS_ACTION.to_owned(),
            schema: banner_command::MATCH_BANNERS_SCHEMA.to_owned(),
            payload_json,
            deadline_unix: 0,
            metadata: Default::default(),
        }
    }

    #[tokio::test]
    async fn run_command_matches_banners_over_the_generic_contract() {
        let addon = addon_with(StartupSnapshot::default());
        // "Apache/2.4.58 (Ubuntu)" -- base64 so binary banners survive intact.
        let payload = br#"{"observations":[{"observation_id":42,"protocol":"http","banner_b64":"QXBhY2hlLzIuNC41OCAoVWJ1bnR1KQ=="}]}"#;

        let result = addon
            .run_command(match_banners_request(payload.to_vec()))
            .await
            .expect("command runs");

        assert!(result.success, "{}", result.message);
        let body: serde_json::Value =
            serde_json::from_slice(&result.payload_json).expect("json response");
        assert_eq!(body["observations"], 1);
        assert_eq!(body["matches"][0]["observation_id"], 42);
        assert_eq!(body["matches"][0]["product"], "HTTPD");
    }

    #[tokio::test]
    async fn run_command_refuses_an_unknown_action_and_schema() {
        let addon = addon_with(StartupSnapshot::default());

        let mut wrong_action = match_banners_request(br#"{"observations":[]}"#.to_vec());
        wrong_action.action_id = "harvest_everything".to_owned();
        let result = addon.run_command(wrong_action).await.expect("answers");
        assert!(!result.success);
        assert!(
            result.message.contains("unsupported action_id"),
            "{}",
            result.message
        );

        // A schema this build does not implement must be refused rather than
        // decoded as v1 -- guessing would answer confidently about the wrong shape.
        let mut wrong_schema = match_banners_request(br#"{"observations":[]}"#.to_vec());
        wrong_schema.schema = "serviceradar.netprobe.banner_match.v99".to_owned();
        let result = addon.run_command(wrong_schema).await.expect("answers");
        assert!(!result.success);
        assert!(
            result.message.contains("unsupported schema"),
            "{}",
            result.message
        );
    }

    #[tokio::test]
    async fn a_malformed_command_payload_is_a_result_not_a_transport_error() {
        // Mirrors configure/0: an Err here becomes a gRPC status the agent
        // retries, and a payload that does not parse will not parse next time.
        let addon = addon_with(StartupSnapshot::default());

        let result = addon
            .run_command(match_banners_request(b"{not json".to_vec()))
            .await
            .expect("answers rather than erroring");

        assert!(!result.success);
        assert!(
            result.message.contains("could not parse"),
            "{}",
            result.message
        );
        assert!(result.payload_json.is_empty());
    }

    fn addon_with(startup: StartupSnapshot) -> NetprobeAddon {
        let config = crate::config::Config {
            capture_interfaces: startup.capture_interfaces.clone(),
            flow_table_max_entries: startup.flow_table_max_entries,
            ..Default::default()
        };

        NetprobeAddon::new(
            "0.2.44",
            test_channels().0,
            RuntimeConfig::new(&config),
            startup,
        )
    }

    #[tokio::test]
    async fn configure_applies_a_live_config_and_returns_its_hash() {
        let addon = addon_with(StartupSnapshot::default());

        let result = addon
            .configure(br#"{"enabled": true, "default_sample_interval_ms": 250}"#)
            .await
            .expect("configure returns");

        assert!(result.accepted, "rejected: {}", result.error);
        assert!(
            result.config_hash.starts_with("netprobe-v1:"),
            "hash = {}",
            result.config_hash
        );
    }

    #[tokio::test]
    async fn configure_carries_dpi_and_device_bindings() {
        // The reason Configure refused outright until now. A parser missing
        // these would produce empty values, wipe every binding, and still
        // report accepted -- worse than refusing.
        let addon = addon_with(StartupSnapshot::default());

        let result = addon
            .configure(
                br#"{
                    "enabled": true,
                    "dpi": {"enabled": true, "protocols": ["tls"]},
                    "device_bindings": [{"ip": "192.168.1.10", "profile_id": "camera"}]
                }"#,
            )
            .await
            .expect("configure returns");

        assert!(result.accepted, "rejected: {}", result.error);
    }

    #[tokio::test]
    async fn configure_refuses_a_restart_only_change_and_names_the_field() {
        // capture_interfaces decides which NICs eBPF programs were attached to,
        // so this process cannot become the requested config. Reported as not
        // accepted because nothing was applied -- claiming otherwise would tell
        // the control plane a setting took effect while the running collector
        // still has the old one.
        let addon = addon_with(StartupSnapshot {
            capture_interfaces: vec!["ens18".to_owned()],
            flow_table_max_entries: 65_536,
        });

        let result = addon
            .configure(br#"{"capture_interfaces": ["ens19"]}"#)
            .await
            .expect("configure returns");

        assert!(!result.accepted);
        assert!(
            result.error.contains("capture_interfaces") && result.error.contains("restart"),
            "error should name the field and the remedy: {}",
            result.error
        );
        assert!(result.config_hash.is_empty(), "nothing was applied");
    }

    #[tokio::test]
    async fn configure_refuses_a_flow_table_resize() {
        let addon = addon_with(StartupSnapshot {
            capture_interfaces: vec![],
            flow_table_max_entries: 65_536,
        });

        let result = addon
            .configure(br#"{"flow_table_max_entries": 131072}"#)
            .await
            .expect("configure returns");

        assert!(!result.accepted);
        assert!(result.error.contains("flow_table_max_entries"));
    }

    #[tokio::test]
    async fn unparseable_json_is_a_rejection_not_a_transport_error() {
        // Err would become a gRPC failure the agent retries. A malformed config
        // is durable -- retrying cannot improve it, and the reason has to reach
        // the operator rather than a retry loop.
        let addon = addon_with(StartupSnapshot::default());

        let result = addon
            .configure(b"{not json")
            .await
            .expect("configure returns");

        assert!(!result.accepted);
        assert!(result.error.contains("parse"));
    }

    fn addon_with_collector_ip(
        collector_ip: &str,
    ) -> (
        NetprobeAddon,
        broadcast::Sender<ProcessSnapshot>,
        broadcast::Sender<FingerprintEvent>,
        broadcast::Sender<DpiEvent>,
    ) {
        let (channels, process, fingerprint, dpi) = test_channels();
        let config = crate::config::Config {
            collector_ip: collector_ip.to_owned(),
            ..Default::default()
        };

        (
            NetprobeAddon::new(
                "0.2.50",
                channels,
                RuntimeConfig::new(&config),
                StartupSnapshot::default(),
            ),
            process,
            fingerprint,
            dpi,
        )
    }

    #[tokio::test]
    async fn a_process_snapshot_carries_its_subject_and_supersedes_by_host() {
        let (addon, process, _fingerprint, _dpi) = addon_with_collector_ip("10.20.30.40");
        let mut stream = addon.stream_telemetry();

        process
            .send(ProcessSnapshot {
                fingerprint: "synthetic-1".to_owned(),
                observed_at_unix_nano: 1_700_000_060_000_000_000,
                ..Default::default()
            })
            .expect("send");

        let batch = tokio::time::timeout(std::time::Duration::from_secs(5), stream.next())
            .await
            .expect("stream did not yield")
            .expect("stream ended")
            .expect("batch");

        let record = batch.records.first().expect("one record");
        let envelope =
            discovery_pb::DiscoveryEnvelope::decode(record.payload.as_slice()).expect("envelope");

        assert_eq!(envelope.schema, PROCESS_SCHEMA);
        // Scope IS set, unlike the event schemas: a process listing replaces the
        // host's previous one, so it should supersede by watermark.
        assert_eq!(envelope.observation_scope, "10.20.30.40");
        assert!(envelope.complete);
        assert_eq!(envelope.part_count, 1);

        let payload =
            ProcessSnapshotBatch::decode(envelope.payload.as_slice()).expect("process batch");
        assert_eq!(
            payload.subject_ip, "10.20.30.40",
            "the subject travels IN the payload; a decoder gets nothing else"
        );
        assert_eq!(
            payload.snapshot.expect("snapshot").fingerprint,
            "synthetic-1"
        );
    }

    #[tokio::test]
    async fn no_collector_ip_means_the_process_schema_is_not_served() {
        // Not served, rather than served with an empty subject. Core would have
        // to guess which device a process listing describes, and guessing wrong
        // attaches a host's processes to someone else's device.
        let (addon, process, _fingerprint, _dpi) = addon_with_collector_ip("");
        let mut stream = addon.stream_telemetry();

        process
            .send(ProcessSnapshot {
                fingerprint: "synthetic-1".to_owned(),
                observed_at_unix_nano: 1_700_000_060_000_000_000,
                ..Default::default()
            })
            .ok();

        let yielded = tokio::time::timeout(std::time::Duration::from_millis(250), stream.next())
            .await
            .is_ok();

        assert!(!yielded, "a process snapshot was emitted with no subject");
    }

    #[test]
    fn dpi_subject_prefers_the_collector_at_either_endpoint() {
        let collector = "10.20.30.40";

        // Collector as SOURCE.
        assert_eq!(
            dpi_subject_ip(
                &DpiEvent {
                    source_ip: collector.into(),
                    destination_ip: "10.20.30.60".into(),
                    ..Default::default()
                },
                collector
            ),
            collector
        );

        // Collector as DESTINATION -- the arm core cannot reproduce, because it
        // has no attested collector address and can only prefer source.
        assert_eq!(
            dpi_subject_ip(
                &DpiEvent {
                    source_ip: "10.20.30.65".into(),
                    destination_ip: collector.into(),
                    ..Default::default()
                },
                collector
            ),
            collector,
            "the collector must win from the destination side too"
        );
    }

    #[test]
    fn dpi_subject_falls_back_to_source_then_destination() {
        assert_eq!(
            dpi_subject_ip(
                &DpiEvent {
                    source_ip: "10.20.30.61".into(),
                    destination_ip: "10.20.30.62".into(),
                    ..Default::default()
                },
                "10.20.30.40"
            ),
            "10.20.30.61"
        );

        assert_eq!(
            dpi_subject_ip(
                &DpiEvent {
                    destination_ip: "10.20.30.63".into(),
                    ..Default::default()
                },
                ""
            ),
            "10.20.30.63"
        );
    }

    #[tokio::test]
    async fn a_fingerprint_batch_opts_out_of_supersession() {
        let (addon, _process, fingerprint, _dpi) = addon_with_collector_ip("10.20.30.40");
        let mut stream = addon.stream_telemetry();

        fingerprint
            .send(FingerprintEvent {
                ip: "10.20.30.41".into(),
                observed_at_unix_nano: 1_700_000_060_000_000_000,
                ..Default::default()
            })
            .expect("send");

        let batch = tokio::time::timeout(std::time::Duration::from_secs(10), stream.next())
            .await
            .expect("stream did not yield")
            .expect("stream ended")
            .expect("batch");

        let record = batch.records.first().expect("one record");
        let envelope =
            discovery_pb::DiscoveryEnvelope::decode(record.payload.as_slice()).expect("envelope");

        assert_eq!(envelope.schema, FINGERPRINT_SCHEMA);
        // THE point of this test. A scope would make each batch supersede the one
        // before it by watermark (buffer.ex:161), and all but the newest would be
        // dropped -- events are independent, not a replacing view.
        assert!(
            envelope.observation_scope.is_empty(),
            "an event batch must opt out of supersession"
        );
        assert!(envelope.complete);
        assert_eq!(envelope.part_count, 1);

        let payload =
            FingerprintEventBatch::decode(envelope.payload.as_slice()).expect("fingerprint batch");
        assert_eq!(payload.events.len(), 1);
    }

    #[tokio::test]
    async fn a_dpi_batch_carries_the_subject_netprobe_chose() {
        let (addon, _process, _fingerprint, dpi) = addon_with_collector_ip("10.20.30.40");
        let mut stream = addon.stream_telemetry();

        // Collector is the DESTINATION: core could only have picked the source.
        dpi.send(DpiEvent {
            protocol: "tls".into(),
            source_ip: "10.20.30.65".into(),
            destination_ip: "10.20.30.40".into(),
            observed_at_unix_nano: 1_700_000_060_000_000_000,
            ..Default::default()
        })
        .expect("send");

        let batch = tokio::time::timeout(std::time::Duration::from_secs(10), stream.next())
            .await
            .expect("stream did not yield")
            .expect("stream ended")
            .expect("batch");

        let record = batch.records.first().expect("one record");
        let envelope =
            discovery_pb::DiscoveryEnvelope::decode(record.payload.as_slice()).expect("envelope");
        let payload = DpiEventBatch::decode(envelope.payload.as_slice()).expect("dpi batch");

        assert_eq!(
            payload.subject_ips,
            vec!["10.20.30.40".to_string()],
            "netprobe must resolve the subject; core cannot"
        );
        // The packet's real direction is untouched -- the choice rides alongside
        // rather than being smuggled through source_ip.
        assert_eq!(payload.events[0].source_ip, "10.20.30.65");
    }

    #[tokio::test]
    async fn the_addon_socket_is_owner_only() {
        // The mode IS the access control on this socket -- it is what keeps a
        // process sharing the runtime GROUP away from Configure and RunCommand.
        // Pinned so a umask change or a refactor of bind_socket cannot loosen it
        // silently; there is no second mechanism behind it to catch that.
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("addon.sock");

        let _listener = bind_socket(&path).expect("bind");

        let mode = std::fs::metadata(&path).expect("stat").permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "the AddonService socket must be owner-only; got {mode:o}"
        );
    }

    #[tokio::test]
    async fn binding_over_a_stale_socket_succeeds() {
        // An unclean shutdown leaves a socket file that refuses bind with
        // EADDRINUSE even though nothing is listening, which would wedge every
        // subsequent start.
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("addon.sock");

        std::fs::write(&path, b"").expect("stale file");
        let _listener = bind_socket(&path).expect("bind over stale socket");

        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).expect("stat").permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "a rebind must restrict the mode too");
    }

    #[tokio::test]
    async fn a_socket_that_cannot_be_restricted_refuses_to_serve() {
        // Simulates a chmod that reports success without taking effect, which is
        // real on some mounts. The check reads the mode back, so the failure is a
        // refusal to serve rather than an AddonService quietly reachable by the
        // whole runtime group.
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("addon.sock");
        let _listener = bind_socket(&path).expect("bind");

        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o660)).expect("loosen");

        let err = restrict_socket_permissions_for_test(&path);
        assert!(
            err.is_ok(),
            "restricting a loosened socket should succeed: {err:?}"
        );

        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
