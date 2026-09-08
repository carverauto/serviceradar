# Change: Ship the DeepCausality Causal Engine as a Real Prediction Service (`rust/causal-engine`)

## Why

The DeepCausality stack's actual value is **automation**: turn events into predictions, route predictions back into alerts and state, and only incidentally paint a topology graph. Today that stack is misused — it backs a 244-line reactive blast-radius stub buried in `god_view_nif` (`elixir/web-ng/native/god_view_nif/src/core/causality.rs`), pulling in `deep_causality`, `_sparse`, `_tensor`, `_topology`, and `ultragraph` to serve a 3-hop BFS plus betweenness scores that classify, never predict. This umbrella ships a real single-pod fused prediction engine on the substrate ServiceRadar already runs — CNPG via `EmbeddedSrql`, the AGE topology graph, and the existing JetStream `signals.causal.*` plumbing — and closes the automation loop by publishing predictions that re-enter `StatefulAlertEngine` as alerts, not merely render as a graph. The God-View renderer becomes one optional downstream consumer, not the center.

## What Changes

### Phase 0 — Pre-V1 (days)
- **Gap G (`ultragraph` version bump) — ALREADY UPSTREAM:** `ultragraph 0.9.0` (published to crates.io, released 2025-08-27) already ships `StructuralGraphAlgorithms` (`strongly_connected_components` / `articulation_points` / `bridges` / `biconnected_components`), `pathway_betweenness_centrality(pathways, directed, normalized)`, `is_reachable`, and `unfreeze`. The NIF pins `0.8`; the new `rust/causal-engine` simply depends on `ultragraph = "0.9"`. **No upstream PR and no wait** — the six graph causaloids (C4, C5, C5b, C7, C8, C9) are unblocked immediately (the docs' "implement upstream" framing predated 0.9.0).
- **Gap B coverage audit:** quantify `speed_bps`/`if_speed` population that feeds `capacity_bps` (derived in Elixir at `network_discovery/topology_graph.ex` edge `min_non_zero(src,dst)`, written to AGE `CANONICAL_TOPOLOGY`). No `if_high_speed` column and no Rust-side enrichment exist; this is a coverage audit PLUS an edge capacity-eligibility contract (the `age-graph` "Capacity Eligibility Contract" requirement marks capacity-less edges ineligible for C6), adding no new schema column.
- **App-level state-change-events feed (DECISION-1):** core-elx publishes `ocsf_devices` / `service_status` / `health_events` (and virtualization + AGE-projection) state **transitions** to `signals.state.<table>` NATS subjects. This is NOT pgoutput CDC and NOT logical replication (none exists today). TimescaleDB hypertables are NEVER streamed this way — they are queried on-demand via SRQL.

### Phase 1 — V1 ship (weeks)
- **NEW crate `rust/causal-engine`** (does not exist yet), peer to `rust/srql`: single binary, single pod, **fused** (hydrator + reasoner in-process — DeepCausality requires in-process `Context` access). Modules `context_hydrator` / `domain_model` / `reasoner` / `emitter` / `snapshot`, with a `ContextStore` trait between hydrator and reasoner to preserve a future split.
- **Ingestion (3 feeds):** (1) `EmbeddedSrql` over CNPG (`rust/srql/src/lib.rs:31-40`, `execute_query`, `graph_cypher`) for cold-start state, on-demand continuous-aggregate queries, and AGE topology snapshots; (2) JetStream subscriber on existing causal subjects (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, zen-consumer OCSF output); (3) the `signals.state.<table>` app-level transitions from Phase 0.
- **Reasoning:** `ultragraph` `CsmGraph` (CSR); `freeze()` before each tick, `unfreeze()` only on real topology change. Causaloids C1–C13 (six via the Gap G upstream calls), evaluated over the hydrated `Context`.
- **Identity:** REUSE canonical `sr:`-prefixed entity IDs (`RuntimeGraph.canonical_runtime_id/1`, `runtime_graph.ex:640-650`); single-point validation at ingestion. The engine MUST NOT invent a parallel ID space. Must handle endpoint-cluster summary nodes so verdicts on a clustered device id still render.
- **Emission + automation-loop closure:** a NEW producer publishes `signals.causal.predictions.{device_uid|incident_id}` to JetStream with **deterministic** prediction IDs. The existing `CausalSignals` processor (`event_writer/processors/causal_signals.ex`) + `pipeline.ex:261-262` already route the `signals.causal.*` prefix into `ocsf_events`; from there predictions (a) re-enter `StatefulAlertEngine.evaluate_events/1` (`stateful_alert_engine.ex:47`) as `device.uid`-grouped alerts (OCSF `class_uid` 1008), and (b) drive the God-View 4-bucket render. No new INBOUND plumbing; only the greenfield PRODUCER half.
- **Inventory risk feed (DECISION-4):** wire `endpoint_inventory` into `DeviceRiskReducer.upsert_contributions/2` (`device_risk_reducer.ex:31`, MAX-wins, writes `ocsf_devices.risk_score`); emit `signals.causal.inventory.*`; project bounded `pkg_*` risk scalars onto AGE `Device` vertices (no package vertices/edges). Per-device risk composes into causaloids C5/C7/C10. Package↔CVE coordinate-matching is DELEGATED to `add-cti-signal-coverage` (DECISION-3) — no purl/cpe matching authored here. Vuln findings emit as OCSF `class_uid` 2004 via the inventory domain.
- **`god_view_nif` refactor — BREAKING:** extract `src/core/causality.rs` (244 LOC) into `rust/causal-engine`; demote the NIF causality entry point to a ~50-line renderer stub reading verdicts from `ocsf_events` / `signals.causal.predictions`; drop `deep_causality*` + `ultragraph` from the NIF Cargo.toml; rejoin the top-level Rust workspace by removing the empty `[workspace]` blocks (`Cargo.toml:23`, sibling `srql_nif`). `layout.rs` / `arrow_serde.rs` / `telemetry.rs` / `utils.rs` / Rustler bindings STAY as the UI accelerator. Cutover is incremental and reversible (parallel publish → shadow compare → primary → demote).

### Phase 2 — Cross-domain inflection (months)
- **Gap A — service↔flow bridge:** derive OTEL service edges (`observability/otel_trace.ex` service_name / parent_span_id; `otel_trace_summary.ex` root_service_name / service_set), bind service→IP:port, and consume the in-flight `attributed_flow` rows (`ocsf_network_activity` with `ocsf_payload.event_type="attributed_flow"`). Upgrade C10 to service granularity.

### Phase 3 — Health vocabulary (months)
- **Gap C:** `health_events.new_state` is ALREADY an atom enum (`infrastructure/health_event.ex:68`). Reconcile + EXTEND it (add `degrading`, `reduced-redundancy`, `failed`; severity ordering) and align engine OUTPUT vocabulary; coordinate `add-service-oriented-plugin-monitoring`.

### Phase 4 — Structural-modeling program (multi-quarter)
- **Gap F:** introduce device-components + AGE `CONTAINS`; redundancy substrate. Coordinate `add-device-environmental-snmp-metrics` + `add-structured-hypervisor-storage-enrichment`.

### Phase 5 — Convenience (when convenient)
- **Gap E:** OOB gateway flag (`gateways.network_class` in-band | out-of-band | management). **Gap D:** reverse `MANAGES` edge / index in AGE.

### Capability deltas (11 total)
- **ADDED capabilities (6):** `causal-engine`, `causal-reasoning`, `causal-prediction-signals`, `inventory-risk-feed`, `service-flow-bridge`, `device-components`.
- **MODIFIED capabilities (5):** `observability-signals`, `age-graph`, `health-events`, `topology-causal-overlays`, `topology-god-view`.

## Impact

### Affected specs (all 11)
- ADDED: `causal-engine`, `causal-reasoning`, `causal-prediction-signals`, `inventory-risk-feed`, `service-flow-bridge`, `device-components`.
- MODIFIED: `observability-signals`, `age-graph`, `health-events`, `topology-causal-overlays`, `topology-god-view`.

### Affected code
- **NEW** `rust/causal-engine` (hydrator / domain_model / reasoner / emitter / snapshot; `ContextStore` trait).
- `elixir/web-ng/native/god_view_nif/` — **BREAKING** refactor: extract `src/core/causality.rs`, demote to renderer stub, drop DC deps, rejoin workspace (`Cargo.toml:23` + `srql_nif`).
- `event_writer/processors/causal_signals.ex` + `pipeline.ex:261-262` — consume the NEW `signals.causal.predictions.*` (no inbound change; producer is greenfield).
- `observability/stateful_alert_engine.ex` (`evaluate_events/1:47`, `build_group/2:281`) — `device.uid`-grouped causal alert rules (automation-loop closure).
- `inventory/device_risk_reducer.ex` (`:31`/`:69`) + `device_risk_contribution.ex` — wire `endpoint_inventory` contribution (MAX-wins).
- `network_discovery/topology_graph.ex` — AGE projection: bounded `pkg_*` Device scalars; Gap B `speed_bps`/`if_speed` coverage; Phase-5 reverse `MANAGES` edge.
- core-elx state-change publisher — NEW `signals.state.<table>` app-level transition emitter for `ocsf_devices` / `service_status` / `health_events` / virtualization / AGE-projection.

### Dependencies / Coordinate
- **Upstream `ultragraph` Gap G** — committed Phase-0 release adding articulation/bridge/reachability/pathway-centrality/unfreeze; six causaloids gate on it.
- **Composed-with (do NOT re-derive):** attributed-flow correlation (product branch `feat/attributed-flow-correlation`, PR ~#3516 — `flow_process_attributions`, `ServiceRadar.FlowAttribution`, `attributed_flow` rows) and `add-cti-signal-coverage` (owns package↔CVE coordinate-match; this umbrella only consumes per-device risk via `DeviceRiskReducer` / `ocsf_devices.risk_score`).
- **Coordinate (declared, deltas NOT authored here):** `add-cti-signal-coverage`, `add-service-oriented-plugin-monitoring` (service identity + Gap A/C substrate), `add-device-environmental-snmp-metrics` + `add-structured-hypervisor-storage-enrichment` (Gap F substrate), `add-endpoint-sbom-inventory` (landed tables), `add-bmp-dual-path-observability` (BMP signal feed), `refactor-topology-read-model-for-carrier-scale` (render contract — engine must honor its bounded/backbone-centric snapshot; do NOT reintroduce unbounded fanout), `improve-mapper-topology-fidelity` + `add-multipath-topology-discovery` (topology evidence quality).
