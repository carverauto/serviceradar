## Why

The sFlow collector (`rust/sflow-collector/`) and NetFlow collector (`rust/netflow-collector/`) share ~80% identical code — publisher, config structure, main.rs orchestration, metrics reporting, and build.rs are nearly byte-for-byte duplicates. Both produce the same `FlowMessage` protobuf and publish to the same NATS JetStream infrastructure. Maintaining two separate binaries, Docker images, and config schemas creates unnecessary operational overhead, duplicated bug fixes, and divergent behavior for what is fundamentally one capability: receiving network flow data over UDP and publishing it to NATS.

## What Changes

- **BREAKING**: Remove `rust/sflow-collector/` and `rust/netflow-collector/` as separate crates
- **BREAKING**: Replace two Docker images with a single `flow-collector` image
- **BREAKING**: Replace two separate JSON config files with a single unified config supporting multiple listener definitions
- Create `rust/flow-collector/` — a single binary that listens on multiple UDP ports simultaneously, each configured with a protocol type (sFlow v5, NetFlow v5/v9, IPFIX)
- Unify shared infrastructure: publisher, config validation, metrics, error types, mTLS/security, and main.rs orchestration into single implementations
- Retain protocol-specific logic (parsers, converters) as modular components behind a common trait interface
- Support independent per-listener configuration (port, buffer size, protocol-specific options like `max_samples_per_datagram` or `pending_flows`)
- Share a single NATS publisher across all listeners, with per-protocol subjects

## Capabilities

### New Capabilities
- `flow-collector`: Unified multi-protocol flow collection binary supporting sFlow v5, NetFlow v5/v9, and IPFIX on independently configured UDP listeners, with shared NATS publishing, metrics, and security infrastructure

### Modified Capabilities
_None — the existing `sflow-collector` and `netflow-analytics` specs live only in change directories, not in `openspec/specs/`. This change supersedes and replaces the `add-sflow-support` sflow-collector spec entirely._

## Impact

- **Code**: `rust/sflow-collector/` and `rust/netflow-collector/` deleted; `rust/flow-collector/` created
- **Cargo workspace**: Two workspace members removed, one added in root `Cargo.toml`
- **Proto**: No changes — existing `proto/flow/flow.proto` and `FlowMessage` remain unchanged
- **Docker**: Two Dockerfiles replaced with one; two container images replaced with one exposing multiple UDP ports
- **Config**: Operators must migrate from two separate JSON configs to one unified config with a `listeners` array
- **Dependencies**: Both parser crates (`flowparser-sflow`, `netflow_parser`) become dependencies of the single crate
- **NATS**: No wire-format changes; subjects remain configurable per listener
- **Deployment**: Existing deployments running separate sFlow/NetFlow containers must switch to the unified image
