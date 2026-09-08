# Change: Fix NetFlow end-to-end ingestion

## Why
NetFlow exports are reaching the collector, but flows do not make it to the UI-backed query path. The current pipeline has two contract mismatches:

- the Rust flow collector publishes `flows.raw.netflow` payloads as JSON, while the Elixir `NetFlowMetrics` processor for that subject expects protobuf `FlowMessage` bytes
- the `/flows` and `/netflow` UI paths query `ocsf_network_activity`, while the current NetFlow raw subject is routed away from that canonical flow store

The deeper architectural problem is split ownership of the same flow event. The UI/SRQL flow path, flow enrichment, and rollups are all built around `platform.ocsf_network_activity`, while NetFlow recently shifted to a separate `netflow_metrics` hot path. That split introduced a silent regression and leaves no single golden path for flow ingestion.

That leaves operators with an empty UI and no clear indication whether the failure is in UDP receive, NATS publish, decode, transformation, or database persistence.

## What Changes
- Define and enforce a single canonical payload contract for `flows.raw.netflow`, using protobuf `FlowMessage` bytes end to end.
- Make `platform.ocsf_network_activity` the single canonical persisted flow model for NetFlow UI, SRQL, enrichment, and rollups.
- Derive BGP analytics from the same decoded protobuf message into `platform.bgp_routing_info` instead of writing a second per-flow NetFlow row.
- Remove the legacy `platform.netflow_metrics` table, processor, tests, and docs so the old path cannot silently regress again.
- Add explicit stage-level health and diagnostics for NetFlow ingestion so contract mismatches and missing transform/routing steps surface immediately.
- Add end-to-end tests that inject representative NetFlow/IPFIX records and verify UI-visible rows appear in the OCSF flow table while BGP analytics remain queryable through the derived BGP store.

## Impact
- Affected specs: `netflow-ingestion` (new)
- Affected code:
  - `rust/flow-collector/src/` for protobuf payload encoding
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/` for NetFlow routing, protobuf decoding, OCSF persistence, and telemetry
  - `elixir/serviceradar_core/lib/serviceradar/bgp/` for derived BGP observation ingestion
  - deployment/bootstrap assets where NetFlow transform dependencies are still configured
  - NetFlow troubleshooting docs and runbooks
- Breaking changes:
  - Internal only: `flows.raw.netflow` becomes an explicitly versioned contract and consumers must honor it
