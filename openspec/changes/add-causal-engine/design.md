# Design — add-causal-engine

## Context

ServiceRadar already has a single convergence plane and a uniform query
surface, and that is what makes a causal engine cheap to build now rather than
later.

- **CNPG is the single data plane.** Every data path — edge-agent mTLS gRPC,
  zen-consumer OCSF normalization, mapper topology, inventory, virtualization,
  telemetry hypertables, and the AGE topology graph — converges in the
  `platform` schema in CloudNativePG. There is no second store to reconcile.
- **SRQL is the uniform API over that plane.** `rust/srql` ships
  `EmbeddedSrql::new` / `QueryEngine::execute_query` (rust/srql/src/lib.rs:31-40;
  rust/srql/src/query/mod.rs) and dispatches across every entity, including raw
  openCypher into Apache AGE via the `graph_cypher` entity
  (rust/srql/src/query/graph_cypher.rs). The engine can read current state,
  TimescaleDB continuous-aggregate rollups, and AGE topology snapshots through
  one library, in-process, without bespoke SQL.

**The 244-line stub diagnosis.** The only DeepCausality code that exists today
is a misplaced stub: `src/core/causality.rs` inside the `god_view_nif` Rustler
NIF (elixir/web-ng/native/god_view_nif/, 3,138 LOC total). Of that, 244 lines
are causal logic — `betweenness_scores` (15-66) and
`evaluate_causal_states_with_reasons_impl` (83-244), with a hard 3-hop BFS cap
at line 183. That is reactive blast-radius classification, not prediction, and
it drags the full DeepCausality stack (deep_causality 0.13 / _sparse 0.1 /
_tensor 0.4 / _topology 0.5 / ultragraph 0.8, Cargo.toml:14-21) into a UI
accelerator. The remaining ~2,894 lines (layout.rs 543, arrow_serde.rs 494,
telemetry.rs 352, utils.rs 457, rustler bindings in lib.rs 815) are legitimate
rendering infrastructure and stay where they are. The NIF deliberately carries
an empty `[workspace]` block (Cargo.toml:23, sibling `srql_nif` too) that
isolates it from the top-level Rust workspace.

**Automation-first reframe.** The point of the engine is the automation loop:
events -> alerts -> state enrichment -> prediction. The God-View topology
renderer is one optional consumer, not the center. Verdicts must re-enter the
automation loop. The seam already exists: the `CausalSignals` processor
(elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex)
normalizes the `signals.causal.*` prefix into `ocsf_events`
(pipeline.ex:261-262 routes the prefix to the `bmp_causal` batcher), and
post-insert `ocsf_events` already drive `StatefulAlertEngine.evaluate_events/1`
(stateful_alert_engine.ex:47) into `monitoring.alerts`. So engine verdicts that
land as `ocsf_events` both (a) close the loop into alerts and (b) paint the
God-View graph. The inbound plumbing is done; the greenfield half is the
producer that writes `signals.causal.predictions.*`.

**In-flight neighbors.** Two product-repo efforts compose with this umbrella
and MUST NOT be re-derived here:

- **Attributed flows** (branch `feat/attributed-flow-correlation`, PR ~#3516):
  `ServiceRadar.FlowAttribution` correlates netprobe process attribution
  against NetFlow into `ocsf_network_activity` rows with
  `ocsf_payload.event_type="attributed_flow"`. The published partition is
  always the server `self_partition_id` (B-4 isolation). This is the Phase-2
  Gap-A substrate; the engine consumes it, it does not re-derive it.
- **Endpoint SBOM inventory** (landed migration
  `20260601183000_add_endpoint_inventory_storage`): `endpoint_inventory_scans` /
  `_artifacts` / `_packages`. The inventory-risk feed in this umbrella wires
  these into `DeviceRiskReducer`, but CVE coordinate-matching is delegated.

Companion analysis lives in the product repo at
`docs/docs/Integration-assessment.md`,
`docs/docs/causal-engine-integration-points.md`, and
`docs/docs/unblock-capabilities.md`. This design grounds and corrects those
documents against the codebase.

## Goals / Non-Goals

Goals:

- Ship V1 as a **single-pod fused Rust service** at `rust/causal-engine` (peer
  to `rust/srql`), with the hydrator and reasoner in one process so
  DeepCausality has in-process `Context` access, and a `ContextStore` trait
  preserving a future split.
- Implement causaloids **C1 through C13**, six of which (C4, C5, C5b, C7, C8,
  C9) reduce to `ultragraph 0.9` library calls (the Gap G algorithms already
  ship upstream — see Decision 2).
- **Close the automation loop:** publish `signals.causal.predictions.*` with
  deterministic IDs; rely on the existing `CausalSignals` -> `ocsf_events` ->
  `StatefulAlertEngine.evaluate_events/1` path to turn verdicts into alerts and
  the God-View render simultaneously.
- Author the **inventory-risk feed**: an `endpoint_inventory` contribution into
  `DeviceRiskReducer` (MAX-wins), a `signals.causal.inventory.*` emission, and
  bounded `pkg_*` risk scalars on the AGE `Device` vertex.
- Perform the **`god_view_nif` refactor**: extract `core/causality.rs` into
  `rust/causal-engine`, demote the NIF to a ~50-line renderer stub, drop the
  DeepCausality/ultragraph deps from the NIF, and rejoin the Rust workspace.

Non-Goals (V1):

- **HA / active-passive + leader election, sharding, and a standalone
  hydration service.** Causal graphs resist sharding because causation crosses
  entity boundaries; snapshot-to-disk gives single-pod restart in seconds. The
  `ContextStore` trait keeps the split cheap when a second consumer appears.
- **CVE / package coordinate-matching.** Delegated to `add-cti-signal-coverage`.
  This umbrella consumes only per-device risk via `DeviceRiskReducer` /
  `ocsf_devices.risk_score`; no purl/cpe matching code is authored here.
- **Re-deriving flow attribution.** The attributed-flow correlation (PR ~#3516)
  is composed, not rebuilt. The engine consumes `attributed_flow`
  `ocsf_network_activity` rows in Phase 2 (Gap A / service-flow-bridge).
- A new INBOUND NATS path. The `signals.causal.*` prefix is already routed;
  only the PRODUCER half is greenfield.

## Decisions

### Decision 1 — Live state deltas via app-level NATS change-events, not pgoutput CDC

The engine subscribes to `signals.state.<table>` subjects to which core-elx
publishes **application-level state TRANSITIONS** for `ocsf_devices`,
`service_status`, and `health_events` (plus virtualization and AGE-projection
state). This is emitted by application code at the point of transition, not by
logical replication.

Rationale: not all writers traverse JetStream today — the edge-agent path
(`serviceradar-agent` -> `agent-gateway` -> `core` -> CNPG over mTLS gRPC) does
not publish to JetStream, so availability and SNMP-derived transitions would
otherwise be invisible to the live feed. Publishing transitions from the same
code that writes them gives a semantic, already-canonicalized delta with the
old->new state in hand, and never touches TimescaleDB hypertables (queried
on-demand via SRQL).

Alternatives considered:

- **pgoutput logical replication / a CDC slot republishing to
  `signals.state.<table>`** (what the Integration-assessment originally
  proposed). Rejected: no logical replication exists today; a slot adds
  operational surface (slot lag, WAL retention, schema-drift coupling) and
  emits row images without transition semantics, forcing the engine to diff
  state it does not hold. It also risks accidentally streaming hypertables.
- **SRQL polling on a timer.** Rejected for the live path: it trades
  sub-second reactivity for poll latency and load, and cannot observe
  short-lived transitions between polls. SRQL is retained for cold-start
  bootstrap and on-demand aggregates, not for liveness.

### Decision 2 — Gap G is already resolved upstream: depend on `ultragraph 0.9`

UPDATED 2026-06-02 after inspecting the upstream repo. `ultragraph 0.9.0`
(tagged `ultragraph-v0.9.0`, published to crates.io, released 2025-08-27)
ALREADY ships the full Gap G surface with real implementations:
`StructuralGraphAlgorithms` (`strongly_connected_components` /
`articulation_points` / `bridges` / `biconnected_components`),
`pathway_betweenness_centrality(pathways, directed, normalized)`,
`is_reachable`, and `unfreeze`. The "committed upstream PR" framing was an
artifact of the design docs being written against the `0.8` the NIF pins. The
ServiceRadar action is therefore a one-line dependency bump (`ultragraph =
"0.9"` in `rust/causal-engine`); the six graph causaloids (C4, C5, C5b, C7, C8,
C9) are unblocked immediately, with no upstream PR and no wait. Alternative now
moot: filing the upstream PR / shipping a 0.8 subset.

Rationale: these primitives unlock an entire class of standing
single-point-of-failure predictions (articulation points, bridges) and the
management/service/BGP reachability suppressions. Reimplementing them
in-crate would fork algorithm maintenance away from the library that already
owns the CSR representation.

Alternatives considered:

- **Ship V1 against the 0.8 subset** (centrality only), deferring the six graph
  causaloids. Rejected: C5/C5b are among the highest-leverage V1 deliverables
  and C4/C7/C8 are reachability suppressions that materially improve alert
  precision; launching without them guts the value proposition.
- **Vendor a private Tarjan implementation inside `rust/causal-engine`.**
  Rejected: duplicates graph state outside the CSR `CsmGraph`, diverges from
  upstream, and is the same ~200 LOC better placed in the shared library.

### Decision 3 — CVE coordinate-matching delegated; this umbrella consumes a thin risk substrate

Package<->CVE matching is owned by `add-cti-signal-coverage`. This umbrella
consumes per-device risk only via `DeviceRiskReducer` /
`ocsf_devices.risk_score` and composes that scalar into risk-aware causaloids
(C5/C7/C10).

Rationale: coordinate matching (purl/cpe normalization, CVE feed correlation)
is a large, separately-evolving concern with its own data feeds. Coupling it
into the causal engine would entangle two release cadences and duplicate
matching logic.

Alternatives considered:

- **Author CVE matching here** to make the engine self-contained. Rejected:
  scope creep across an unrelated capability boundary; `DeviceRiskReducer`
  (device_risk_reducer.ex; MAX-wins, `normalize_score` clamps 0-100 at :179)
  already provides a clean per-device aggregation point.
- **No risk signal at all in V1.** Rejected: device risk is a cheap, available
  prior that sharpens root-cause ranking; the seam is a few contribution rows,
  not a matcher.

### Decision 4 — The inventory->engine seam is authored in this umbrella, not in the SBOM change

This umbrella authors: an `endpoint_inventory` contribution into
`DeviceRiskReducer` (MAX-wins), a `signals.causal.inventory.*` emission, and
bounded `pkg_*` risk scalars on the AGE `Device` vertex (NO package
vertices/edges).

Rationale: the SBOM change (`add-endpoint-sbom-inventory`) owns the inventory
TABLES (landed). The seam that turns inventory into a causal signal is engine
concern — it is where risk enters reasoning. `DeviceRiskReducer` is currently
wired only to `sync_ingestor.ex` and `bumblebee_ingestor.ex`, not to endpoint
inventory; this umbrella closes that gap.

Alternatives considered:

- **Put the contribution wiring in `add-endpoint-sbom-inventory`.** Rejected:
  that change would then need to know the engine's risk-composition contract;
  keeping the seam here keeps the inventory change a pure storage capability.
- **Project package vertices/edges into AGE.** Rejected: unbounded fanout that
  conflicts with the carrier-scale render contract
  (`refactor-topology-read-model-for-carrier-scale`). Bounded scalar
  properties (`pkg_*`) on the existing `Device` vertex carry the signal without
  growing the graph.

### Architecture decisions

- **Fused single pod.** Hydrator and reasoner in one process; DeepCausality
  requires in-process `Context` access for causaloid evaluation, and splitting
  would put network-hop serialization on the reasoning hot path. Modules:
  `context_hydrator`, `domain_model`, `reasoner`, `emitter`, `snapshot`.
- **`ContextStore` trait** sits between hydrator and reasoner. In-process direct
  calls today; the day a second Context consumer appears the trait gets a
  gRPC/NATS implementation and the split happens without a rewrite.
- **Canonical-ID reuse.** The engine reuses the canonical `sr:`-prefixed entity
  IDs (`RuntimeGraph.canonical_runtime_id/1`, runtime_graph.ex:640-650) with
  single-point validation at ingestion. `ocsf_devices.uid` == AGE `Device.id`
  == `ocsf_events.device.uid`. The engine MUST NOT invent a parallel ID space,
  and MUST handle endpoint-cluster summary nodes (a verdict on a clustered
  device id will not render if `GodViewStream` summarized it).
- **Deterministic prediction IDs.** The emitter publishes
  `signals.causal.predictions.{device_uid|incident_id}` with deterministic
  prediction IDs so re-emission is idempotent across restarts and shadow runs,
  and so `ocsf_events` normalization de-duplicates rather than fans out.
- **Snapshot-to-disk.** Periodic `Context` dump gives single-pod restart in
  seconds, which is operationally indistinguishable from active/passive for a
  system without a tight SLA, and removes HA from V1 scope.
- **freeze / unfreeze lifecycle.** Build the Context as a mutable graph from
  CNPG + JetStream deltas; `freeze()` to the CSR `CsmGraph` before each
  reasoning tick; `unfreeze()` only when topology actually changes (gated by
  AGE updates), which is rare. Reasoning runs against the frozen CSR.

## Risks / Trade-offs

- **Gap G (resolved).** Originally a sequencing risk (six causaloids gating on
  an upstream ultragraph release). RESOLVED: `ultragraph 0.9.0` already ships the
  structural + pathway-betweenness algorithms (Decision 2), so the only remaining
  action is a dependency bump — no upstream wait, no degraded launch.
- **Carrier-scale render-contract conflict.** The engine must align with the
  bounded, backbone-centric snapshot of
  `refactor-topology-read-model-for-carrier-scale` and must NOT reintroduce
  unbounded fanout (this is why inventory risk is a scalar, not package
  vertices). Mitigation: declare that change as a render-contract dependency;
  verdicts target the same canonical/summary node identity the read model
  emits.
- **Endpoint-cluster summary id mis-render.** A verdict keyed on an underlying
  device id will not paint if `GodViewStream` clustered that device into an
  endpoint-cluster summary node. Mitigation: route verdicts through
  `RuntimeGraph` canonicalization and resolve to the summary id when one exists;
  add a shadow-phase divergence check for unrendered verdicts.
- **Change-event ordering / at-least-once.** App-level `signals.state.<table>`
  events are at-least-once and may arrive out of order. Mitigation: transitions
  carry old->new + a monotonic marker; the hydrator applies them idempotently
  against current Context state and reconciles against periodic SRQL snapshots
  so a missed or stale delta self-heals.
- **Verdict feedback loops.** Engine verdicts become `ocsf_events` that feed
  `StatefulAlertEngine`, which could in principle re-trigger inputs the engine
  reasons over. Mitigation: deterministic prediction IDs + idempotent
  normalization prevent amplification; engine inputs exclude its own
  `signals.causal.predictions.*` output class; alert `group_by device.uid`
  rules and cooldown/renotify damp oscillation.

## Migration Plan

The `god_view_nif` cutover is incremental and reversible at each step
(Integration-assessment §4.5). The 5,833-line `GodViewStream` is touched at one
point (verdict source); the `GodViewSnapshot` contract (4 buckets, schema_version
2) is unchanged throughout.

1. **Stand up `rust/causal-engine` in parallel.** New top-level crate; engine
   publishes `signals.causal.predictions.*`; the existing NIF stub continues to
   drive the UI. Zero risk to the current render path.
2. **Shadow.** Teach `GodViewStream` to consume engine verdicts *in addition
   to* NIF output. Compare side-by-side and alert on divergence (especially
   unrendered verdicts from cluster-summary id mismatches).
3. **Switch primary with NIF fallback.** `GodViewStream` consumes engine
   verdicts as the primary source, NIF output as fallback. Reversible by
   flipping the source back.
4. **Demote and detach the NIF.** Reduce `core/causality.rs` to a ~50-line
   renderer stub that reads verdicts from `ocsf_events` (via the CNPG pool
   `srql_nif` already opens) or subscribes read-only to
   `signals.causal.predictions`; drop `deep_causality*` and `ultragraph` from
   the NIF Cargo.toml; remove the empty `[workspace]` blocks in `god_view_nif`
   and `srql_nif` so the NIF rejoins the top-level workspace and shared deps
   (rustler, serde, arrow) resolve uniformly.

After the refactor there is a single canonical home for causal abstractions
(`rust/causal-engine`) with thin consumers: the NIF as a UI-accelerator
renderer, and future Go/CLI consumers via `signals.causal.predictions` or SRQL
queries on `ocsf_events`.

## Open Questions

- **`device_fleet_ordinals` ownership.** CSR indexing and roaring-bitmap
  rendering both need a stable dense ordinal per device. Does the engine own
  the ordinal assignment for its CSR (and publish it), or does it consume an
  ordinal space owned by the read model / `GodViewStream`
  (Native.build_roaring_bitmaps, god_view_stream.ex:5160)? Ordinals must agree
  or verdicts mis-index against the bitmap layer.
- **`signals.causal.predictions` leaf-subject granularity.** Leaf on
  `device_uid` vs `incident_id` vs both — what is the canonical leaf for
  de-duplication and for the `CausalSignals` processor's normalization, and how
  do incident-scoped (multi-device) verdicts key deterministically?
- **NIF renderer stub data path.** After demotion, does the ~50-line stub read
  `ocsf_events` via the `srql_nif` CNPG pool (pull, consistent with current NIF
  DB access) or subscribe read-only to `signals.causal.predictions` (push,
  lower latency, new NATS dependency in the NIF)? Trade reuse of existing pool
  plumbing against render latency.
- **Coordination ordering with `refactor-topology-read-model-for-carrier-scale`.**
  Which lands first? The engine's verdict identity must align with that change's
  bounded snapshot node identity; if the read model reshapes node identity
  after the engine ships, verdicts could mis-target until re-aligned.
- **Per-tenant engine deployment topology.** Today single-tenant. When
  multi-tenant: one engine pod per tenant (clean Context isolation, more pods)
  vs one engine with tenant-scoped Contexts (fewer pods, shared blast radius,
  cross-tenant isolation burden on the hydrator). The `ContextStore` trait and
  partition isolation (B-4) inform this but do not decide it.
