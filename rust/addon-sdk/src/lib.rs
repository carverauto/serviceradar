/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Rust helper for ServiceRadar native agent add-ons (issue 3425).
//!
//! The agent supervises `agent-sidecar` add-ons with HashiCorp `go-plugin`. That
//! library lives on the Go host side, but it defines a *language-neutral wire
//! protocol*: a handshake line on stdout, gRPC over a Unix-domain socket, and
//! (optionally) AutoMTLS where the host and the plugin exchange self-signed
//! certificates over the environment. This crate implements the plugin (server)
//! half of that protocol in Rust so a Rust add-on is launched and supervised by
//! the agent's *existing, unmodified* go-plugin client.
//!
//! An add-on author implements [`Addon`] (Info / Configure / Health and,
//! optionally, RunCommand / telemetry) and calls [`serve`] from `main`:
//!
//! ```ignore
//! #[tokio::main]
//! async fn main() {
//!     addon_sdk::serve(MyAddon::default()).await;
//! }
//! ```
//!
//! The handshake/transport contract this crate implements is documented in
//! `openspec/changes/add-native-addon-rust-sdk/` and mirrors
//! `github.com/hashicorp/go-plugin@v1.8.0` exactly (see [`handshake`] and
//! [`tls`]).

pub mod handshake;
pub mod tls;

mod server;

/// Generated tonic/prost stubs for `proto/agent/addon/v1/addon.proto`.
///
/// This is the gRPC contract shared verbatim with the Go SDK
/// (`go/pkg/addon`); the agent dispenses the `addon` plugin and calls these
/// three RPCs over the supervised connection.
pub mod pb {
    tonic::include_proto!("serviceradar.agent.addon.v1");
}

/// Generated prost stubs for the discovery envelope an add-on wraps device
/// observations in.
///
/// The envelope's `schema` field is a STRING on purpose: adding an observation
/// type is one registry entry in the control plane, with no proto edit, no
/// regeneration, and no agent change. Add a schema, never a payload kind.
pub mod discovery_pb {
    tonic::include_proto!("serviceradar.agent.discovery.v1");
}

/// Generated prost stubs for the canonical ServiceRadar metric envelope.
pub mod metric_pb {
    pub use serviceradar_metric_proto::pb::*;
}

use std::pin::Pin;

use async_trait::async_trait;
use prost::Message;
use tokio_stream::Stream;

pub use server::ServeError;
pub use server::serve;
pub use server::serve_on_listener;

/// Capability advertised by add-ons that support native telemetry streaming.
pub const CAPABILITY_NATIVE_TELEMETRY_V1: &str = "native-telemetry:v1";

/// Capability advertised by add-ons that serve the acked OTLP relay stream
/// (`AddonService.RelayOtlp`). Unlike [`CAPABILITY_NATIVE_TELEMETRY_V1`]
/// (lossy, fire-and-forget), relay frames carry a persistent monotonic
/// `relay_id` and stay in the add-on's durable spool until the agent acks
/// them after gateway acceptance, giving at-least-once delivery.
pub const CAPABILITY_OTLP_RELAY_V1: &str = "otlp-relay:v1";

/// Capability advertised by add-ons that consume the agent's local metric feed
/// (`AddonService.StreamMetricFeed`) to analyze samples at the edge before they
/// are shipped upstream — e.g. per-series anomaly detection.
pub const CAPABILITY_METRIC_FEED_V1: &str = "metric-feed:v1";

pub const SIGNAL_SCHEMA_METADATA_PRODUCER_ID: &str = "serviceradar.signal_schema.producer_id";
pub const SIGNAL_SCHEMA_METADATA_PRODUCER_VERSION: &str =
    "serviceradar.signal_schema.producer_version";
pub const SIGNAL_SCHEMA_METADATA_SCHEMA_ID: &str = "serviceradar.signal_schema.schema_id";
pub const SIGNAL_SCHEMA_METADATA_SCHEMA_VERSION: &str = "serviceradar.signal_schema.schema_version";
pub const SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_ID: &str =
    "serviceradar.signal_schema.display_contract_id";
pub const SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_VERSION: &str =
    "serviceradar.signal_schema.display_contract_version";
pub const SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT: &str =
    "serviceradar.signal_schema.display_contract";
pub const SIGNAL_SCHEMA_METADATA_SIGNAL_TYPE: &str = "serviceradar.signal_schema.signal_type";
pub const SIGNAL_SCHEMA_METADATA_PAYLOAD_KIND: &str = "serviceradar.signal_schema.payload_kind";
pub const METRIC_ENVELOPE_SCHEMA_VERSION: &str = "serviceradar.metric.v1";

/// Stream item type used by [`Addon::stream_telemetry`].
pub type TelemetryStream =
    Pin<Box<dyn Stream<Item = Result<pb::TelemetryBatch, tonic::Status>> + Send + 'static>>;

/// Outbound frame stream returned by [`Addon::relay_otlp`] (add-on -> agent).
pub type OtlpRelayStream =
    Pin<Box<dyn Stream<Item = Result<pb::OtlpRelayFrame, tonic::Status>> + Send + 'static>>;

/// Inbound ack-watermark stream passed to [`Addon::relay_otlp`]
/// (agent -> add-on). The server adapter boxes tonic's request stream into
/// this alias so implementations (and tests) are not tied to a transport.
pub type OtlpRelayAckStream =
    Pin<Box<dyn Stream<Item = Result<pb::OtlpRelayAck, tonic::Status>> + Send + 'static>>;

/// Inbound metric-feed frame stream (agent -> add-on) passed to
/// [`Addon::stream_metric_feed`]. Each frame carries an encoded
/// `serviceradar.metric.v1.MetricBatch` the add-on analyzes locally.
pub type MetricFeedStream =
    Pin<Box<dyn Stream<Item = Result<pb::MetricFeedFrame, tonic::Status>> + Send + 'static>>;

/// Outbound ack-watermark stream returned by [`Addon::stream_metric_feed`]
/// (add-on -> agent) for cumulative flow control over the metric feed.
pub type MetricFeedAckStream =
    Pin<Box<dyn Stream<Item = Result<pb::MetricFeedAck, tonic::Status>> + Send + 'static>>;

/// Coarse health of an add-on, mirroring `HealthResponse.Status` in the proto
/// and the Go `addon.HealthStatus` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthStatus {
    Unspecified,
    Healthy,
    Degraded,
    Unhealthy,
}

impl HealthStatus {
    /// Maps to the generated proto enum value.
    pub fn to_proto(self) -> pb::health_response::Status {
        match self {
            HealthStatus::Unspecified => pb::health_response::Status::Unspecified,
            HealthStatus::Healthy => pb::health_response::Status::Healthy,
            HealthStatus::Degraded => pb::health_response::Status::Degraded,
            HealthStatus::Unhealthy => pb::health_response::Status::Unhealthy,
        }
    }
}

/// The add-on's stable identity, version, and advertised capabilities.
#[derive(Debug, Clone, Default)]
pub struct Info {
    pub id: String,
    pub version: String,
    pub capabilities: Vec<String>,
}

/// Result of applying operator-selected configuration.
#[derive(Debug, Clone, Default)]
pub struct ConfigureResult {
    /// A stable hash of the applied configuration for agent-side change detection.
    pub config_hash: String,
    pub accepted: bool,
    /// A bounded diagnostic when `accepted` is false.
    pub error: String,
}

/// Result of a health probe.
#[derive(Debug, Clone)]
pub struct Health {
    pub status: HealthStatus,
    pub version: String,
    /// A bounded explanation when `status` is not `Healthy`. Prose for a human;
    /// the agent must not parse it.
    pub degradation_reason: String,
    /// Bounded, STRUCTURED capability state the agent reads to make decisions --
    /// e.g. netprobe's privilege level and fingerprint corpus revisions, which
    /// become the sweep banner-grab capability status.
    ///
    /// Not trusted for identity or authorization: this is the add-on describing
    /// its own runtime.
    pub details: std::collections::BTreeMap<String, String>,
}

/// Generic command invocation delivered by the agent to a native add-on.
///
/// The control plane owns scheduling and dispatch. The command reaches the
/// add-on only through the normal edge path: core/web-ng -> agent-gateway ->
/// agent -> local add-on gRPC. Add-ons should treat `payload_json` as the
/// package-declared command payload and return a bounded JSON response when
/// useful.
#[derive(Debug, Clone, Default)]
pub struct CommandRequest {
    pub command_id: String,
    pub command_type: String,
    pub action_id: String,
    pub schema: String,
    pub payload_json: Vec<u8>,
    pub deadline_unix: i64,
    pub metadata: std::collections::HashMap<String, String>,
}

/// Generic command result returned from [`Addon::run_command`].
#[derive(Debug, Clone, Default)]
pub struct CommandResult {
    pub success: bool,
    pub message: String,
    pub payload_json: Vec<u8>,
    pub metadata: std::collections::HashMap<String, String>,
}

/// Convenience builder for `TelemetryBatch` messages.
#[derive(Debug, Clone, Default)]
pub struct TelemetryBatchBuilder {
    batch: pb::TelemetryBatch,
}

impl TelemetryBatchBuilder {
    pub fn new(source_type: impl Into<String>, source_instance: impl Into<String>) -> Self {
        Self {
            batch: pb::TelemetryBatch {
                source: Some(pb::TelemetrySource {
                    source_type: source_type.into(),
                    source_instance: source_instance.into(),
                    metadata: Default::default(),
                }),
                records: Vec::new(),
                counters: None,
            },
        }
    }

    pub fn source_metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        if let Some(source) = &mut self.batch.source {
            source.metadata.insert(key.into(), value.into());
        }
        self
    }

    pub fn counters(mut self, counters: pb::TelemetryCounters) -> Self {
        self.batch.counters = Some(counters);
        self
    }

    pub fn push_record(mut self, record: pb::TelemetryRecord) -> Self {
        self.batch.records.push(record);
        self
    }

    pub fn build(self) -> pb::TelemetryBatch {
        self.batch
    }
}

/// Builds one OCSF event telemetry record.
pub fn ocsf_event_record(
    event_id: impl Into<String>,
    event_time_unix_nano: i64,
    observed_time_unix_nano: i64,
    payload: impl Into<Vec<u8>>,
) -> pb::TelemetryRecord {
    pb::TelemetryRecord {
        event_id: event_id.into(),
        observed_time_unix_nano,
        event_time_unix_nano,
        payload_kind: pb::TelemetryPayloadKind::OcsfEvent as i32,
        payload: payload.into(),
        metadata: Default::default(),
    }
}

/// Builds one ServiceRadar-native metric telemetry record.
///
/// The returned record carries an encoded `serviceradar.metric.v1.MetricBatch`
/// payload. Add-ons should use this for non-OTLP metrics; raw OTLP metrics stay
/// on the OTLP relay payload kinds.
pub fn serviceradar_metric_record(
    event_id: impl Into<String>,
    event_time_unix_nano: i64,
    observed_time_unix_nano: i64,
    mut batch: metric_pb::MetricBatch,
) -> pb::TelemetryRecord {
    if batch.schema_version.is_empty() {
        batch.schema_version = METRIC_ENVELOPE_SCHEMA_VERSION.to_owned();
    }
    match &mut batch.ingest_identity {
        Some(identity) if identity.payload_kind.is_empty() => {
            identity.payload_kind = METRIC_ENVELOPE_SCHEMA_VERSION.to_owned();
        }
        None => {
            batch.ingest_identity = Some(metric_pb::IngestIdentity {
                payload_kind: METRIC_ENVELOPE_SCHEMA_VERSION.to_owned(),
                ..Default::default()
            });
        }
        _ => {}
    }

    pb::TelemetryRecord {
        event_id: event_id.into(),
        observed_time_unix_nano,
        event_time_unix_nano,
        payload_kind: pb::TelemetryPayloadKind::ServiceradarMetrics as i32,
        payload: batch.encode_to_vec(),
        metadata: Default::default(),
    }
}

/// Builds one discovery telemetry record: device observations an add-on made
/// about OTHER hosts, bound for the inventory pipeline.
///
/// `schema` selects the decoder and, with it, the identity policy the
/// observations are ingested under. It must be a schema the control plane has
/// registered; an unregistered one is dropped loudly rather than guessed at.
///
/// Nothing in the envelope is trusted for identity. `agent_id`, `gateway_id`
/// and `partition` are stamped by the control plane from gateway-attested
/// metadata, and the source string comes from the registry -- so a `producer_id`
/// here is for display and telemetry only, never an identity claim.
///
/// For a SNAPSHOT (a complete replacement of `observation_scope`), set
/// `snapshot_id` to something that cannot repeat across a producer restart --
/// a process start time works -- so a reassembler can never merge parts of two
/// different snapshots. Leave it empty for an independent event.
#[allow(clippy::too_many_arguments)]
pub fn discovery_record(
    event_id: impl Into<String>,
    event_time_unix_nano: i64,
    observed_time_unix_nano: i64,
    envelope: discovery_pb::DiscoveryEnvelope,
) -> pb::TelemetryRecord {
    pb::TelemetryRecord {
        event_id: event_id.into(),
        observed_time_unix_nano,
        event_time_unix_nano,
        payload_kind: pb::TelemetryPayloadKind::DiscoveryV1 as i32,
        payload: envelope.encode_to_vec(),
        metadata: Default::default(),
    }
}

/// Bounded display/schema reference attached to package telemetry records.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SignalSchemaRef {
    pub producer_id: String,
    pub producer_version: String,
    pub schema_id: String,
    pub schema_version: String,
    pub display_contract_id: String,
    pub display_contract_version: String,
    pub display_contract: String,
    pub signal_type: String,
    pub payload_kind: String,
}

/// Stores a signal schema reference on a telemetry record's metadata map.
pub fn attach_signal_schema_ref(
    mut record: pb::TelemetryRecord,
    signal_schema: &SignalSchemaRef,
) -> pb::TelemetryRecord {
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_PRODUCER_ID,
        &signal_schema.producer_id,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_PRODUCER_VERSION,
        &signal_schema.producer_version,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_SCHEMA_ID,
        &signal_schema.schema_id,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_SCHEMA_VERSION,
        &signal_schema.schema_version,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_ID,
        &signal_schema.display_contract_id,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT_VERSION,
        &signal_schema.display_contract_version,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT,
        &signal_schema.display_contract,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_SIGNAL_TYPE,
        &signal_schema.signal_type,
    );
    insert_if_present(
        &mut record.metadata,
        SIGNAL_SCHEMA_METADATA_PAYLOAD_KIND,
        &signal_schema.payload_kind,
    );
    record
}

fn insert_if_present(
    metadata: &mut std::collections::HashMap<String, String>,
    key: &str,
    value: &str,
) {
    if !value.is_empty() {
        metadata.insert(key.to_owned(), value.to_owned());
    }
}

impl Default for Health {
    fn default() -> Self {
        Health {
            status: HealthStatus::Healthy,
            version: String::new(),
            degradation_reason: String::new(),
            details: Default::default(),
        }
    }
}

/// The clean Rust contract an add-on implements; mirrors the Go `addon.Addon`
/// interface so the agent consumes Go and Rust add-ons identically.
///
/// Implementations are shared (`Arc`) across concurrent gRPC calls, so methods
/// take `&self`. Use interior mutability (e.g. a `Mutex`) for configuration that
/// must survive across `Configure`.
#[async_trait]
pub trait Addon: Send + Sync + 'static {
    /// Reports the add-on's stable identity, version, and advertised capabilities.
    async fn info(&self) -> anyhow::Result<Info>;

    /// Applies operator-selected configuration (already validated by the control
    /// plane against the add-on's `config.schema.json`) and returns a stable hash.
    async fn configure(&self, config_json: &[u8]) -> anyhow::Result<ConfigureResult>;

    /// The readiness probe the agent polls; a non-healthy status carries a bounded
    /// degradation reason.
    async fn health(&self) -> anyhow::Result<Health>;

    /// Called when the host asks the plugin process to terminate. Add-ons with
    /// long-lived stream tasks should close/abort them here so tonic's graceful
    /// shutdown is not held open by in-flight RPCs.
    async fn shutdown(&self) -> anyhow::Result<()> {
        Ok(())
    }

    /// Optional native telemetry stream. Add-ons that advertise
    /// [`CAPABILITY_NATIVE_TELEMETRY_V1`] should override this method and return
    /// bounded telemetry batches. The default empty stream keeps legacy add-ons
    /// source-compatible.
    fn stream_telemetry(&self) -> TelemetryStream {
        Box::pin(tokio_stream::empty())
    }

    /// Optional generic command handler for package-declared producer schedules
    /// and run-now actions. Add-ons that declare schedules using
    /// `addon.run_command` should override this method. The default keeps older
    /// Rust add-ons source-compatible and lets the host report a bounded
    /// unavailable result instead of failing the gRPC method.
    async fn run_command(&self, _request: CommandRequest) -> anyhow::Result<CommandResult> {
        Ok(CommandResult {
            success: false,
            message: "addon command handler unavailable".to_owned(),
            payload_json: Vec::new(),
            metadata: Default::default(),
        })
    }

    /// Optional acked OTLP relay stream (`AddonService.RelayOtlp`). Add-ons
    /// that advertise [`CAPABILITY_OTLP_RELAY_V1`] should override this
    /// method: emit `OtlpRelayFrame`s with persistent monotonic `relay_id`s
    /// from the durable spool, and release spooled frames as the cumulative
    /// ack watermarks arrive on `acks`. The agent (the RPC client) acks a
    /// frame only after the agent-gateway accepted it inside a
    /// GatewayServiceStatus envelope with source == "otlp-relay", so unacked
    /// frames must be re-sent (original `relay_id`s) after a reconnect.
    ///
    /// The default rejects the call with UNIMPLEMENTED so add-ons without the
    /// capability fail loudly instead of silently dropping an acked relay.
    //
    // tonic::Status is the natural error type at this gRPC seam (the server
    // adapter forwards it verbatim); its size is tonic's concern, not ours.
    #[allow(clippy::result_large_err)]
    fn relay_otlp(&self, _acks: OtlpRelayAckStream) -> Result<OtlpRelayStream, tonic::Status> {
        Err(tonic::Status::unimplemented(
            "add-on does not implement otlp-relay:v1",
        ))
    }

    /// Optional local metric feed (`AddonService.StreamMetricFeed`). Add-ons that
    /// advertise [`CAPABILITY_METRIC_FEED_V1`] should override this: consume the
    /// agent's locally collected `MetricFeedFrame`s (each an encoded
    /// `serviceradar.metric.v1.MetricBatch`), analyze them at the edge, and
    /// return a stream of cumulative [`pb::MetricFeedAck`] watermarks so the
    /// agent can bound in-flight frames. The default rejects the call with
    /// UNIMPLEMENTED so add-ons without the capability fail loudly.
    #[allow(clippy::result_large_err)]
    fn stream_metric_feed(
        &self,
        _frames: MetricFeedStream,
    ) -> Result<MetricFeedAckStream, tonic::Status> {
        Err(tonic::Status::unimplemented(
            "add-on does not implement metric-feed:v1",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attach_signal_schema_ref_populates_record_metadata() {
        let record = pb::TelemetryRecord::default();
        let record = attach_signal_schema_ref(
            record,
            &SignalSchemaRef {
                producer_id: "powerdns".to_owned(),
                producer_version: "0.1.0".to_owned(),
                schema_id: "com.carverauto.powerdns.dns_activity".to_owned(),
                schema_version: "1.0.0".to_owned(),
                display_contract_id: "com.carverauto.powerdns.dns_activity.display".to_owned(),
                display_contract_version: "1.0.0".to_owned(),
                display_contract: "display/dns_activity.display.json".to_owned(),
                signal_type: "event".to_owned(),
                payload_kind: "ocsf_event".to_owned(),
            },
        );

        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_SCHEMA_ID),
            Some(&"com.carverauto.powerdns.dns_activity".to_owned())
        );
        assert_eq!(
            record.metadata.get(SIGNAL_SCHEMA_METADATA_DISPLAY_CONTRACT),
            Some(&"display/dns_activity.display.json".to_owned())
        );
    }

    /// An add-on that implements only the required contract (no otlp-relay:v1).
    struct RelaylessAddon;

    #[async_trait]
    impl Addon for RelaylessAddon {
        async fn info(&self) -> anyhow::Result<Info> {
            Ok(Info::default())
        }

        async fn configure(&self, _config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
            Ok(ConfigureResult::default())
        }

        async fn health(&self) -> anyhow::Result<Health> {
            Ok(Health::default())
        }
    }

    #[test]
    fn relay_otlp_defaults_to_unimplemented() {
        let err = RelaylessAddon
            .relay_otlp(Box::pin(tokio_stream::empty()))
            .err()
            .expect("default relay_otlp must reject the call");
        assert_eq!(err.code(), tonic::Code::Unimplemented);
    }

    #[test]
    fn otlp_relay_wire_types_match_contract() {
        assert_eq!(pb::TelemetryPayloadKind::OtlpTraces as i32, 3);
        assert_eq!(pb::TelemetryPayloadKind::OtlpLogs as i32, 4);
        assert_eq!(pb::TelemetryPayloadKind::OtlpMetrics as i32, 5);
        assert_eq!(pb::TelemetryPayloadKind::OtlpDerivedMetric as i32, 6);

        let frame = pb::OtlpRelayFrame {
            relay_id: 42,
            batch: Some(
                TelemetryBatchBuilder::new("otel-collector", "default")
                    .push_record(pb::TelemetryRecord {
                        payload_kind: pb::TelemetryPayloadKind::OtlpTraces as i32,
                        payload: b"export-request-chunk".to_vec(),
                        ..Default::default()
                    })
                    .build(),
            ),
        };
        let ack = pb::OtlpRelayAck { acked_relay_id: 42 };
        assert_eq!(ack.acked_relay_id, frame.relay_id);
    }

    #[test]
    fn discovery_record_wraps_an_envelope_under_the_discovery_kind() {
        let envelope = discovery_pb::DiscoveryEnvelope {
            schema: "serviceradar.netprobe.census.v1".to_owned(),
            producer_id: "netprobe".to_owned(),
            observation_scope: "ens18".to_owned(),
            snapshot_id: "ens18-1700000000-1".to_owned(),
            part_index: 0,
            part_count: 1,
            complete: true,
            generated_at_unix_nano: 1_700_000_060_000_000_000,
            dropped_since_last: 0,
            payload: vec![1, 2, 3],
        };

        let record = discovery_record("evt-1", 123, 456, envelope.clone());

        assert_eq!(
            record.payload_kind,
            pb::TelemetryPayloadKind::DiscoveryV1 as i32
        );
        assert_eq!(record.event_time_unix_nano, 123);
        assert_eq!(record.observed_time_unix_nano, 456);

        // The payload is the encoded envelope and nothing else: everything
        // between the add-on and the control plane treats it as opaque bytes.
        let decoded = discovery_pb::DiscoveryEnvelope::decode(record.payload.as_slice())
            .expect("payload is an encoded DiscoveryEnvelope");
        assert_eq!(decoded, envelope);

        // No identity is carried on the record itself. agent_id, gateway_id and
        // partition are stamped by the control plane from attested metadata.
        assert!(record.metadata.is_empty());
    }

    #[test]
    fn serviceradar_metric_record_wraps_metric_batch() {
        let record = serviceradar_metric_record(
            "evt-1",
            123,
            456,
            metric_pb::MetricBatch {
                resource: Some(metric_pb::MetricResource {
                    agent_id: "agent-1".to_owned(),
                    service_name: "sample-native-addon".to_owned(),
                    service_type: "native-addon".to_owned(),
                    attributes: vec![metric_pb::StringMapEntry {
                        key: "rack".to_owned(),
                        value: "rack-7".to_owned(),
                    }],
                    ..Default::default()
                }),
                ingest_identity: Some(metric_pb::IngestIdentity {
                    source: "native-addon".to_owned(),
                    producer_id: "sample-native-addon".to_owned(),
                    producer_kind: "native-addon".to_owned(),
                    ..Default::default()
                }),
                metrics: vec![
                    metric_pb::Metric {
                        name: "cpu.temperature_celsius".to_owned(),
                        metric_type: "cpu".to_owned(),
                        kind: metric_pb::MetricKind::Gauge as i32,
                        unit: "Cel".to_owned(),
                        points: vec![metric_pb::MetricPoint {
                            value: 62.5,
                            observed_at_unix_nano: 456,
                            attributes: vec![metric_pb::StringMapEntry {
                                key: "sensor".to_owned(),
                                value: "cpu0".to_owned(),
                            }],
                            ..Default::default()
                        }],
                        ..Default::default()
                    },
                    metric_pb::Metric {
                        name: "network.bytes_total".to_owned(),
                        metric_type: "interface".to_owned(),
                        kind: metric_pb::MetricKind::Sum as i32,
                        temporality: metric_pb::MetricTemporality::Cumulative as i32,
                        is_monotonic: true,
                        points: vec![metric_pb::MetricPoint {
                            value: 987.0,
                            raw_value: "987".to_owned(),
                            raw_value_type: metric_pb::MetricValueType::Uint64 as i32,
                            observed_at_unix_nano: 456,
                            ..Default::default()
                        }],
                        ..Default::default()
                    },
                ],
                ..Default::default()
            },
        );

        assert_eq!(
            record.payload_kind,
            pb::TelemetryPayloadKind::ServiceradarMetrics as i32
        );
        assert_eq!(record.event_id, "evt-1");
        assert_eq!(record.event_time_unix_nano, 123);
        assert_eq!(record.observed_time_unix_nano, 456);

        let decoded = metric_pb::MetricBatch::decode(record.payload.as_slice())
            .expect("metric batch decodes");
        assert_eq!(decoded.schema_version, METRIC_ENVELOPE_SCHEMA_VERSION);
        assert_eq!(
            decoded
                .ingest_identity
                .as_ref()
                .expect("ingest identity")
                .payload_kind,
            METRIC_ENVELOPE_SCHEMA_VERSION
        );
        assert_eq!(
            decoded.resource.as_ref().expect("resource").attributes[0].key,
            "rack"
        );
        assert_eq!(decoded.metrics[0].points[0].attributes[0].value, "cpu0");
        assert_eq!(decoded.metrics[0].kind, metric_pb::MetricKind::Gauge as i32);
        assert_eq!(decoded.metrics[1].kind, metric_pb::MetricKind::Sum as i32);
        assert_eq!(
            decoded.metrics[1].temporality,
            metric_pb::MetricTemporality::Cumulative as i32
        );
        assert!(decoded.metrics[1].is_monotonic);
        assert_eq!(
            decoded.metrics[1].points[0].raw_value_type,
            metric_pb::MetricValueType::Uint64 as i32
        );
    }
}
