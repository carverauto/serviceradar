# Tasks: Add Causal Engine (DeepCausality automation loop)

Phased implementation checklist. Each phase maps to one or more capabilities in the decomposition: `causal-engine`, `causal-reasoning`, `causal-prediction-signals`, `inventory-risk-feed`, `service-flow-bridge`, `device-components`, and the MODIFIED specs `observability-signals`, `age-graph`, `health-events`, `topology-causal-overlays`, `topology-god-view`.

Automation-first ordering: the engine exists to turn events into alerts and state enrichment; the God-View render is one optional consumer. Verdicts MUST re-enter the automation loop (alerts/state), not merely paint a graph.

## 0. Phase 0 — Pre-V1 (days)

### 0.1 Gap G — ultragraph upstream dependency (capability: causal-reasoning)
- [ ] 0.1.1 File the committed Phase-0 upstream PR against the `ultragraph` crate adding `articulation_points`, `bridges`, `is_reachable`, `pathway_betweenness_centrality`, and `unfreeze` (~200 LOC Tarjan/biconnected-components) on a new `StructuralGraphAlgorithms` trait (today 0.8 ships only `betweenness_centrality` + `freeze` under `CentralityGraphAlgorithms`).
- [ ] 0.1.2 Add CSR-aware tests on the frozen `CsmGraph` for each new algorithm (articulation points, bridges, reachability, pathway centrality) covering disconnected and single-node graphs.
- [ ] 0.1.3 Track the upstream release version and pin it; record that causaloids C4, C5, C5b, C7, C8, C9 gate on this release and the full causaloid set ships at launch.

### 0.2 Gap B — capacity coverage audit + eligibility contract (capability: topology-causal-overlays)
- [ ] 0.2.1 Audit `speed_bps` / `if_speed` population coverage across `mapper_results_ingestor.ex:2444` ingest and `network_discovery/topology_graph.ex` (per-interface coalesce `:1660`, edge `capacity_bps = min_non_zero(src,dst)` `:1565` written to AGE `CANONICAL_TOPOLOGY` `:901`); there is NO `if_high_speed` column and NO Rust-side enrichment.
- [ ] 0.2.2 Define the edge eligibility contract: which edges carry trustworthy `capacity_bps` and which are unknown, so saturation/redundancy causaloids do not reason over absent data.
- [ ] 0.2.3 Document coverage gaps and the eligibility predicate the engine will use to mark capacity evidence as `known` vs `unknown`.

### 0.3 App-level state-change-events publisher in core-elx (Decision 1) (capability: observability-signals)
- [ ] 0.3.1 Add a core-elx publisher that emits app-level state TRANSITIONS for `ocsf_devices`, `service_status`, and `health_events` (plus virtualization + AGE-projection transitions) to NATS subject `cdc.platform.<table>`. This is NOT pgoutput CDC and NOT logical replication.
- [ ] 0.3.2 NEVER stream TimescaleDB hypertables on this feed; hypertables remain on-demand via SRQL. Add a guard/test asserting hypertable tables are excluded.
- [ ] 0.3.3 Stamp every transition with the canonical `sr:`-prefixed entity ID (`RuntimeGraph.canonical_runtime_id/1`, `:640-650`) so the engine consumes one ID space (`ocsf_devices.uid == AGE Device.id == ocsf_events.device.uid`).
- [ ] 0.3.4 Include before/after state, partition_id, and a monotonic sequence/timestamp so the engine can order and dedupe deltas at ingestion.

## 1. Phase 1 — V1 Engine (weeks)

### 1.1 Scaffold rust/causal-engine in the workspace (capability: causal-engine)
- [ ] 1.1.1 Create new top-level Rust crate `rust/causal-engine`, peer to `rust/srql`, as a single binary / single FUSED pod (hydrator + reasoner in-process; DeepCausality requires in-process `Context` access).
- [ ] 1.1.2 Add modules: `context_hydrator`, `domain_model`, `reasoner`, `emitter`, `snapshot`; define a `ContextStore` trait between hydrator and reasoner to preserve a future split.
- [ ] 1.1.3 Add dependencies `deep_causality 0.13`, `deep_causality_sparse 0.1`, `deep_causality_tensor 0.4`, `deep_causality_topology 0.5`, and `ultragraph` pinned to the Gap-G release (0.1.3).
- [ ] 1.1.4 Wire startup/shutdown, config, and logging consistent with `rust/srql`; single-pod restart in seconds via snapshot (HA/leader-election/sharding are non-goals for V1).

### 1.2 Hydrator — three ingestion feeds (capability: causal-engine)
- [ ] 1.2.1 Feed 1: integrate `EmbeddedSrql` (`rust/srql/src/lib.rs:31-40`) calling `QueryEngine::execute_query` (`rust/srql/src/query/mod.rs`) for cold-start current state, on-demand TimescaleDB continuous-aggregate queries, and AGE topology snapshots via the `graph_cypher` entity (`rust/srql/src/query/graph_cypher.rs`).
- [ ] 1.2.2 Feed 2: add a JetStream subscriber for live deltas on EXISTING causal subjects (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, zen-consumer OCSF output).
- [ ] 1.2.3 Feed 3: add a JetStream subscriber for the app-level state-change-events on `cdc.platform.<table>` (from 0.3) and merge into Context.
- [ ] 1.2.4 Single-point identity validation at ingestion: reject/normalize any entity not carrying a canonical `sr:`-prefixed ID; the engine MUST NOT invent a parallel ID space.
- [ ] 1.2.5 Handle endpoint-cluster summary nodes: detect when a device ID was summarized by `GodViewStream` so a verdict on a clustered device does not silently fail to render.

### 1.3 Reasoner — CausaloidGraph over ultragraph CSR (capability: causal-reasoning)
- [ ] 1.3.1 Build the `CausaloidGraph` on an ultragraph `CsmGraph` (CSR); `freeze()` before each reasoning tick.
- [ ] 1.3.2 `unfreeze()` ONLY when topology actually changes (a state-change-event that mutates vertices/edges), not on every metric delta.
- [ ] 1.3.3 Implement the reasoning tick loop: hydrate Context, freeze, evaluate causaloids, collect verdicts, hand off to emitter.

### 1.4 Implement causaloids C1–C13 (capability: causal-reasoning)
- [ ] 1.4.1 Implement the 7 non-graph causaloids (not gated on Gap G) operating on Context state/metrics/risk: C1 (virt host→guest cascade), C2 (datastore→guest disk), C3 (gateway/agent root-cause, incl. Gap E out-of-band distinction), C6 (interface saturation, capacity-eligible edges only), C11 (flap-rate precursor), C12 (operator-rule promotion from `stateful_alert_rules`), C13 (discovery-gap disambiguation).
- [ ] 1.4.2 Implement the 6 ultragraph-gated causaloids using the Gap-G algorithms: C4, C5, C5b, C7, C8, C9 (e.g. `articulation_points` / `bridges` for single-point-of-failure and redundancy reasoning, `is_reachable` for blast-radius, `pathway_betweenness_centrality` for criticality). Note in code which causaloid calls which algorithm.
- [ ] 1.4.3 Gate-check: the 6 ultragraph causaloids compile and run only against the pinned Gap-G `ultragraph` release; the full C1–C13 set ships at launch.

### 1.5 Risk composition into C5/C7/C10 (capability: causal-reasoning, inventory-risk-feed)
- [ ] 1.5.1 Feed per-device risk (`ocsf_devices.risk_score` / `risk_level_id` / `risk_level`) into causaloids C5, C7, and C10 as an evidence input.
- [ ] 1.5.2 Consume risk via `DeviceRiskReducer` MAX-wins semantics only; do NOT author any purl/cpe coordinate-matching here (DELEGATED to `add-cti-signal-coverage`).

### 1.6 Emitter — signals.causal.predictions producer (capability: causal-prediction-signals)
- [ ] 1.6.1 Implement a NEW NATS JetStream producer publishing `signals.causal.predictions.{device_uid|incident_id}` with DETERMINISTIC prediction IDs (stable across restarts for the same verdict).
- [ ] 1.6.2 Shape the payload so the existing `CausalSignals` processor (`event_writer/processors/causal_signals.ex`, table `:27`) normalizes it into `ocsf_events` with no new INBOUND plumbing (the `signals.causal.*` prefix already routes to the `bmp_causal` batcher at `pipeline.ex:261-262`).
- [ ] 1.6.3 Verify the in-process `:causal_signal_ingested` broadcast (Phoenix `CausalPubSub`, NOT NATS) still fires so the God-View 4-bucket render path is driven.

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
