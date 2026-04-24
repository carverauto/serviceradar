## 1. Crate Scaffolding

- [x] 1.1 Create `rust/flow-collector/` directory with `Cargo.toml` combining dependencies from both existing crates (`flowparser-sflow`, `netflow_parser`, `async-nats`, `prost`, `tokio`, `serde`, `serde_json`, `clap`, `anyhow`, `log`, `env_logger`), edition 2024
- [x] 1.2 Create `rust/flow-collector/build.rs` with tonic-build proto compilation for `proto/flow/flow.proto`
- [x] 1.3 Update root `Cargo.toml` workspace members: add `rust/flow-collector`, remove `rust/sflow-collector` and `rust/netflow-collector`
- [x] 1.4 Create module directory structure: `src/sflow/` and `src/netflow/` subdirectories

## 2. Unified Config

- [x] 2.1 Create `src/config.rs` with top-level `Config` struct (shared fields: `nats_url`, `stream_name`, `nats_creds_file`, `stream_subjects`, `stream_max_bytes`, `partition`, `channel_size`, `batch_size`, `publish_timeout_ms`, `drop_policy`, `security`, `metrics_addr`) and `listeners: Vec<ListenerConfig>`
- [x] 2.2 Implement `ListenerConfig` as serde internally-tagged enum (`#[serde(tag = "protocol")]`) with variants `Sflow` and `Netflow`, each containing shared listener fields (`listen_addr`, `subject`, `buffer_size`) plus protocol-specific options
- [x] 2.3 Implement `Config::validate()` — check required top-level fields, non-empty listeners array, duplicate listen_addr detection, per-listener field validation, pending_flows range validation for netflow listeners
- [x] 2.4 Implement `Config::stream_subjects_resolved()` — merge subjects from all listeners plus `stream_subjects`, deduplicate and sort
- [x] 2.5 Port shared types: `DropPolicy`, `SecurityConfig`, `SecurityMode`, `TlsConfig`, `PendingFlowsCacheConfig` with cert path helpers
- [x] 2.6 Add config unit tests: valid multi-listener config, empty listeners, missing required fields, duplicate addresses, pending_flows validation, serde defaults

## 3. Error and Metrics

- [x] 3.1 Create `src/error.rs` combining error types from both collectors (`GetCurrentTimeError`, `ConversionError`)
- [x] 3.2 Create `src/metrics.rs` with `ListenerMetrics` struct (AtomicU64 counters: packets_received, flows_converted, flows_dropped, parse_errors) and `MetricsReporter` that iterates a `Vec` of named listener metrics, logging each with protocol/address prefix every 30 seconds

## 4. FlowHandler Trait and Protocol Implementations

- [x] 4.1 Define `FlowHandler` trait in `src/listener.rs` with `parse_datagram(&self, buf: &[u8], len: usize, peer: SocketAddr) -> Vec<FlowMessage>` and `protocol_name(&self) -> &'static str`
- [x] 4.2 Create `src/sflow/converter.rs` — relocate existing sflow converter from `rust/sflow-collector/src/converter.rs` (no logic changes, update module paths)
- [x] 4.3 Create `src/sflow/mod.rs` — implement `SflowHandler` struct owning `SflowParser` and `ListenerMetrics` Arc, implement `FlowHandler` trait by calling parser + converter + degenerate filtering + metric updates
- [x] 4.4 Create `src/netflow/converter.rs` — relocate existing netflow converter from `rust/netflow-collector/src/converter.rs` (no logic changes, update module paths)
- [x] 4.5 Create `src/netflow/mod.rs` — implement `NetflowHandler` struct owning `Mutex<AutoScopedParser>`, pending flows config, and `ListenerMetrics` Arc, implement `FlowHandler` trait with template event callbacks, degenerate filtering, and metric updates

## 5. Generic Listener

- [x] 5.1 Create `src/listener.rs` with generic `Listener` struct that takes a `Box<dyn FlowHandler>`, listen address, buffer size, mpsc sender, and `ListenerMetrics` Arc
- [x] 5.2 Implement `Listener::run()` — UDP recv loop calling `handler.parse_datagram()`, encode each `FlowMessage` to protobuf bytes, `mpsc::try_send` with backpressure drop + warning logging
- [x] 5.3 Add factory function to construct the appropriate `FlowHandler` from a `ListenerConfig` variant

## 6. Publisher

- [x] 6.1 Create `src/publisher.rs` — port from either existing publisher (they're identical), update to accept unified `Config` and use `stream_subjects_resolved()` for stream subject merging across all listeners

## 7. Main Orchestration

- [x] 7.1 Create `src/main.rs` with CLI args (default config `flow-collector.json`), config loading, logging of shared + per-listener settings
- [x] 7.2 Create single mpsc channel, spawn publisher task with the receiver
- [x] 7.3 Loop over `config.listeners` — construct `FlowHandler` and `Listener` per entry, clone mpsc sender, spawn each listener as independent tokio task, collect `JoinHandle`s and metrics refs
- [x] 7.4 Spawn metrics reporter task with collected listener metrics
- [x] 7.5 Implement `tokio::select!` over publisher handle (exit on failure) and listener handles (log failure, continue others)

## 8. Config Files and Docker

- [x] 8.1 Create `rust/flow-collector/flow-collector.json` example config with both sflow and netflow listeners
- [x] 8.2 Create `rust/flow-collector/Dockerfile` — multi-stage build, expose UDP ports 6343 and 2055, metrics port
- [x] 8.3 Update `docker-compose.simple.yml` if it references separate sflow/netflow collector services

## 9. Cleanup

- [x] 9.1 Delete `rust/sflow-collector/` directory
- [x] 9.2 Delete `rust/netflow-collector/` directory
- [x] 9.3 Verify `cargo build --release` succeeds for the new `flow-collector` crate
- [x] 9.4 Verify existing converter tests pass (relocated from both crates)
- [x] 9.5 Verify config validation tests pass
