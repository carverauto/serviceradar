## Context
The current NetFlow path is internally inconsistent:

- `rust/flow-collector/src/listener.rs` currently serializes received flows to JSON before publishing to NATS
- `ServiceRadar.EventWriter.Config` routes `flows.raw.netflow` away from the canonical OCSF flow processor
- the UI and SRQL `in:flows` read from `platform.ocsf_network_activity`, and the flow enrichment/cache refresh path is also built around that table
- BGP analytics already query `platform.bgp_routing_info`, which is an aggregated store, not a per-flow UI path

There is also historical evidence of a Zen-based promotion path for `flows.raw.netflow.processed`, but that dependency is not a reliable or observable prerequisite for the current UI path and should not be required for the golden path.

## Goals / Non-Goals
- Goals:
  - restore a working end-to-end NetFlow path from collector to UI
  - make the raw subject contract explicit and testable
  - establish one canonical persisted flow model instead of competing per-flow stores
  - preserve BGP analytics without forcing the UI to query raw flow bytes or a second per-flow table
  - make failure stages diagnosable from metrics/health instead of only from empty UI symptoms
- Non-Goals:
  - redesign the `/netflow` or `/flows` user experience
  - redesign BGP dashboard semantics
  - replace SRQL query semantics for `in:flows`

## Decisions
- Decision: standardize `flows.raw.netflow` on protobuf `FlowMessage` bytes and treat that message as the only canonical raw contract.
  - Why: this is more efficient over the wire, avoids lossy JSON translation, preserves the full raw field set, and matches the intent of the existing `NetFlowMetrics` processor and tests.
  - Downstream NetFlow processing must decode the protobuf once and derive every stored projection from that decode instead of relying on an intermediate JSON envelope.
- Decision: `platform.ocsf_network_activity` is the only canonical persisted per-flow model for NetFlow.
  - Why: the UI, SRQL `in:flows`, enrichment, cache refresh workers, and rollups already depend on that table.
  - NetFlow should rejoin that path rather than make the rest of the stack pivot to a thinner raw table.
- Decision: BGP-specific analytics must derive from the same decoded protobuf into `platform.bgp_routing_info`, not a second per-flow flow table.
  - Why: the BGP dashboard already queries `bgp_routing_info`, which is an aggregated analytics store rather than a second source of truth for flow rows.
  - This preserves BGP visibility without duplicating every flow into both `ocsf_network_activity` and `netflow_metrics`.
- Decision: `platform.netflow_metrics` is removed from the required live ingest path.
  - Why: it duplicates the same event in a competing storage model and is the direct cause of the current split-brain behavior.
  - The table, processor, and stale docs/tests should be deleted so the codebase has only one supported NetFlow path.
- Decision: NetFlow health must report stage-level counters and last-error reasons.
  - Why: an empty UI currently gives no signal about whether decode, routing, transformation, or persistence failed.
  - At minimum we need visibility into UDP receive, NATS publish, decode success/failure, OCSF inserts, derived BGP observation inserts, and backlog/lag indicators where applicable.

## Alternatives Considered
- Keep the collector on JSON for `flows.raw.netflow` and align all consumers to that envelope.
  - Rejected because it preserves an unnecessary translation step, risks losing raw fields, and diverges from the existing `FlowMessage` contract already used by tests, docs, and the NetFlow metrics processor.
- Keep `netflow_metrics` as the canonical per-flow store and migrate the UI/SRQL path to query it directly.
  - Rejected because current `/flows`, `/netflow`, cache refresh workers, and `in:flows` are already deeply coupled to `ocsf_network_activity` and its enrichment/rollup shape.
- Rely exclusively on Zen promotion from `flows.raw.netflow` to `flows.raw.netflow.processed`.
  - Rejected because it leaves UI visibility dependent on bootstrap/runtime rule state and does not solve the current raw subject decode mismatch.
- Dual-write every flow into both `ocsf_network_activity` and `netflow_metrics`.
  - Rejected because it keeps two per-flow truths alive and turns the current repair into a permanent split-brain architecture.

## Risks / Trade-offs
- Some environments may currently tolerate or expect the accidental JSON encoding on `flows.raw.netflow`.
  - Mitigation: audit internal consumers during implementation and verify deployed images/components move together.
- OCSF does not have first-class typed columns for every NetFlow/BGP-specific field.
  - Mitigation: keep canonical per-flow data in OCSF plus unmapped payload fields, and persist BGP-specific analytics in `bgp_routing_info` where query shape actually requires it.
- Existing tooling or tests may still assume `netflow_metrics` is hot.
  - Mitigation: move routing and tests to the OCSF/BGP path first, then deprecate or remove stale expectations explicitly.

## Migration Plan
1. Restore protobuf `FlowMessage` publishing on `flows.raw.netflow`.
2. Update EventWriter flow handling to decode the protobuf and persist NetFlow into `platform.ocsf_network_activity`.
3. Derive BGP observations from the same decoded protobuf into `platform.bgp_routing_info` when AS-path data is present.
4. Drop the legacy `netflow_metrics` table and delete its dead code/docs/tests.
5. Add health/telemetry so mixed-version deployments or missing routing dependencies are detectable.

## Open Questions
- Do any deployment paths still intentionally depend on `flows.raw.netflow.processed` for NetFlow UI visibility after this repair?
