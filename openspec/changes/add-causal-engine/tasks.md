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
- [x] 0.3.1a NEW module `event_writer/state_change_publisher.ex`: `publish_transition/3` → `signals.state.<table>` via `NATS.Connection.publish/3`; default-disabled (`STATE_CHANGE_EVENTS_ENABLED` env / `:state_change_events_enabled` app env); fire-and-forget app-level NATS publish.
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
- [x] 1.1.3 Heavy integration deps added per-increment: srql + async-nats (1.2); `ultragraph = "0.9"` (1.3/1.4.2 graph causaloids); `deep_causality = "0.13.10"` for the topology `CausaloidGraph` wrapper. `deep_causality_{sparse,tensor,topology}` remain out of V1 until a concrete model needs them.
- [ ] 1.1.4 (partial) Config (envy) + tracing logging + snapshot-restore-on-start wired and a fused tick loop runs; graceful shutdown lands with the real hydrator/NATS in 1.2.

### 1.2 Hydrator — three ingestion feeds (capability: causal-engine) — Feeds 1 + 3 done
- [x] 1.2.1 Feed 1 (current-state snapshot): `ContextHydrator::connect()` builds `EmbeddedSrql` from srql `AppConfig::from_env`, and `current_context()` runs SRQL queries (`in:devices`, `in:services`) via `QueryEngine::execute_query`, mapping result rows into the `Context` (Device/Service). On-demand continuous-aggregate + AGE `graph_cypher` queries land as coverage broadens (1.2b). Unit-tested row mappers.
- [ ] 1.2.2 Feed 2: JetStream subscriber for live deltas on EXISTING causal subjects (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, zen OCSF). (1.2b)
- [x] 1.2.3 Feed 3 (live state-change): `subscriber.rs` core-NATS subscribes `signals.state.>`, parses `StateChangePublisher` envelopes (`delta.rs`) and applies deltas to the shared `Arc<RwLock<Context>>` between `EmbeddedSrql` refreshes. Best-effort/ephemeral — durability comes from the periodic `refresh()`, so NO JetStream stream/consumer/ack is needed for V1 (Phase-2 reactivity/scale concern). The hydrator now holds the shared Context (seed-on-connect + periodic `refresh`), and `current_context()` clones it. TLS-aware `nats::connect` (mTLS) feeds both this subscriber and the emitter. main runs dual cadences (reason tick + refresh tick) via `tokio::select!`.
- [x] 1.2.4 Single-point identity validation: `map_device` skips any device whose `uid` is not a canonical `sr:`-prefixed id (the engine never forks the ID space). Extend to every entity mapper as coverage grows.
- [ ] 1.2.5 Handle endpoint-cluster summary nodes so a verdict on a clustered device does not silently fail to render. (1.2b)

### 1.3 Reasoner — topology causaloids over a frozen DeepCausality graph (capability: causal-reasoning) — DONE (V1)
> V1 SHAPE: the non-topology causaloid logic is plain Rust over the hydrated `Context` (state/metrics/risk). The topology causaloids (C5/C5b/C9/C10) build a DeepCausality `CausaloidGraph` from `Context` `CONNECTS_TO` edges, freeze it, and use the frozen ultragraph-backed graph for structural algorithms. This is independent of the metrics anomaly detector; anomaly/capacity verdicts may feed causal evidence later, but the anomaly engine does not require the topology graph.
- [x] 1.3.1 Graph causaloids build & `freeze()` a DeepCausality `CausaloidGraph` from `Context` CONNECTS_TO edges each tick (`graph.rs`) and retain the existing frozen graph algorithms for C5/C5b/C9/C10.
- [~] 1.3.2 V1 rebuilds+freezes the topology graph per evaluate (cheap at V1 scale); incremental `unfreeze()`-on-topology-change is a Phase-2 scale optimization.
- [x] 1.3.3 Reasoning tick loop: hydrate `Context` → `Reasoner::evaluate` (build/freeze graph, run C1–C13, compose risk) → collect `Verdict`s → emitter (`main.rs` reason tick).

### 1.4 Implement causaloids C1–C13 (capability: causal-reasoning) — DONE
- [x] 1.4.1 Non-graph causaloids over `Context` state/metrics/risk (`reasoner.rs`): C1 (virt host→guest cascade), C2 (datastore→guest-disk cascade), C3 (gateway/agent root-cause, incl. Gap E out-of-band suppression via `GatewayClass`), C6 (interface saturation on capacity-eligible `links` only), C7 (service-stack collapse over `DEPENDS_ON`), C11 (flap-rate precursor), C12 (operator-rule promotion from `operator_rules`), C13 (discovery-gap disambiguation). C8 (BGP withdrawal) reads explicit `bgp_routes` downstream lists.
- [x] 1.4.2 Graph causaloids over the frozen topology graph (`graph.rs` + `reasoner.rs`): C4 (`MANAGED_BY` unobservable), C5 (`articulation_points`), C5b (`bridges`), C9 (`betweenness_centrality`), C10 (`is_reachable` blast radius). C5/C5b/C9/C10 run through the topology `CausaloidGraph` wrapper; each call site notes the algorithm it uses.
- [x] 1.4.3 Verified against pinned `ultragraph 0.9`: `cargo clippy --all-targets -D warnings` + 54 unit tests + `bazel build //rust/causal-engine:{causal_engine_lib,causal_engine_bin,causal_engine_test} --config=ci` (RBE) green. Full C1–C13 set ships together; no upstream gate remains.

### 1.5 Risk composition into C5/C7/C10 (capability: causal-reasoning, inventory-risk-feed) — DONE
- [x] 1.5.1 `device_risk()` composes per-device `ocsf_devices.risk_score` + bounded `pkg_severity` (AGE `pkg_worst_severity`, CVSS ×10) into a 0..=100 risk that RAISES — never lowers — the predicted `Verdict.severity` of C5/C7/C10 for the affected node; the structural classification is unchanged (`raise_severity_to` is monotonic). Unit-tested.
- [x] 1.5.2 Risk is consumed via the `DeviceRiskReducer` MAX-wins `risk_score` (+ the bounded pkg scalar) only; no purl/cpe coordinate-matching here (DELEGATED to `add-cti-signal-coverage`).

### 1.6 Emitter — signals.causal.predictions producer (capability: causal-prediction-signals) — DONE (engine side)
- [x] 1.6.1 `rust/causal-engine/src/emitter.rs`: `Emitter` connects NATS JetStream (`async_nats` 0.48) and publishes one message per verdict on `signals.causal.predictions.<entity>` with a DETERMINISTIC `event_identity` (`pred:<entity>:<classification>`, stable across restarts), awaiting each ack. Unit-tested envelope builder + determinism + subject sanitization.
- [x] 1.6.2 OCSF-compatible envelope (signal_type `causal`; event_type ∈ root_cause/affected/healthy/unknown; `source_identity.entity_uid`; `routing_correlation.topology_keys`) mirrors what `CausalSignals` (`event_writer/processors/causal_signals.ex`) normalizes into `ocsf_events` — the `signals.causal.*` prefix already routes (`pipeline.ex:261-262`), so no new INBOUND plumbing.
- [ ] 1.6.3 Verify (Elixir-side, once verdicts flow end-to-end) the in-process `:causal_signal_ingested` broadcast (Phoenix `CausalPubSub`) still fires so the God-View 4-bucket render path is driven.

### 1.7 Snapshot persistence (capability: causal-engine) — DONE (Context)
- [x] 1.7.1 `snapshot.rs` SnapshotStore: atomic JSON persistence of the `Context` (write-temp + rename); the hydrator saves after each `refresh()`. The topology `CausaloidGraph` is rebuilt/frozen from the persisted `Context` each tick in V1.
- [x] 1.7.2 Restore-on-start: `ContextHydrator::connect(snapshot_path)` loads the snapshot to seed the shared Context instantly, then a best-effort initial refresh overwrites with fresh CNPG state; if CNPG is momentarily down at boot the engine serves the restored snapshot and the refresh tick retries. Live `signals.state.>` deltas keep it current. Unit-tested round-trip.

### 1.8 Inventory-risk-feed seam (capability: inventory-risk-feed) — DELIVERED by the merged endpoint-SBOM feature
- [x] 1.8.1 `endpoint_inventory` DeviceRiskReducer contribution: `ServiceRadar.Inventory.EndpointInventoryVulnerabilityRisk` (inventory/endpoint_inventory_vulnerability_risk.ex) computes a CVSS-derived score from vulnerability-match payloads and calls `DeviceRiskReducer.upsert_contribution(%{source: "endpoint_inventory", source_ref: device_uid, score, active, occurred_at, resolved_at, metadata})` (MAX-wins → `ocsf_devices.risk_score`). Merged from feat/endpoint-sbom-ingestion.
- [x] 1.8.2 `signals.causal.inventory.<event_type>` emission: `EndpointInventoryHistory.publish_package_change_signals` (inventory/endpoint_inventory_history.ex:119) via the causal-signal publisher.
- [x] 1.8.3 Bounded AGE `Device` `pkg_*` scalars: `topology_graph.ex:280-284` SET pkg_worst_severity/pkg_critical_count/pkg_kev_count/pkg_has_unpatched_rce/pkg_risk_summary_at via `project_vulnerability_risk_summary` (no Package vertices/edges — the @-attrs allowlist at :26-30 bounds it).
- [x] 1.8.4 Engine consumes per-device risk via `ocsf_devices.risk_score` (hydrator `map_device` reads it). CVE→CVSS scoring is done by the inventory's vulnerability-match path (D1 resolved: it consumes match payloads — e.g. from add-cti-signal-coverage — and scores them; the engine does not duplicate matching).

### 1.9 Automation-loop closure (capability: observability-signals, causal-prediction-signals) — DELIVERED by the merged endpoint-SBOM feature
- [x] 1.9.1/1.9.2 Inventory causal events drive alerts: `causal_signals.ex` detects inventory rows (`inventory_event_row?`, `signal_type => "inventory"`) and calls `enqueue_inventory_alert_evaluation` → `StatefulAlertEngine`; the existing firing path produces `class_uid:1008` alerts. (If device-scoped incidents are wanted, verify/author a `group_by: ["device.uid"]` rule for the inventory subject — the grouping mechanism + firing path exist.)
- [x] 1.9.3 OCSF `class_uid:2004` vulnerability findings: `causal_signals.ex:28` `@ocsf_vulnerability_finding_class_uid 2004` / `:30` `@ocsf_vulnerability_finding_type_uid 200_401`, split out via `inventory_vulnerability_finding_row?` — inventory-derived risk surfaces as 2004 findings, not only score enrichment.
- [x] 1.9.4 (engine-side) `ocsf_devices.risk_score` + AGE pkg_* scalars composed into C5/C7/C10 — done in task 1.5 (`device_risk` / `Verdict::raise_severity_to`).

### 1.10 god_view_nif refactor — 6 steps (capability: topology-god-view, causal-reasoning)
> Step 1 is reversible/code-only and DONE. Steps 2–6 are deploy-gated and ordered so the live God-View never loses reasoning — see `runbooks/god-view-nif-cutover.md`. Demoting the NIF or dropping its deps before the engine is deployed and proven at parity would blank the God-View overlay, so they follow engine deployment, not this PR.
- [x] 1.10.1 Extracted `core/causality.rs` (`betweenness_scores` + `evaluate_causal_states_with_reasons_impl`, incl. the 3-hop BFS cap) into `rust/causal-engine/src/god_view.rs`, dropping the dead DeepCausality `CausaloidGraph` (built-frozen-but-never-queried). State codes (0=root/1=affected/2=healthy/3=unknown) + reason strings preserved verbatim for an exact shadow diff. 5 unit tests.
- [ ] 1.10.2 (deploy-gated) Demote the NIF to a renderer stub; keep the UI accelerators that STAY: `layout.rs`, `arrow_serde.rs`, `telemetry.rs`, `utils.rs`, `lib.rs` bindings.
- [ ] 1.10.3 (deploy-gated) Drop `deep_causality` and `ultragraph` from the NIF crate (currently `ultragraph = "0.8"`).
- [ ] 1.10.4 (deploy-gated) Rejoin the NIF crate to the workspace by populating the empty `[workspace]` block (sibling `srql_nif` too); re-run `bazel build` for the NIF targets.
- [ ] 1.10.5 (deploy-gated, do FIRST) SHADOW mode: engine verdicts vs NIF verdicts computed in parallel and diffed, no UI cutover, until parity.
- [ ] 1.10.6 (deploy-gated) CUTOVER: God-View render consumes engine `signals.causal.predictions` -> `ocsf_events` -> `GodViewSnapshot` 4 buckets (`@schema_version 2`); retire the NIF reasoning path.

## 2. Phase 2 — Gap A service-flow-bridge (months)

> FUTURE-PHASE (Phases 2–4): captured as spec deltas (`specs/service-flow-bridge`, `specs/health-events`, `specs/device-components` — `openspec validate --strict` passes) with declared cross-proposal dependencies (`add-service-oriented-plugin-monitoring`, `add-device-environmental-snmp-metrics`, `add-structured-hypervisor-storage-enrichment`). They are NOT V1 implementation and several cannot land until their substrate proposals do. The V1 engine already carries the seams: `AttributedFlow`/C10 (Gap A), the 4-bucket `Classification` ↔ health vocabulary (Gap C), and `Contains`/`BackedBy` edges + structural causaloids (Gap F).

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
> ENGINE-READY: C3 already consumes `Device.gateway_class` (`InBand|OutOfBand|Management`) and suppresses OOB/management gateways from data-plane root-cause blame (task 1.4.1). 5.1.1/5.1.2 are the DATA-SOURCE side — a `gateways.network_class` column migration + AGE projection so the hydrator can populate `gateway_class`. Deferred (migration-bearing; the engine no-ops safely with `gateway_class = None`).
- [ ] 5.1.1 Gap E: add `gateways.network_class` enum (`in-band|out-of-band|management`) so causaloids do not treat a management/OOB path as in-band reachability.
- [ ] 5.1.2 Surface `network_class` into the AGE projection / overlay evidence + the hydrator's `map_device` so structural causaloids weight OOB paths correctly.

### 5.2 Reverse MANAGES edge (capability: age-graph)
- [x] 5.2.1 Gap D: `topology_graph.ex` `upsert_managed_by/2` now also MERGEs the reverse `(mgmt)-[:MANAGES]->(child)` edge (additive, mirrors the `MANAGED_BY` MERGE) so the engine can traverse manager -> managed directly. A dedicated AGE edge index is a follow-on optimization (the reverse edge already avoids the full reverse scan).

## 6. Validation

- [x] 6.1 `openspec validate add-causal-engine --strict` → "Change 'add-causal-engine' is valid" (every requirement has ≥1 `#### Scenario:`; exact `## ADDED|MODIFIED Requirements` headers).
- [x] 6.2 `rust/causal-engine` BUILD.bazel mirrors rust/srql (`all_crate_deps`); the new `ultragraph` dep was picked up by `crate_universe` (`Cargo.lock` + `MODULE.bazel.lock` committed). The `god_view_nif`/`srql_nif` workspace rejoin is part of the deploy-gated 1.10.4 (cutover runbook), not this PR.
- [x] 6.3 No new Go/Elixir imports introduced this phase needed BUILD edits (the Phase-0 publisher + Gap D edit are same-module additions; SBOM wiring landed with its own feature). Re-checked.
- [x] 6.4 `bazel build //rust/causal-engine:{causal_engine_lib,causal_engine_bin,causal_engine_test} --config=ci` (RBE/BuildBuddy) green; 54 `cargo test` + clippy `-D warnings` + `cargo fmt --check` green.
- [x] 6.5 Cross-references declared in `proposal.md` (verified present): `add-cti-signal-coverage`, `add-service-oriented-plugin-monitoring`, `add-device-environmental-snmp-metrics`, `add-structured-hypervisor-storage-enrichment`, `add-endpoint-sbom-inventory`, `add-bmp-dual-path-observability`, `refactor-topology-read-model-for-carrier-scale`, `improve-mapper-topology-fidelity`, `add-multipath-topology-discovery`.
