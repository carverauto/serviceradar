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

use async_trait::async_trait;

pub use server::serve;
pub use server::serve_on_listener;
pub use server::ServeError;

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
}
