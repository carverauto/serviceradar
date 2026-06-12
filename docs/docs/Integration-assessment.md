# ServiceRadar to DeepCausality Integration Assessment

> **Method:** strict first-principles derivation from the existing CNPG schema
> and AGE topology graph. Every causaloid in §3 reduces to `A ∧ B → C` where A
> and B are present in the database today. Gaps are listed in §3.7 and treated
> in depth in the companion document
> [unblock-capabilities.md](./unblock-capabilities.md), which ranks them by
> cross-domain capability and gives concrete close-out steps for each.
> Architecture and roadmap follow in §4 and §5.
>
> **Schema snapshot:** 224 tables in `platform`, 475 indexes, 49 views, a
> 13,950-line baseline plus 201 migrations. Zero hits on
> `redundan|depends_on|capacity|headroom`. AGE edge labels: `CONNECTS_TO`,
> `HAS_INTERFACE`, `MANAGED_BY`, `CANONICAL_TOPOLOGY`, plus auxiliary. Vertex
> types: `Device`, `Interface`.

---

## 0. Executive Summary

A genuinely useful V1 causal engine can ship against the existing data and
graph schema by deriving an ontology from what is observable: network
topology, virtualization containment, the agent/gateway observability
hierarchy, netflow traffic dependencies, MTR shared-path inference, BGP
routing state, and the implicit causal graph already encoded in
`stateful_alert_rules`.

Three additional findings shape the recommendation:

1. **The existing God-View pipeline is the right consumer for engine
   verdicts.** Its 4-bucket classification (`root_cause / affected / healthy
   / unknown`), Roaring-bitmap rendering, and entity-ID canonicalization are
   reusable as-is. The current `god_view_nif` causality stub of 244 lines is
   misplaced and should be extracted into a standalone `rust/causal-engine`
   service. The remaining ~1,800 lines of the NIF (layout, Arrow serde,
   telemetry enrichment) are a legitimate UI accelerator and stay where they
   are.

2. **`ultragraph` (already a dependency) closes most of the V1 graph-algorithm
   surface for free.** Six of thirteen V1 causaloids reduce to library calls,
   including a direct match between `pathway_betweenness_centrality` and the
   MTR shared-hop bottleneck causaloid. Adding articulation-point and bridge
   detection upstream (~200 LOC) closes the last remaining gap and unlocks a
   whole class of standing single-point-of-failure predictions.

3. **Cross-domain bridges dominate gap economics.** The single highest-value
   schema work is closing the service-identity to flow-identity seam (Gap A).
   It bridges netflow, OTEL, service health, and inventory, promoting the
   engine from infrastructure-level reasoning to dependency-aware
   service-level reasoning.

**Recommendation.** Ship V1 as a single-pod fused Rust service
(`rust/causal-engine`) against the existing schema. Consume via
`EmbeddedSrql` plus JetStream. Emit verdicts on `signals.causal.predictions`,
rendered by the existing God-View pipeline. Refactor the misplaced 244 lines
of causality logic out of `god_view_nif` as part of the same change. V1 is a
~2,000-line effort on top of `EmbeddedSrql` and `ultragraph`. Defer scaling,
HA, and the structural-modeling program until V1 is in operators' hands and
real usage drives the priorities.

---

## 1. Current State

### 1.1 The data layer

CNPG is the convergence point for every data path in ServiceRadar. The
`platform` schema holds 224 tables. They are dominated by telemetry
hypertables, OCSF normalization, inventory caches, config and rules, and
virtualization inventory.

What the schema does **not** have, anywhere in 13,950 lines:

- No occurrences of `redundan`, `depends_on`, `capacity`, or `headroom`.
- No structured component entities for physical hosts (PSU, fan, temperature,
  disk). SNMP environmental data lands as anonymous `timeseries_metrics`
  rows.
- No service-to-service dependency edges. Netflow has IP↔IP traffic; OTEL
  has spans; `service_status` knows binary up/down. Nothing connects them.
- No multi-state device or service health. Five booleans live on
  `ocsf_devices` (`is_available`, `is_managed`, `is_compliant`, `is_trusted`,
  `is_active`) and a `service_status.available boolean`. The `health_events`
  table is a transition log with free-text `new_state`. The right shape; no
  controlled vocabulary.

What the schema does have, and where the V1 substrate comes from:

- A working AGE topology graph with `CONNECTS_TO`, `HAS_INTERFACE`,
  `MANAGED_BY`, `CANONICAL_TOPOLOGY`, plus auxiliary edge labels.
  Network-layer adjacency only; no structural edges; solid infrastructure
  with confidence-weighted idempotent upsert.
- One real containment domain: `virtualization_*` tables with hard FK
  relationships from guests to hosts to clusters and to datastores and
  disks.
- Rich telemetry hypertables (`cpu_metrics`, `memory_metrics`, `disk_metrics`,
  `process_metrics`, `timeseries_metrics`, `otel_metrics`, `otel_traces`,
  `netflow_metrics`, `bgp_routing_info`, `bmp_routing_events`, `mtr_traces`,
  `mtr_hops`, `discovered_interfaces`).
- An implicit operator-encoded causal graph in `stateful_alert_rules`,
  `_states`, and `_histories`.
- OCSF normalization (`ocsf_devices`, `ocsf_events`, `ocsf_network_activity`)
  giving uniform field semantics across heterogeneous inputs.

### 1.2 The existing causal integration

The current DeepCausality integration is the `god_view_nif` Rustler NIF in
`elixir/web-ng/native/god_view_nif/`, consumed by:

- **`RuntimeGraph`.** A GenServer that caches an AGE topology projection
  and refreshes it every 30 seconds.
- **`GodViewStream`** (~5,800 lines). Builds nodes and edges with rich
  telemetry (including `capacity_bps`, `flow_pps_ab/ba`, `flow_bps_ab/ba`,
  `protocol`, `evidence_class`, `confidence_tier`), calls the NIF for causal
  classification, builds Roaring bitmaps, and streams snapshots to the UI.
- **`GodViewSnapshot`.** The envelope contract with the 4-bucket causal
  classification (`root_cause / affected / healthy / unknown`).

The NIF totals 3,138 lines. Only 244 of those are actual causal logic
(centrality plus 3-hop BFS, accurately described by the previous integration
doc as "reactive blast-radius classification, not prediction"). The remaining
2,894 lines are legitimate UI infrastructure: layout, Arrow IPC encoding,
telemetry enrichment, and Rustler bindings. The NIF's Cargo.toml
deliberately opts out of the top-level Rust workspace. It isolates itself
from `rust/srql` and any future causal-engine crate.

The architectural diagnosis is direct. The *rendering* side is well-built
and reusable. The *reasoning* side is a stub in the wrong place. The full
DeepCausality stack (`deep_causality`, `_sparse`, `_tensor`, `_topology`,
`ultragraph`) is pulled in to serve 244 lines of stub logic.

---

## 2. V1 Ontology — derivable from today's schema

This is the substrate the V1 engine reasons over. Every concept below is
derivable from §1.1 with no schema changes.

### 2.1 Entities (Layer 1)

| Entity | Source | Identity |
|---|---|---|
| Device | `ocsf_devices`, AGE `Device` vertex | `uid` |
| Interface | `discovered_interfaces`, AGE `Interface` vertex | `interface_id` |
| Agent | `ocsf_agents`, `agent_id` FKs | `agent_id` |
| Gateway | `gateways`, `gateway_id` FKs | `gateway_id` |
| Service | `service_status` / `service_state` tuple `(gateway_id, agent_id, service_name)` | composite |
| VirtCluster / VirtHost / VirtGuest / VirtDisk / VirtDatastore | `virtualization_*` | `id` |
| BGP peer | `bgp_routing_info` | composite |
| MTR path / hop | `mtr_traces` / `mtr_hops` | trace id, hop |
| Flow (IP↔IP:port) | `netflow_metrics` | 5-tuple |
| Stateful alert rule | `stateful_alert_rules` / `_states` | rule id |
| Health-event-emitting entity | `health_events.(entity_type, entity_id)` | polymorphic |

### 2.2 Relationships (Layer 2)

| Relationship | Source | Kind |
|---|---|---|
| `Device HAS_INTERFACE Interface` | AGE | structural |
| `Interface CONNECTS_TO Interface` | AGE | physical |
| `Device MANAGED_BY Device` | AGE + `management_device_id` | operational |
| `Device OBSERVED_VIA Agent` | `ocsf_devices.availability_source_agent_id` | observational |
| `Agent HOSTED_ON Device` | `agent_id` on device + agent identity | operational |
| `Agent REPORTS_TO Gateway` | `gateway_id` on agent | operational |
| `Service RUNS_AS (Agent, Gateway)` | `service_status` columns | operational |
| `VirtGuest RUNS_ON VirtHost` | `virtualization_guests.host_id` | structural |
| `VirtHost MEMBER_OF VirtCluster` | `virtualization_hosts.cluster_id` | structural |
| `VirtHost HAS_DISK VirtDisk` | `virtualization_host_disks.host_id` | structural |
| `VirtGuest USES_DATASTORE VirtDatastore` | provider refs | structural |
| `Flow FROM_IP → TO_IP:port` | `netflow_metrics` | observed traffic |
| `MTR_path TRAVERSES Hop` | `mtr_hops` | observed network path |
| `BGP_peer ADVERTISES Prefix` | `bgp_routing_info` | observed routing |
| `Health transition (entity, t) old→new` | `health_events` | temporal |

### 2.3 Derivable concepts (Layer 3)

**D1. Observability path.** `Device → OBSERVED_VIA → Agent → REPORTS_TO →
Gateway`. The path through which a device's availability is *known*.
Distinct from the device's actual state.

**D2. Containment (virtualization).** `VirtGuest ⊆ VirtHost ⊆ VirtCluster`;
`VirtDisk ⊆ VirtHost`. The one real containment hierarchy in the schema.
Strict FK transitivity.

**D3. Service stack.** `Service → Agent → Device`, reporting via Gateway. A
4-tuple chain with a hard FK at each link.

**D4. Network reachability under current availability.** AGE topology
filtered by `ocsf_devices.is_available = true`. Connected components are
reachability sets. Articulation points are single points of network failure.

**D5. Shared-fate gateway/agent set.** `{Device : Device.gateway_id = G}` is
the set of devices whose observability collapses with G.

**D6. Interface headroom.** `capacity_bps − Σ recent flow_bps` per interface.
The only place in the schema with a real capacity denominator. `capacity_bps`
is a first-class field on God-View edges (`GodViewSnapshot`).

**D7. Observed traffic dependency.** For any destination IP:port D,
`{src IP : flow → D in window W}` is its observed clientele. Pure netflow
derivation; no declaration required.

**D8. Shared-hop dependency.** For MTR traces, `{path : path contains hop
H}`. A hop appearing on K independent traces is a shared dependency.

**D9. BGP reachability surface.** Prefix P announced by peer Pe makes all
destinations in P reachable via that route. Withdrawal removes the
reachability *before* MTR or ping confirms loss.

**D10. State transition history.** From `health_events`, per
`(entity_type, entity_id)`: transition count, mean dwell time per state,
flap rate over window W.

**D11. Operator-encoded causal rules.** Each row of `stateful_alert_rules`
is an `input pattern → state transition` claim. The collection is an
implicit operator-curated causal graph that already exists in the database.

**D12. Confidence-weighted topology.** AGE edges carry `evidence_class`,
`confidence_tier`, and `confidence_reason`. Causaloids weight predictions by
edge confidence: `direct-physical` evidence is stronger than
`inferred-segment`.

**D13. SCC-derived shared-fate classes.** `strongly_connected_components` on
the MANAGED_BY graph. Each SCC is a mutual-management cluster. Properly
configured, each SCC is a single node. Anything larger is a
misconfiguration.

**D14. Dependency-graph cycle detection.** `find_cycle` on any derived
dependency graph (services once Gap A closes; netflow source/dest now).
Cycles are usually bugs.

**D15. Topological cascade order.** `topological_sort` on the dependency
graph gives the natural propagation order. Causaloids evaluate in this
order; a node's verdict is computed only after its dependencies' verdicts
settle.

**D16. Centrality-ranked root-cause priors.** Full-graph
`betweenness_centrality` gives a structural prior over likely root causes.
The engine combines this prior with observed health to rank candidates.

### 2.4 Causaloids deliverable today

Each uses only Layer 1 through Layer 3. No schema change required.

**C1. Virtualization cascade.** `VirtHost.is_available → false ⟹
∀ guest where guest.host_id = host: predict guest.available → false`.

**C2. Datastore loss to guest disk loss.** Same shape as C1, different
containment edge.

**C3. Gateway and agent root-cause classification.** `N devices flip
is_available→false within W, all sharing gateway G ⟹ root cause = G`.

**C4. Management unobservable.** `Device D's MANAGED_BY = M, M unavailable
⟹ D's availability is unknown, not failed`. *Library call:*
`is_reachable(D, M)` over the MANAGED_BY subgraph.

**C5. Articulation-point standing warning.** Articulation points of the
available-filtered topology are single-failure-partition devices. *Library
call:* `articulation_points(directed=false)` after Gap G lands upstream.

**C5b. Bridge-edge standing warning.** Cut edges of the available-filtered
topology are single-link-partition edges. *Library call:* `bridges()` after
Gap G lands upstream. Often more actionable than articulation vertices,
because operators can add redundant links cheaply.

**C6. Interface saturation projection.** `Headroom < threshold AND positive
growth rate over W ⟹ time-to-saturation < T`. Uses D6.

**C7. Service-stack collapse prediction.** Device hosting Agent A degrades,
which ⟹ predict service unavailability for services with `agent_id = A`
*before* the agent reports. *Library call:* `is_reachable` over the
service-stack chain.

**C8. BGP withdrawal to reachability degradation.** `bmp_routing_events`
shows P withdrawn ⟹ predict reachability loss for destinations in P.
*Library call:* `is_reachable` over the BGP prefix-to-destination graph.

**C9. Shared-hop bottleneck.** Hop H exhibits RTT and loss on K or more
simultaneous MTR traces ⟹ predict degradation for flows traversing H.
*Library call:* `pathway_betweenness_centrality(mtr_pathways)`. An exact
algorithm-to-use-case match.

**C10. Traffic-source blast radius.** Destination D unavailable ⟹ predict
failures at source IPs with recent flows to D. *Library call:*
reverse-reachability set of D in the netflow graph.

**C11. Flap-rate precursor.** Entity transition history matches "high flap
rate + increasing degraded dwell time" ⟹ elevated failure probability. Uses
D10.

**C12. Operator-rule promotion.** For each `stateful_alert_rule` in an
active state with inputs trending toward firing: predict imminent
activation. Uses D11. Bootstraps the engine on already-encoded operator
knowledge.

**C13. Discovery-gap vs. failure disambiguation.** `last_seen_time staleness
> expected_polling_interval AND no health event AND no service_status change
⟹ classify as "stale observation"`. Improves alert precision.

### 2.5 Existing library leverage

V1 sits on two mature libraries.

**`EmbeddedSrql`.** The `rust/srql` crate is already deployed as a NIF
dependency. Its production-ready `QueryEngine` opens a CNPG pool and
dispatches across every entity in the schema, including raw openCypher via
`graph_cypher`. The engine consumes via:

```rust
let engine = EmbeddedSrql::new(config).await?;
let result = engine.query.execute_query(req).await?;
```

**`ultragraph`.** `CsmGraph` static-state algorithms cover six of the
thirteen V1 causaloids:

| Causaloid | Ultragraph primitive |
|---|---|
| C4 (mgmt unobservable) | `is_reachable` |
| C5 (articulation-point warning) | `articulation_points` (Gap G) |
| C5b (bridge-edge warning) | `bridges` (Gap G) |
| C7 (service-stack collapse) | `is_reachable` |
| C8 (BGP withdrawal) | `is_reachable` |
| C9 (shared-hop bottleneck) | `pathway_betweenness_centrality` |
| C10 (traffic-source blast radius) | reverse reachability |

The remaining causaloids are not graph problems: C1 and C2 are FK
traversals, C3 is index intersection, C6 is arithmetic, C11 is temporal,
C12 is rule-state monitoring, C13 is timestamp disambiguation.

Ultragraph's `freeze` / `unfreeze` lifecycle matches the V1 engine's
hydration pattern. Build the Context as a `DynamicGraph` from CNPG plus
JetStream deltas. Call `freeze()` before each reasoning tick. Call
`unfreeze()` only when topology actually changes, which is rare and gated
by AGE updates. Published performance: `shortest_path` on 1M nodes and 5M
edges in roughly 482 µs. ServiceRadar topologies are orders of magnitude
smaller.

### 2.6 V1 sizing

With these substrates, V1 is approximately a 2,000 to 2,100-line effort:

| Component | Lines | Purpose |
|---|---|---|
| Hydrator | ~800 | `EmbeddedSrql` snapshot + JetStream subscriber + AGE to `DynamicGraph` |
| Graph layer | ~300 | Thin wrapper exposing V1-relevant projections (MANAGED_BY subgraph, service-stack chain, netflow predecessor graph, MTR pathway list) |
| Causaloids | ~600 | DC `CausaloidGraph` invoking ultragraph queries and applying state-transition rules |
| Emitter | ~200 | `signals.causal.predictions` publisher with deterministic IDs |
| Snapshot persistence | ~200 | Context dump to disk for fast restart |

The work concentrates where it should: in **projection design** (how to
construct the right subgraphs from CNPG and AGE) and **causaloid
composition** (how DC's `CausaloidGraph` wraps the graph queries). The
boilerplate of graph algorithms and SQL access is library-provided.

---

## 3. Identified gaps

These are not blockers for V1. They are the seams where targeted schema or
library work unlocks materially larger causal capability. The companion
document [unblock-capabilities.md](./unblock-capabilities.md) ranks them by
net utility and details how to close each, including identifier matching,
schema diffs, and audit queries.

**Gap A. Service identity to flow identity bridge.** `service_status` knows
service names; `netflow_metrics` knows IP:port. No mapping. Worth checking
whether `otel_traces` or `otel_trace_summaries` carry parent/child span data
that implies service-to-service edges.

**Gap B. `capacity_bps` population coverage.** The field exists in
`GodViewSnapshot` and is contracted on edges. The audit question is
*coverage*: how often is it non-null in production? Likely sourced from
`discovered_interfaces` and/or AGE edge properties projected by
`RuntimeGraph`.

**Gap C. `health_events.new_state` controlled vocabulary.** The transition
log exists; the state alphabet does not. Reasoning over "degraded vs.
failing" requires a controlled vocabulary or enum.

**Gap D. Inverse `MANAGES` edge or index in AGE.** C4 currently resolves
"devices managed by M" via relational lookup. Functional, but two-step on
the graph side. A performance-only ergonomic.

**Gap E. Out-of-band vs. in-band gateway flag.** No marker that a gateway is
on a separate observability network. Without it, C3 can't always
distinguish "gateway down" from "gateway's link down."

**Gap F. Structured component identity for physical hosts.** SNMP polling
of PSU, fan, and temp data lands in `timeseries_metrics` keyed by OID, with
no per-component entity. This is the integration doc's original
"redundancy" pitch. It cannot work today because the substrate isn't
there.

**Gap G. Articulation-point and bridge algorithms in `ultragraph`.**
*Closing upstream.* Tarjan's articulation-point and bridge detection (or a
biconnected-components decomposition that subsumes both) added to
`StructuralGraphAlgorithms`. Roughly 200 LOC. Once landed, C5 and C5b ship
as single library calls, and an entire class of standing
single-point-of-failure predictions becomes available before any of Gaps A
through F close.

---

## 4. Architecture

### 4.1 Engine placement: fused, single pod, in `rust/causal-engine`

A new top-level Rust crate, peer to `rust/srql`, in the workspace. Single
binary. Single pod. Deployed in the Kubernetes namespace alongside the
existing services. The "fused vs. split" question (hydrator and reasoner in
one process vs. two services) is resolved in favor of fused for V1, because
DeepCausality requires in-process Context access for causaloid evaluation.
Splitting would force network-hop serialization on the reasoning hot path.

Module boundaries inside the binary preserve future optionality:

- `context_hydrator`. Owns CNPG, JetStream, and AGE projection.
- `domain_model`. Rust types for V1 entities and relationships.
- `reasoner`. DC `CausaloidGraph` plus causaloid implementations.
- `emitter`. Verdict publisher.
- `snapshot`. Context persistence for fast restart.

The `context_hydrator` to `reasoner` interface is a `ContextStore` trait.
The day a second consumer of the Context appears (a renderer, a second
reasoner), the trait gets a gRPC/NATS implementation and the split happens
without a rewrite. Until then, in-process direct calls.

### 4.2 Data integration: CNPG, JetStream, and scoped CDC

Three feeds, three responsibilities:

- **`EmbeddedSrql` over CNPG.** Bootstrap (current state on cold start),
  on-demand aggregates when causaloids fire (TimescaleDB continuous
  aggregates via `stats:`, `bucket:`, and `rollup_stats:`), and structural
  snapshots (AGE topology via `graph_cypher`).
- **JetStream subscriber.** Live deltas. Subscribes to `signals.causal.>`,
  core-elx-normalized OCSF/event outputs, and `arancini.updates.>` plus
  `siem.events.>` for the existing causal-signal paths. Sub-second reactivity.
- **Scoped CDC via pgoutput.** Closes the gap that not all writers traverse
  JetStream. The edge-agent path (`serviceradar-agent` to `agent-gateway`
  to `core` to CNPG over mTLS gRPC) doesn't publish to JetStream today, so
  device availability transitions and SNMP-derived state need a logical
  replication slot republishing onto `cdc.platform.<table>` subjects.
  Allowlist: `ocsf_devices`, `service_status`, `health_events`,
  virtualization tables, and AGE projection tables. **Do not CDC
  TimescaleDB hypertables.** The engine queries them on demand via SRQL.

### 4.3 Output path: verdicts to the God-View renderer

The engine emits on `signals.causal.predictions`. The existing
`CausalSignals` processor (in
`serviceradar_core/lib/serviceradar/event_writer/processors/`) already
normalizes that subject into `ocsf_events`. From there, the existing
God-View pipeline reads it as additional health signals into the
`(health_signals: Vec<u8>, edges)` vector that drives the 4-bucket
classification and Roaring bitmap rendering.

**Entity-ID alignment is the integration constraint.** The engine and
`RuntimeGraph` must agree on canonical IDs. Reuse `RuntimeGraph`'s
canonicalization. Do not invent a parallel one. If `GodViewStream` clusters
a device into an endpoint-cluster summary node, verdicts on the underlying
device ID will not render against the right node otherwise.

Engine output vocabulary is constrained by the `GodViewSnapshot` envelope
(schema_version 2): verdicts must map cleanly to `root_cause`, `affected`,
`healthy`, and `unknown`. Don't fight the existing contract.

### 4.4 Refactoring `god_view_nif`

The 244-line `core/causality.rs` moves to `rust/causal-engine`. The rest of
the NIF stays. It is a legitimate UI accelerator. Six-step plan:

1. Create `rust/causal-engine` in the top-level Rust workspace.
2. Migrate `core/causality.rs` and its DC dependencies (`deep_causality*`,
   `ultragraph`) into the new crate.
3. Leave `layout`, `arrow_serde`, `telemetry`, `utils`, and Rustler
   bindings exactly where they are.
4. Slim `god_view_nif`'s causality entry point to a ~50-line renderer stub
   that reads verdicts from `ocsf_events` (via the CNPG pool `srql_nif`
   already opens), or subscribes read-only to `signals.causal.predictions`.
5. Drop `deep_causality*` and `ultragraph` from `god_view_nif`'s
   Cargo.toml.
6. Rejoin the top-level Rust workspace by removing the empty `[workspace]`
   blocks in both `god_view_nif` and `srql_nif`, so shared deps (rustler,
   serde, arrow) resolve uniformly.

After the refactor, the monorepo has a single canonical home for causal
abstractions (`rust/causal-engine`), with thin consumers: the NIF for the
UI accelerator, and future Go or CLI consumers via
`signals.causal.predictions` or SRQL queries on `ocsf_events`.

### 4.5 Migration sequencing: incremental and reversible

This ships without breaking the UI:

1. Stand up `rust/causal-engine` in parallel with the existing NIF stub.
   The engine publishes verdicts; the NIF continues to drive the UI. Zero
   risk.
2. Teach `GodViewStream` to consume engine verdicts *in addition to* NIF
   output. Run shadow. Compare side-by-side, alert on divergence.
3. Switch `GodViewStream` to consume engine verdicts as the primary source,
   with NIF as fallback.
4. Demote NIF causality.rs to the renderer stub. Drop DC deps from the NIF
   Cargo.toml.

Each step is independently reversible. The 5,800-line `GodViewStream` is
touched at one point (verdict source). The snapshot contract is unchanged
throughout.

### 4.6 Deferred: scaling and HA

V1 is single-pod. Active/passive with leader election, sharding, and
replicated Context are all deferred. The reasoning:

- The actual hard problem is the ontology, not the scaling profile. Until
  the Context has shape and the engine has measured load, scaling
  decisions are premature.
- Snapshot-to-disk on a periodic timer gives single-pod restart in
  seconds. Operationally this is indistinguishable from active/passive for
  a system without a tight SLA yet.
- The invariants that make scaling-later cheap (deterministic prediction
  IDs, idempotent hydration, module boundary between hydrator and
  reasoner) are roughly 200 lines of discipline, not architecture.

Revisit when (a) a second consumer of the Context appears, (b) cold-start
bootstrap exceeds the deploy SLO and on-disk snapshots aren't enough, or
(c) measured load justifies it. Skip entity-sharding indefinitely. Causal
graphs resist sharding because causation crosses entity boundaries.

---

## 5. Roadmap

Sequenced by leverage-per-effort and gating dependencies.

### Phase 0. Pre-V1 (days)

- **Audit Gap B coverage.** Trace where `capacity_bps` is populated;
  quantify non-null fraction. Cheap, blocks nothing, and sharpens C6
  immediately.
- **Land Gap G upstream in `ultragraph`.** Articulation-point and bridge
  detection (or biconnected-components decomposition). About 200 LOC.
  Unblocks C5 and C5b as library calls in V1.

### Phase 1. V1 ship (weeks)

Goal: a single-pod fused engine running against today's schema, emitting
verdicts the existing God-View pipeline renders.

- Create `rust/causal-engine` in the top-level workspace.
- Implement hydrator, graph layer, emitter, and snapshot persistence.
- Implement C1 through C13 (six of which are ultragraph library calls).
- Stand up the engine in parallel with the existing NIF; shadow comparison.
- Cut over `GodViewStream` to engine verdicts as primary.
- Demote the NIF causality module to a renderer stub; drop DC deps from
  the NIF.

Deliverable: standing predictions for articulation points and bridges
(C5/C5b), virtualization cascade prediction (C1/C2),
management-unobservable suppression (C4), service-stack collapse
anticipation (C7), BGP-withdrawal reachability prediction (C8), MTR
shared-hop bottleneck identification (C9), traffic-source blast radius
(C10), interface saturation projection (C6), flap-rate precursors (C11),
operator-rule promotion (C12), discovery-gap disambiguation (C13), and
gateway/agent root-cause classification (C3). All rendered through the
existing God-View UI with no UI changes.

### Phase 2. Cross-domain inflection (months)

**Close Gap A (service to flow bridge).** This is the qualitative leap.

- Audit `otel_traces` and `otel_trace_summaries` for parent/child span
  data.
- If present, derive service dependency edges from spans and project them
  into the Context as a new entity-relationship layer.
- Upgrade C10 to service granularity. Add the upstream-degradation
  prediction causaloid. Add trace-anchored root-cause identification.
- The engine becomes dependency-aware at the application layer.

### Phase 3. Vocabulary standardization (months)

**Close Gap C.** Audit `health_events.new_state` values in production.
Define a controlled vocabulary. Migrate. Align engine output vocabulary
with input vocabulary. Generalize C11 across entity types.

### Phase 4. Structural-modeling program (multi-quarter)

**Close Gap F.** OpenSpec proposal for structured physical-host components.
SNMP collector work to emit one structured row per PSU, fan, temp, and
disk with a controlled health enum. AGE edge labels for `CONTAINS`. Once
landed, the PSU, RAID, and redundancy-group causaloids the original
integration doc described become writable, now on a substrate that already
reasons across domains.

### Phase 5. Convenience (when convenient)

- **Gap E.** OOB marker for gateways where applicable.
- **Gap D.** Reverse `MANAGES` edge in AGE.

### When to revisit deferred decisions

- **Active/passive HA.** When cold-start bootstrap exceeds deploy SLO, or
  when a second Context consumer appears.
- **Sharding.** Likely never. Causation crosses entity boundaries, and
  causal graphs resist sharding.
- **Standalone hydration service.** When a second consumer of the Context
  ships (renderer, secondary reasoner, agent). Swap the in-process
  `ContextStore` trait implementation for gRPC/NATS. No architectural
  rewrite.

---

## 6. Recommendation

**Ship V1 as a single-pod fused Rust service** in `rust/causal-engine`,
sitting on `EmbeddedSrql` for data access and `ultragraph` for graph
algorithms, emitting verdicts on `signals.causal.predictions`, rendered by
the existing God-View pipeline.

**Pre-V1 work that pays for itself immediately:**

1. Audit Gap B coverage (cheap; sharpens C6).
2. Add articulation-points and bridge detection to `ultragraph` (Gap G;
   roughly 200 LOC upstream; unlocks C5 and C5b as library calls).

**V1 scope** is approximately 2,000 lines. Most of it is ontology
projection and causaloid composition. It is not reimplementation of graph
algorithms or SQL access, both of which are library-provided.

**Refactor the existing `god_view_nif`** as part of the V1 work. Extract
the 244 lines of misplaced causality logic into `rust/causal-engine`.
Leave the 2,894 lines of legitimate UI infrastructure in place. The
migration is incremental and reversible at each step.

**Defer everything else.** Scaling, HA, structural-component modeling, and
the redundancy/PSU/RAID story the original integration doc led with all
wait. The ontology is the project. Scaling decisions without measured load
are premature. The structural-modeling program is genuinely valuable but
genuinely multi-quarter, and benefits from landing on a substrate that
already reasons across domains.

**The cross-domain inflection point is Gap A.** After V1 is in operator
hands and the engine is producing real verdicts against today's substrate,
the next investment is the service-identity to flow-identity bridge. That
is where the engine stops being an infrastructure-level reasoner and
becomes a dependency-aware service-level reasoner, which is the actual
point of having a causal engine in the first place.
