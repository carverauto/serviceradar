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
//! An add-on author implements [`Addon`] (Info / Configure / Health) and calls
//! [`serve`] from `main`:
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

use std::pin::Pin;

use async_trait::async_trait;
use tokio_stream::Stream;

pub use server::serve;
pub use server::serve_on_listener;
pub use server::ServeError;

/// Capability advertised by add-ons that support native telemetry streaming.
pub const CAPABILITY_NATIVE_TELEMETRY_V1: &str = "native-telemetry:v1";

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

/// Stream item type used by [`Addon::stream_telemetry`].
pub type TelemetryStream =
    Pin<Box<dyn Stream<Item = Result<pb::TelemetryBatch, tonic::Status>> + Send + 'static>>;

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
    /// A bounded explanation when `status` is not `Healthy`.
    pub degradation_reason: String,
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

    /// Optional native telemetry stream. Add-ons that advertise
    /// [`CAPABILITY_NATIVE_TELEMETRY_V1`] should override this method and return
    /// bounded telemetry batches. The default empty stream keeps legacy add-ons
    /// source-compatible.
    fn stream_telemetry(&self) -> TelemetryStream {
        Box::pin(tokio_stream::empty())
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
}
