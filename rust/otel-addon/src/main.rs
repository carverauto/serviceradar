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

//! `serviceradar-otel-addon` packages the ServiceRadar OTEL collector as a
//! native agent add-on (edge-relay plan, step 2). It is supervised by the
//! agent's go-plugin client like every `agent-sidecar` add-on and:
//!
//! - serves the local OTLP/gRPC + OTLP/HTTP listeners from the `otel` crate,
//!   with the output backend forced to **agent-forward** (durable spool;
//!   `[output] backend = "agent"`);
//! - advertises `otlp-relay:v1` and serves `AddonService.RelayOtlp`,
//!   streaming spooled frames to the agent and advancing the spool's ack
//!   watermark as cumulative acks arrive;
//! - advertises `native-telemetry:v1` and serves `StreamTelemetry`,
//!   emitting OCSF spool-usage events on utilization threshold transitions
//!   (`spool_monitor`);
//! - reports Degraded when the spool is >= 90% full or a listener is down.
//!
//! Logging goes to stderr (env_logger's default): stdout is reserved for the
//! go-plugin handshake line.

mod addon;
mod spool_monitor;

use addon::OtelCollectorAddon;

#[tokio::main]
async fn main() {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .try_init();

    if let Err(err) = addon_sdk::serve(OtelCollectorAddon::default()).await {
        // Match the Go SDK / go-plugin UX: when run directly (no magic
        // cookie) print the friendly "this is a plugin" message; otherwise
        // report the failure on stderr and exit non-zero.
        if matches!(err, addon_sdk::ServeError::Handshake(_)) {
            eprint!("{}", addon_sdk::handshake::DIRECT_EXECUTION_MESSAGE);
        } else {
            eprintln!("serviceradar-otel-addon: {err}");
        }
        std::process::exit(1);
    }
}
