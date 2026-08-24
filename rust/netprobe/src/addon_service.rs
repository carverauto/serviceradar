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
    Addon, ConfigureResult, Health, HealthStatus, Info, TelemetryStream, discovery_pb,
    discovery_record, pb, serve_on_listener,
};
use anyhow::{Context, Result};
use async_trait::async_trait;
use prost::Message as _;
use tokio::net::UnixListener;
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::{Stream, StreamExt};

use crate::addon_config_json::AddonConfigJson;
use crate::capabilities;
use crate::fingerprint::{
    FINGERPRINT_ENGINE_VERSION, JA4_BASE_SPEC_REVISION, MUONFP_CORPUS_REVISION,
    P0F_CORPUS_REVISION, RECOG_CORPUS_REVISION, SATORI_CORPUS_REVISION,
    SERVICERADAR_ADDITIONS_REVISION, SERVICERADAR_RECOG_ADDITIONS_REVISION,
};
use crate::proto::netprobe::{
    DeviceCensusSnapshot, MdnsSnapshot, ProcessSnapshot, ProcessSnapshotBatch,
    VisibilityAgentConfig,
};
use crate::runtime_config::RuntimeConfig;

/// Schema names the control plane registers decoders and identity policy
/// against. Changing one of these strings is a contract break, not a rename:
/// an unregistered schema is dropped, loudly, rather than guessed at.
pub const CENSUS_SCHEMA: &str = "serviceradar.netprobe.census.v1";
pub const MDNS_SCHEMA: &str = "serviceradar.netprobe.mdns.v1";
pub const PROCESS_SCHEMA: &str = "serviceradar.netprobe.process.v1";

const ADDON_ID: &str = "netprobe";

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

/// netprobe's `AddonService` implementation.
#[derive(Clone)]
pub struct NetprobeAddon {
    version: String,
    census: broadcast::Sender<DeviceCensusSnapshot>,
    mdns: broadcast::Sender<MdnsSnapshot>,
    process: broadcast::Sender<ProcessSnapshot>,
    runtime_config: RuntimeConfig,
    startup: StartupSnapshot,
}

impl NetprobeAddon {
    pub fn new(
        version: impl Into<String>,
        census: broadcast::Sender<DeviceCensusSnapshot>,
        mdns: broadcast::Sender<MdnsSnapshot>,
        process: broadcast::Sender<ProcessSnapshot>,
        runtime_config: RuntimeConfig,
        startup: StartupSnapshot,
    ) -> Self {
        Self {
            version: version.into(),
            census,
            mdns,
            process,
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

    fn stream_telemetry(&self) -> TelemetryStream {
        let census = snapshot_stream(
            self.census.subscribe(),
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
            self.mdns.subscribe(),
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

            return Box::pin(census.merge(mdns));
        }

        let process = snapshot_stream(
            self.process.subscribe(),
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

        Box::pin(census.merge(mdns).merge(process))
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

/// Wraps one broadcast of snapshots as a stream of single-record telemetry
/// batches.
///
/// A lagged receiver is NOT an error here. Each snapshot completely supersedes
/// the last, so falling behind means the older views are worth skipping -- and
/// the count of skipped ones is reported as `dropped_since_last` so a quiet
/// segment and a saturated producer stay distinguishable.
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

/// Owner-only. `AddonService` exposes `Configure` and `RunCommand`, so the
/// socket must not be reachable by any local process that happens to share the
/// runtime group -- which is what the legacy IPC socket allows today.
fn restrict_socket_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to restrict {}", path.display()))?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let (census, _) = broadcast::channel(4);
        let (mdns, _) = broadcast::channel(4);
        let (process, _) = broadcast::channel(4);
        let addon = NetprobeAddon::new(
            "0.2.44",
            census,
            mdns,
            process,
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

    fn addon_with(startup: StartupSnapshot) -> NetprobeAddon {
        let (census, _) = broadcast::channel(4);
        let (mdns, _) = broadcast::channel(4);
        let config = crate::config::Config {
            capture_interfaces: startup.capture_interfaces.clone(),
            flow_table_max_entries: startup.flow_table_max_entries,
            ..Default::default()
        };

        let (process, _) = broadcast::channel(4);

        NetprobeAddon::new(
            "0.2.44",
            census,
            mdns,
            process,
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
    ) -> (NetprobeAddon, broadcast::Sender<ProcessSnapshot>) {
        let (census, _) = broadcast::channel(4);
        let (mdns, _) = broadcast::channel(4);
        let (process, _) = broadcast::channel(4);
        let config = crate::config::Config {
            collector_ip: collector_ip.to_owned(),
            ..Default::default()
        };

        (
            NetprobeAddon::new(
                "0.2.48",
                census,
                mdns,
                process.clone(),
                RuntimeConfig::new(&config),
                StartupSnapshot::default(),
            ),
            process,
        )
    }

    #[tokio::test]
    async fn a_process_snapshot_carries_its_subject_and_supersedes_by_host() {
        let (addon, process) = addon_with_collector_ip("10.20.30.40");
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
        let (addon, process) = addon_with_collector_ip("");
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
}
