## Why

ServiceRadar currently only ingests NetFlow (V5/V9/IPFIX) for network flow observability. Many network environments use sFlow as their primary flow telemetry protocol — particularly environments with Arista, Juniper, and HP switches. Adding sFlow ingestion broadens the network visibility ServiceRadar can provide and makes it viable in mixed-protocol environments. The proto schema already anticipates sFlow (`SFLOW_5 = 1` enum value), and the `flowparser-sflow` crate (v0.1.0) provides a ready-made parser.

## What Changes

- **New Rust sFlow collector** (`rust/sflow-collector/`): A new collector binary following the same architecture as `netflow-collector` — UDP listener, sFlow parser (`flowparser-sflow` crate), converter to `FlowMessage` protobuf, and NATS JetStream publisher. Listens on UDP port 6343 (sFlow standard).
- **Rename "NetFlow" tab to "Flows"**: The observability tab currently labeled "NetFlow" will be renamed to "Flows" to serve as the unified view for all flow protocols (NetFlow, sFlow, and future protocols). Routes change from `/netflow` to `/flows`.
- **Collector enrollment for sFlow**: Add `"sflow"` as a supported collector type in the collector bundle generator and enrollment API, with appropriate default configuration.
- **Settings page rename**: Rename "NetFlow" settings to "Flows" settings at `/settings/flows`.

## Capabilities

### New Capabilities
- `sflow-collector`: Rust sFlow v5 collector — UDP ingestion, parsing via `flowparser-sflow`, conversion to `FlowMessage` protobuf, NATS publishing. Covers config, listener, converter, publisher, and metrics.

### Modified Capabilities
- `observability-signals`: Rename "NetFlow" observability signal to "Flows" across UI labels, routes, SRQL catalog, and settings navigation. Add sFlow as a recognized flow source type alongside NetFlow/IPFIX.

## Impact

- **New crate**: `rust/sflow-collector/` added to workspace `Cargo.toml`
- **New dependency**: `flowparser-sflow = "0.1"` in the sflow-collector crate
- **Proto**: No schema changes needed — `FlowMessage` already has `SFLOW_5` type and all required fields
- **NATS subject**: New subject `flows.raw.sflow` for sFlow data (parallel to `flows.raw.netflow`)
- **Elixir routes**: `/netflow` → `/flows`, `/settings/netflows` → `/settings/flows` — **BREAKING** for bookmarked URLs (redirect from old paths)
- **Collector API**: `collector_type` enum gains `"sflow"` value
- **Docker/deployment**: New container image for sflow-collector, new port mapping (UDP 6343)
- **Bundle generator**: New sflow config template with sFlow-specific defaults (port 6343, protocols list)
