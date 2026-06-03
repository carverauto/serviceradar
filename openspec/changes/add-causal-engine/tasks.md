# Tasks: Add Causal Engine (DeepCausality automation loop)

Phased implementation checklist. Each phase maps to one or more capabilities in the decomposition: `causal-engine`, `causal-reasoning`, `causal-prediction-signals`, `inventory-risk-feed`, `service-flow-bridge`, `device-components`, and the MODIFIED specs `observability-signals`, `age-graph`, `health-events`, `topology-causal-overlays`, `topology-god-view`.

Automation-first ordering: the engine exists to turn events into alerts and state enrichment; the God-View render is one optional consumer. Verdicts MUST re-enter the automation loop (alerts/state), not merely paint a graph.

## 0. Phase 0 — Pre-V1 (days)

### 0.1 Gap G — RESOLVED upstream by ultragraph 0.9.0 (capability: causal-reasoning)
- [x] 0.1.1 Verified upstream: `ultragraph 0.9.0` (tagged `ultragraph-v0.9.0`, published to crates.io, released 2025-08-27) ALREADY implements the full Gap G surface with real (non-stub) code — `StructuralGraphAlgorithms` (strongly_connected_components / articulation_points / bridges / biconnected_components), `pathway_betweenness_centrality(pathways, directed, normalized)`, `is_reachable`, and `unfreeze`. The "upstream PR" framing was an artifact of the docs being written against the `0.8` the NIF pins. No DeepCausality PR is needed; see `runbooks/gap-g-resolution.md`.
- [ ] 0.1.2 ServiceRadar action: depend on `ultragraph = "0.9"` in `rust/causal-engine` (task 1.1.3) and implement causaloids C4/C5/C5b/C7/C8/C9 against the existing trait methods (task 1.4.2). API notes: `articulation_points()`/`bridges()` use the undirected view (matches `CONNECTS_TO`); `is_reachable(start_index, stop_index)` and `pathway_betweenness_centrality(pathways, directed, normalized)` take node-index args.

### 0.2 Gap B — capacity coverage audit + eligibility contract (capability: age-graph) — IMPLEMENTED
- [x] 0.2.1 Audit SQL authored: `runbooks/gap-b-capacity-audit.sql` (sizes `platform.discovered_interfaces` speed_bps/if_speed coverage + canonical-edge capacity-eligibility violations). NOTE: run read-only against CNPG before/after deploy; the audit RUN itself is pending DB access.
- [x] 0.2.2 Eligibility contract implemented in `network_discovery/topology_graph.ex`: `telemetry_status_fields/4` now requires `capacity_bps > 0` (min-of-both-ends from speed_bps/if_speed) AND observed flow for `telemetry_eligible`; capacity-less edges are skipped by the saturation causaloid (C6). Refines the existing field; no new schema column.
- [x] 0.2.3 Coverage-gap + eligibility predicate documented in the runbook header and the `age-graph` "Capacity Eligibility Contract" requirement.
- [ ] 0.2.4 Post-deploy: run a full canonical-topology refresh so stored `telemetry_eligible` reconciles (the edit changes computed eligibility, not existing rows retroactively).

### 0.3 App-level state-change-events publisher in core-elx (Decision 1) (capability: observability-signals) — PARTIAL
- [x] 0.3.1a NEW module `event_writer/state_change_publisher.ex`: `publish_transition/3` → `signals.state.<table>` via `NATS.Connection.publish/3`; default-disabled (`STATE_CHANGE_EVENTS_ENABLED` env / `:state_change_events_enabled` app env); fire-and-forget. NOT pgoutput CDC / NOT logical replication.
- [x] 0.3.1b Hook `health_events` (tap `HealthTracker.record_state_change/3` — old/new already in hand).
- [x] 0.3.1c Hook `service_state` (NOT the `service_status` hypertable): pre-fetch prior availability in `ServiceStateRegistry.upsert_from_status/1` (gated behind `enabled?/0`) and publish only on a real transition; keyed by composite service identity (Decision 2).
- [x] 0.3.1d Hook `ocsf_devices` is_available/is_managed transitions in `inventory/sync_ingestor.ex`: gated pre-fetch of prior is_available/is_managed by uid before `upsert_devices`, diff after `{:ok, remap}` (publishes against the remapped final uid). COALESCE-aware — only a non-nil incoming value that differs counts as a transition; risk_score deferred (separate DeviceRiskReducer rollup hook).
- [ ] 0.3.1e Hook virtualization + AGE-projection transition write-sites (not yet grounded). DEFERRED.
- [x] 0.3.2 `service_state` (not the `service_status` hypertable) is the transition surface; the publisher targets only current-state tables. Add an explicit hypertable-exclusion guard/test when the ocsf_devices/virt hooks land.
- [x] 0.3.3 Identity per table: `ocsf_devices` → `sr:` `uid`; `service_state` → composite `agent_id:service_type:service_name` (Decision 2); `health_events` → writer `entity_id`. The engine maps `(table, entity_uid)` into one canonical space.
- [x] 0.3.4 Envelope carries before/after (`explainability.old/new`), `partition_id`, per-node monotonic `seq`, `event_time`, and `event_identity` (engine dedupes on `event_identity`). Unit test: `test/serviceradar/event_writer/state_change_publisher_test.exs`.
- [ ] 0.3.5 Provision the `signals.state.>` JetStream STREAM + consumer/processor with the Phase-1 engine consumer (see 1.2.3) — deferred so app startup is not coupled to a not-yet-existing processor module.

## 1. Phase 1 — V1 Engine (weeks)

### 1.1 Scaffold rust/causal-engine in the workspace (capability: causal-engine) — DONE
- [x] 1.1.1 Created top-level crate `rust/causal-engine` (single binary, single FUSED pod), added to workspace members + Cargo.lock; BUILD.bazel mirrors rust/srql (`all_crate_deps`). Verified `cargo check` / `cargo clippy --all-targets -D warnings` / `cargo fmt --check` + `bazel build //rust/causal-engine:{causal_engine_lib,causal_engine_bin} --config=ci` (RBE) all green.
- [x] 1.1.2 Modules `context_hydrator` (`ContextStore` trait + stub), `domain_model` (Context/Device/Service, canonical sr: ids), `reasoner` (Verdict/Classification + stub), `emitter` (stub), `snapshot` (stub); plus `config` (`CAUSAL_ENGINE_*` via envy) + `error` (thiserror).
- [ ] 1.1.3 Heavy integration deps DEFERRED to the increment that first uses them (srql + async-nats in 1.2; `ultragraph = "0.9"` + deep_causality{,_sparse,_tensor,_topology} in 1.3) to keep each crate_universe change scoped.
- [ ] 1.1.4 (partial) Config (envy) + tracing logging + snapshot-restore-on-start wired and a fused tick loop runs; graceful shutdown lands with the real hydrator/NATS in 1.2.

### 1.2 Hydrator — three ingestion feeds (capability: causal-engine) — Feed 1 done
- [x] 1.2.1 Feed 1 (current-state snapshot): `ContextHydrator::connect()` builds `EmbeddedSrql` from srql `AppConfig::from_env`, and `current_context()` runs SRQL queries (`in:devices`, `in:services`) via `QueryEngine::execute_query`, mapping result rows into the `Context` (Device/Service). On-demand continuous-aggregate + AGE `graph_cypher` queries land as coverage broadens (1.2b). Unit-tested row mappers.
- [ ] 1.2.2 Feed 2: JetStream subscriber for live deltas on EXISTING causal subjects (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, zen OCSF). (1.2b)
- [ ] 1.2.3 Feed 3: app-level `signals.state.<table>` state-change-events. Delta parse/apply CORE landed (`delta.rs`: `parse_state_change` of the StateChangePublisher envelope + `apply_delta` mutating the in-memory Context for ocsf_devices is_available/is_managed and service_state available; unit-tested). REMAINING: the async JetStream subscriber maintaining a shared Context (Arc<RwLock>) that applies deltas between snapshots, + provision the `signals.state.>` stream. (1.2b)
- [x] 1.2.4 Single-point identity validation: `map_device` skips any device whose `uid` is not a canonical `sr:`-prefixed id (the engine never forks the ID space). Extend to every entity mapper as coverage grows.
- [ ] 1.2.5 Handle endpoint-cluster summary nodes so a verdict on a clustered device does not silently fail to render. (1.2b)

### 1.3 Reasoner — CausaloidGraph over ultragraph CSR (capability: causal-reasoning)
- [ ] 1.3.1 Build the `CausaloidGraph` on an ultragraph `CsmGraph` (CSR); `freeze()` before each reasoning tick.
- [ ] 1.3.2 `unfreeze()` ONLY when topology actually changes (a state-change-event that mutates vertices/edges), not on every metric delta.
- [ ] 1.3.3 Implement the reasoning tick loop: hydrate Context, freeze, evaluate causaloids, collect verdicts, hand off to emitter.

### 1.4 Implement causaloids C1–C13 (capability: causal-reasoning)
- [ ] 1.4.1 Implement the 7 non-graph causaloids (not gated on Gap G) operating on Context state/metrics/risk: C1 (virt host→guest cascade), C2 (datastore→guest disk), C3 (gateway/agent root-cause, incl. Gap E out-of-band distinction), C6 (interface saturation, capacity-eligible edges only), C11 (flap-rate precursor), C12 (operator-rule promotion from `stateful_alert_rules`), C13 (discovery-gap disambiguation).
- [ ] 1.4.2 Implement the 6 graph causaloids using ultragraph 0.9 methods: C4, C5, C5b, C7, C8, C9 (`articulation_points` / `bridges` for single-point-of-failure and redundancy reasoning, `is_reachable` for blast-radius / management reachability, `pathway_betweenness_centrality` for criticality). Note in code which causaloid calls which algorithm.
- [ ] 1.4.3 Verify the 6 graph causaloids compile and run against the pinned `ultragraph 0.9`; the full C1–C13 set ships together (no upstream gate remains).

### 1.5 Risk composition into C5/C7/C10 (capability: causal-reasoning, inventory-risk-feed)
- [ ] 1.5.1 Feed per-device risk (`ocsf_devices.risk_score` / `risk_level_id` / `risk_level`) into causaloids C5, C7, and C10 as an evidence input.
- [ ] 1.5.2 Consume risk via `DeviceRiskReducer` MAX-wins semantics only; do NOT author any purl/cpe coordinate-matching here (DELEGATED to `add-cti-signal-coverage`).

### 1.6 Emitter — signals.causal.predictions producer (capability: causal-prediction-signals) — DONE (engine side)
- [x] 1.6.1 `rust/causal-engine/src/emitter.rs`: `Emitter` connects NATS JetStream (`async_nats` 0.48) and publishes one message per verdict on `signals.causal.predictions.<entity>` with a DETERMINISTIC `event_identity` (`pred:<entity>:<classification>`, stable across restarts), awaiting each ack. Unit-tested envelope builder + determinism + subject sanitization.
- [x] 1.6.2 OCSF-compatible envelope (signal_type `causal`; event_type ∈ root_cause/affected/healthy/unknown; `source_identity.entity_uid`; `routing_correlation.topology_keys`) mirrors what `CausalSignals` (`event_writer/processors/causal_signals.ex`) normalizes into `ocsf_events` — the `signals.causal.*` prefix already routes (`pipeline.ex:261-262`), so no new INBOUND plumbing.
- [ ] 1.6.3 Verify (Elixir-side, once verdicts flow end-to-end) the in-process `:causal_signal_ingested` broadcast (Phoenix `CausalPubSub`) still fires so the God-View 4-bucket render path is driven.

### 1.7 Snapshot persistence (capability: causal-engine)
- [ ] 1.7.1 Implement `snapshot` module: serialize Context + CausaloidGraph frozen state to disk on a cadence and on graceful shutdown.
- [ ] 1.7.2 Implement restore-on-start: load snapshot, then catch up from JetStream sequence/timestamp so single-pod restart is seconds, not a full cold rehydrate.

### 1.8 Inventory-risk-feed seam (capability: inventory-risk-feed)
- [ ] 1.8.1 Add an `endpoint_inventory` `DeviceRiskReducer` contribution (`upsert_contributions/2` `:31`, MAX-wins, `normalize_score` clamps 0–100 `:179`) writing `ocsf_devices.risk_score` from inventory; today the reducer is wired only to `sync_ingestor.ex` + `bumblebee_ingestor.ex`.
- [ ] 1.8.2 Emit `signals.causal.inventory.*` from the inventory ingestion path so inventory risk transitions reach the engine via the existing `signals.causal.*` route.
- [ ] 1.8.3 Add bounded AGE `Device` `pkg_*` risk SCALARS (no package vertices, no package edges) to the projection so the engine reads per-device package risk without unbounded fanout.
- [ ] 1.8.4 Consume per-device risk only; package<->CVE coordinate matching is DELEGATED to `add-cti-signal-coverage` (declared as a dependency, NOT authored here).

### 1.9 Automation-loop closure (capability: observability-signals, causal-prediction-signals)
- [ ] 1.9.1 Add `device.uid` group_by normalization + stateful alert rules in `StatefulAlertEngine` (`build_group/2` `:281` supports dotted keys but no `device.uid` normalization/rules exist yet) so normalized causal events fire alerts via `evaluate_events/1` (`:47`).
- [ ] 1.9.2 Confirm the firing path produces OCSF `class_uid:1008` ("alert.rule.threshold") -> `AlertGenerator.from_event` -> `monitoring.alerts` with cooldown/renotify honored.
- [ ] 1.9.3 Emit OCSF `class_uid:2004` vulnerability findings via the inventory domain so inventory-derived risk surfaces as findings, not only score enrichment.

### 1.10 god_view_nif refactor — 6 steps (capability: topology-god-view, causal-reasoning)
- [ ] 1.10.1 Extract `src/core/causality.rs` (244 LOC: `betweenness_scores` `15-66` + `evaluate_causal_states_with_reasons_impl` `83-244`, including the hard 3-hop BFS cap at `:183`) out of `elixir/web-ng/native/god_view_nif/` into `rust/causal-engine`.
- [ ] 1.10.2 Demote the NIF to a ~50-line renderer stub; keep the UI accelerators that STAY: `layout.rs` (543), `arrow_serde.rs` (494), `telemetry.rs` (352), `utils.rs` (457), `lib.rs` rustler bindings (815).
- [ ] 1.10.3 Drop `deep_causality` and `ultragraph` deps from the NIF crate now that reasoning moved to the engine.
- [ ] 1.10.4 Rejoin the NIF crate to the workspace by populating the empty `[workspace]` block at `Cargo.toml:23` (sibling `srql_nif` too).
- [ ] 1.10.5 Run incremental/reversible SHADOW mode: engine verdicts and NIF verdicts computed in parallel, diffed, with no UI cutover.
- [ ] 1.10.6 CUTOVER: switch the God-View render to consume engine-produced `signals.causal.predictions` -> normalized `ocsf_events` -> `GodViewSnapshot` 4 buckets (`root_cause|affected|healthy|unknown`, `:38-42`, `@schema_version 2`); retire the NIF reasoning path.

## 2. Phase 2 — Gap A service-flow-bridge (months)

### 2.1 Service identity + flow binding (capability: service-flow-bridge)
- [ ] 2.1.1 Build OTEL-derived service edges from `observability/otel_trace.ex` (`service_name:156-159`, `trace_id`, `span_id`, `parent_span_id` STRING) and `otel_trace_summary.ex` (`root_service_name`, `service_set`).
- [ ] 2.1.2 Add a service -> `IP:port` binding so services map onto network endpoints/devices in the canonical ID space.
- [ ] 2.1.3 Consume `attributed_flow` rows (`ocsf_network_activity` with `ocsf_payload.event_type="attributed_flow"` + `attribution{pid,comm,redacted_cmdline,uid,container_id}` from the in-flight PR ~#3516) to link flows to services/processes; compose, do NOT re-derive the correlation.
- [ ] 2.1.4 Extend C10 to reason at service granularity (service-level blast radius / dependency) using the new service edges.
- [ ] 2.1.5 Declare dependency on `add-service-oriented-plugin-monitoring` (service identity substrate); align with `refactor-topology-read-model-for-carrier-scale` render contract — no unbounded fanout.

## 3. Phase 3 — Gap C health vocabulary (months)

### 3.1 Extend and align the health-events enum (capability: health-events)
- [ ] 3.1.1 Reconcile and EXTEND the existing `health_events.new_state` atom enum (`infrastructure/health_event.ex:68`, values healthy/degraded/offline/connected/disconnected/active/failing/recovering/maintenance) — add `degrading`, `reduced-redundancy`, `failed` and define a severity ordering; it is NOT free text and NOT introduced from scratch.
- [ ] 3.1.2 Align the engine OUTPUT vocabulary to this extended enum so verdict states map 1:1 to health states.
- [ ] 3.1.3 Coordinate with `add-service-oriented-plugin-monitoring` (Gap A/C substrate) as a declared dependency.

## 4. Phase 4 — Gap F device-components (multi-quarter)

### 4.1 Structured components + redundancy substrate (capability: device-components, age-graph)
- [ ] 4.1.1 Add a `device-components` model (structured sub-device components: PSUs, line cards, fans, links) feeding redundancy reasoning.
- [ ] 4.1.2 Add an AGE `CONTAINS` edge from `Device` to its components in `network_discovery/topology_graph.ex` (alongside existing `CONNECTS_TO`, `HAS_INTERFACE`, `MANAGED_BY`, `CANONICAL_TOPOLOGY`).
- [ ] 4.1.3 Provide the redundancy substrate the structural causaloids (C4/C5/C5b/C8) need to distinguish single-point-of-failure from redundant components.
- [ ] 4.1.4 Coordinate with `add-device-environmental-snmp-metrics` and `add-structured-hypervisor-storage-enrichment` (Gap F substrate) as declared dependencies.

## 5. Phase 5 — Gap E OOB flag + Gap D reverse MANAGES (when convenient)

### 5.1 Out-of-band gateway flag (capability: age-graph, topology-causal-overlays)
- [ ] 5.1.1 Gap E: add `gateways.network_class` enum (`in-band|out-of-band|management`) so causaloids do not treat a management/OOB path as in-band reachability.
- [ ] 5.1.2 Surface `network_class` into the AGE projection / overlay evidence so structural causaloids weight OOB paths correctly.

### 5.2 Reverse MANAGES edge (capability: age-graph)
- [ ] 5.2.1 Gap D: add a reverse `MANAGES` edge (inverse of `MANAGED_BY`) plus an index so the engine can traverse manager -> managed without a full scan.

## 6. Validation

- [ ] 6.1 Run `openspec validate add-causal-engine --strict` and resolve all issues (every requirement has >=1 `#### Scenario:`; headers use exact `## ADDED|MODIFIED|REMOVED|RENAMED Requirements`).
- [ ] 6.2 Add/update Bazel `BUILD` files for the new `rust/causal-engine` crate AND for the rejoined `god_view_nif` / `srql_nif` workspace members (this repo requires Bazel BUILD updates when adding Rust deps; `cargo`/`go test` can pass while `bazel test` breaks).
- [ ] 6.3 Update Bazel `BUILD` deps for any new Go/Elixir imports introduced by the core-elx publisher (0.3), `DeviceRiskReducer` inventory wiring (1.8), and `StatefulAlertEngine` `device.uid` rules (1.9).
- [ ] 6.4 Run `bazel build`/`bazel test` for affected targets and confirm green.
- [ ] 6.5 Verify cross-references resolve: `add-cti-signal-coverage`, `add-service-oriented-plugin-monitoring`, `add-device-environmental-snmp-metrics`, `add-structured-hypervisor-storage-enrichment`, `add-endpoint-sbom-inventory`, `add-bmp-dual-path-observability`, `refactor-topology-read-model-for-carrier-scale`, `improve-mapper-topology-fidelity`, `add-multipath-topology-discovery` are declared as dependencies in `proposal.md`.
