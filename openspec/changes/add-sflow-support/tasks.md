## 1. Crate Scaffolding

- [x] 1.1 Create `rust/sflow-collector/` directory with `Cargo.toml` (name: `serviceradar-sflow-collector`, edition 2024, deps: `flowparser-sflow 0.1`, `prost`, `async-nats`, `tokio`, `serde`, `serde_json`, `log`, `env_logger`, `anyhow`, `clap`; build-dep: `tonic-build`)
- [x] 1.2 Add `"rust/sflow-collector"` to the workspace members in the root `Cargo.toml`
- [x] 1.3 Create `rust/sflow-collector/build.rs` with `tonic_build::compile_protos` for `proto/flow/flow.proto`
- [x] 1.4 Create `rust/sflow-collector/src/main.rs` with module declarations, CLI args (config path defaulting to `sflow-collector.json`), tokio runtime, and three-task orchestration (listener, publisher, metrics)

## 2. Configuration

- [x] 2.1 Create `rust/sflow-collector/src/config.rs` with `Config` struct: `listen_addr`, `buffer_size` (default 65536), `nats_url`, `nats_creds_file`, `stream_name`, `subject`, `stream_subjects`, `stream_max_bytes`, `partition`, `channel_size` (default 10000), `batch_size` (default 100), `publish_timeout_ms` (default 5000), `max_samples_per_datagram` (Option<u32>), `drop_policy`, `security` (SecurityConfig), `metrics_addr`
- [x] 2.2 Implement `Config::from_file()` with JSON deserialization and `validate()` method (required fields check, bounds validation)
- [x] 2.3 Port `DropPolicy`, `SecurityConfig`, `TlsConfig` types from netflow-collector (identical structs)
- [x] 2.4 Create `rust/sflow-collector/sflow-collector.json` example config with defaults (listen_addr `0.0.0.0:6343`, subject `flows.raw.sflow`)

## 3. Error Types

- [x] 3.1 Create `rust/sflow-collector/src/error.rs` with `ConversionError` enum and `GetCurrentTimeError` type (mirror netflow-collector pattern)

## 4. Converter

- [x] 4.1 Create `rust/sflow-collector/src/converter.rs` with protobuf module include (`flowpb`) and `Converter` struct holding `SflowDatagram`, `SocketAddr`, and `receive_time_ns`
- [x] 4.2 Implement `convert_flow_sample()` that iterates `FlowSample.records` and merges fields from `SampledIpv4`, `SampledIpv6`, `RawPacketHeader`, `ExtendedSwitch`, `ExtendedRouter`, `ExtendedGateway` into a single `FlowMessage`
- [x] 4.3 Implement SampledIpv4 mapping: `src_addr`, `dst_addr`, `src_port`, `dst_port`, `proto`, `tcp_flags`, `ip_tos`, `bytes`, `etype=0x0800`
- [x] 4.4 Implement SampledIpv6 mapping: `src_addr`, `dst_addr`, `src_port`, `dst_port`, `proto`, `tcp_flags`, `bytes`, `etype=0x86DD`
- [x] 4.5 Implement RawPacketHeader fallback: set `bytes` from `frame_length`, `etype` from `header_protocol`
- [x] 4.6 Implement ExtendedSwitch mapping: `src_vlan`, `dst_vlan`
- [x] 4.7 Implement ExtendedRouter mapping: `next_hop` (AddressType → bytes), `src_net`, `dst_net`
- [x] 4.8 Implement ExtendedGateway mapping: `src_as`, `dst_as`, `as_path` (flatten segments), `bgp_communities`, `bgp_next_hop`
- [x] 4.9 Implement flow sample metadata: `type=SFLOW_5`, `packets=1`, `sampling_rate`, `in_if`, `out_if`, `sampler_address` (agent_address → bytes), `sequence_num`, `time_received_ns`
- [x] 4.10 Implement `AddressType` → `Vec<u8>` helper for IPv4/IPv6 agent addresses
- [x] 4.11 Implement `is_valid_flow()` filter (drop flows with `bytes == 0 && packets == 0`)
- [x] 4.12 Implement top-level `convert()` that iterates datagram samples, skips `Counter`/`ExpandedCounter`/`ExpandedFlow`, and collects `FlowMessage` results from flow samples

## 5. Listener

- [x] 5.1 Create `rust/sflow-collector/src/listener.rs` with `Listener` struct holding config, UDP socket, `SflowParser`, and mpsc sender
- [x] 5.2 Implement `Listener::new()` — bind UDP socket, create `SflowParser` (with optional `max_samples` from config via `SflowParserBuilder`)
- [x] 5.3 Implement `Listener::run()` — UDP recv loop calling `process_packet()` per datagram
- [x] 5.4 Implement `process_packet()` — call `parser.parse_bytes()`, log parse errors, create `Converter`, filter degenerate flows, encode protobuf, `tx.try_send()` with backpressure warning

## 6. Publisher

- [x] 6.1 Copy `rust/netflow-collector/src/publisher.rs` to `rust/sflow-collector/src/publisher.rs` and update log messages from "NetFlow" to "sFlow" (publisher logic is identical — NATS connect, batch publish, exponential backoff, stream auto-creation, mTLS)

## 7. Metrics

- [x] 7.1 Create `rust/sflow-collector/src/metrics.rs` with `MetricsReporter` that logs packet count, flow count, drop count, and error count periodically (simplified version — no template cache stats since sFlow is stateless)

## 8. Tests

- [x] 8.1 Write unit tests for converter: SampledIpv4 → FlowMessage field mapping
- [x] 8.2 Write unit tests for converter: SampledIpv6 → FlowMessage field mapping
- [x] 8.3 Write unit tests for converter: ExtendedSwitch/Router/Gateway enrichment
- [x] 8.4 Write unit tests for converter: RawPacketHeader-only fallback
- [x] 8.5 Write unit tests for converter: counter sample skipping
- [x] 8.6 Write unit tests for converter: degenerate flow filtering
- [x] 8.7 Write unit tests for config: valid config parsing, missing required fields, default values
- [x] 8.8 Verify crate builds and all tests pass with `cargo test -p serviceradar-sflow-collector`

## 9. UI Rename — Routes and Labels

- [x] 9.1 Update `router.ex`: change `/netflow` live route to `/flows`, `/settings/netflows` routes to `/settings/flows`
- [x] 9.2 Add redirect routes in `router.ex`: `get("/netflow", PageController, :redirect_to_flows)` and `get("/netflows", PageController, :redirect_to_flows)`
- [x] 9.3 Update `page_controller.ex`: add `redirect_to_flows/2` function that preserves query params and redirects to `/flows`
- [x] 9.4 Update SRQL catalog (`srql/catalog.ex`): change label from `"NetFlow"` to `"Flows"` and route from `"/netflow"` to `"/flows"`
- [x] 9.5 Update `log_live/index.ex`: change tab button label from `"NetFlow"` to `"Flows"`, update tab id from `"netflows"` to `"flows"`, update `panel_title/1`
- [x] 9.6 Update settings nav links in `settings/netflow_live/index.ex`: change `~p"/settings/netflows"` paths to `~p"/settings/flows"`
- [x] 9.7 Update collector type badge labels in `collector_live/index.ex` and `edge_sites_live/show.ex` to show `"sFlow"` for `:sflow` type

## 10. Collector Enrollment

- [x] 10.1 Add `"sflow"` to the allowed `collector_type` list in `collector_controller.ex`
- [x] 10.2 Add `add_collector_defaults/2` clause for `:sflow` in `collector_enroll_controller.ex` with defaults (listen_addr `0.0.0.0:6343`, protocols `["sflow-v5"]`)
- [x] 10.3 Update `collector_bundle_generator.ex` to generate `sflow.json` config file for sFlow collector type with appropriate defaults

## 11. Build and Verify

- [x] 11.1 Run `cargo build -p serviceradar-sflow-collector` and fix any compilation errors
- [x] 11.2 Run `cargo test -p serviceradar-sflow-collector` and verify all tests pass
- [ ] 11.3 Run `mix compile` in `web-ng/` and verify no Elixir compilation errors from route/label changes (Elixir not installed locally — verify in CI)
