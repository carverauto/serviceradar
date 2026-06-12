# ServiceRadar — Causal Engine Integration Points

> **Audience:** the DeepCausality author + the ServiceRadar team.
> **Question being answered:** *"Can you give me a good point where all the data
> streams come together in ServiceRadar? There must be some kind of data pane
> that has uniform API access."*
>
> **Date:** 2026-05-22 · **Branch:** `staging` · based on a deep-dive of the
> repo at `/home/mfreeman/src/serviceradar`.

---

## TL;DR

**The data plane question has a clean answer; the harder finding is what it
*doesn't* give you.**

1. **The single point where everything converges is the CNPG database**
   (CloudNativePG / Postgres + TimescaleDB + Apache AGE graph + pgvector).
   Anything that arrives over NATS is written to CNPG near-instantly, so there
   is no reason to integrate against NATS — CNPG is the one uniform plane.

2. **The uniform API over it is SRQL** (ServiceRadar Query Language) — and,
   critically for you, **SRQL already exists as an embeddable Rust crate**
   (`rust/srql`, `EmbeddedSrql` / `QueryEngine::execute_query`). A Rust causal
   service can link it directly: no new service, no FFI, no HTTP hop. It covers
   every entity — events, logs, metrics, traces, devices, interfaces, alerts —
   plus raw openCypher into the AGE topology graph.

3. **But the prediction you described is not a data-access problem — it is a
   *model* problem.** "We lost one of two PSUs → redundancy is gone → one more
   fault and the device fails" is causal forward-inference over **structural
   state**: redundancy groups, dependency edges, capacity headroom, multi-state
   health. We audited the schema for exactly that structural state, and **most
   of it does not exist in ServiceRadar today.** SRQL will happily hand the
   engine raw telemetry, binary up/down, and network adjacency — but it cannot
   hand it "these 2 PSUs back each other up," "this service depends on that
   one," or "this cluster is at 85% of capacity," because that data is not
   modeled.

**So the real integration story is a division of labor:** ServiceRadar's data
plane supplies the **observations**; the causal model — the structural
knowledge and the forward-reasoning — has to be **built**, and that is squarely
DeepCausality's job (Context/hypergraph = the structure; causaloids = the
inference). The rest of this document maps both halves precisely and proposes
how they meet.

---

## 1. The convergence point: CNPG, queried via SRQL

ServiceRadar has an Elixir/ERTS control plane and a single Go edge agent. Data
arrives on a few paths (edge-agent mTLS gRPC; bulk-collector NATS JetStream;
causal-signal NATS subjects) — but **every path terminates in one CNPG
database**, and NATS-ingested data is persisted within ~instantly. CNPG is the
system of record; there is no separate "data pane" to find. (Path detail is in
Appendix B for completeness only — you should not need it.)

The CNPG database (schema `platform`) carries:

- **TimescaleDB hypertables** — time-series telemetry: `ocsf_events`, `events`,
  `logs`, `cpu_metrics`, `memory_metrics`, `disk_metrics`, `process_metrics`,
  `timeseries_metrics`, `otel_metrics`, `otel_traces`, `netflow_metrics`,
  `bgp_routing_info`, `bmp_routing_events`, `service_status`,
  `stateful_alert_rule_histories`, `mtr_traces`/`mtr_hops`, plus continuous
  aggregates (rollups).
- **Apache AGE graph** — the canonical network topology (devices, interfaces,
  and the adjacency between them). Projected by
  `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`.
- **pgvector** — embeddings; today used only by the field-survey/RF subsystem.
- **Relational inventory** — `ocsf_devices`, `ocsf_agents`,
  `device_identifiers`, `device_groups`, `virtualization_*` (Proxmox/hypervisor
  inventory), `interface_settings`, etc.

The **uniform semantic model** within CNPG is **OCSF** (Open Cybersecurity
Schema Framework): heterogeneous inputs (syslog, SNMP traps, OTEL logs,
internal health transitions, BMP/SIEM signals) are normalized into
`ocsf_events` / `ocsf_network_activity` / `ocsf_devices` with consistent fields
(`signal_type`, `primary_domain`, `severity`, `source`, correlation keys). A
causal model keyed on OCSF fields is automatically signal-source-agnostic.

---

## 2. SRQL — the uniform API, and how to consume it from Rust

SRQL is the read-only `in:<entity> key:value` query language used everywhere in
the UI. It is the widest API surface in the system. Entity dispatch
(`rust/srql/src/query/mod.rs`) covers `devices`, `device_updates`,
`device_graph`, **`graph_cypher`** (raw openCypher into AGE), `events`,
`bmp_events`, `flows`, `interfaces`, `logs`, `otel_metrics`,
`cpu/memory/disk/process_metrics`, `traces`, `trace_summaries`, `alerts`,
`services`, plus `virtualization_*`, field-survey and wifi entities. It supports
`stats:`, `bucket:`/`agg:` downsampling, `rollup_stats:` over continuous
aggregates, and cursor pagination.

**SRQL comes in three callable forms:**

| Form | Where | Status | Best for |
|---|---|---|---|
| **`rust/srql` crate, embedded** — `EmbeddedSrql::new`, `QueryEngine::execute_query` | Rust library; opens its own CNPG pool | ✅ exists; already a Cargo dep of the SRQL NIF | **A Rust causal service — recommended** |
| **`rust/srql` standalone HTTP server** — `server.rs`: `POST /api/query`, `/translate`, port 8480, x-api-key | Rust axum binary | ⚠️ built + tested but **not deployed** in any manifest | A hard network boundary, if needed |
| **web-ng `POST /api/query`** | Phoenix HTTP, documented in `docs/docs/api-reference.md` | ✅ deployed; the production API | UI + scripts; Ash per-actor authz scoping |

Confirmed embeddable — `rust/srql/src/lib.rs`:

```rust
pub use crate::query::{QueryEngine, QueryRequest, QueryResponse, ...};

pub struct EmbeddedSrql { pub query: QueryEngine }
impl EmbeddedSrql {
    pub async fn new(config: AppConfig) -> anyhow::Result<Self> {
        let pool = db::connect_pool(&config).await?;
        Ok(Self { query: QueryEngine::new(pool, Arc::new(config)) })
    }
}
```

The Elixir `serviceradar_srql` NIF already depends on this crate but uses only
its parse/translate path; the full `execute_query` path is built and unused —
exactly what a Rust consumer wants. For topology, use the `graph_cypher` entity
to run openCypher straight against the AGE graph.

**Not the answer:** `datasvc` / `data_service.proto` (port 50057) is a
JetStream KV + object-store front end — config and blobs, zero telemetry query.
`core_service.proto` is tiny (device/template lookups). Apache Arrow Flight
does not exist. Ignore all three.

➡️ **Recommendation for the data-access layer:** embed the `rust/srql` crate in
a standalone Rust causal service, pointed at CNPG. One decision for the team:
depend on `rust/srql` as an internal library (no stability guarantee yet), or
fund deploying its already-written axum server (port 8480) as a real k8s
service for a stable network boundary.

---

## 3. What "predict failures before they happen" actually requires

This is the part that reframes the project. The prediction is **not** stream
processing — it is **causal forward-inference over current structural state**.
Take your three examples and decompose what each one needs:

| Your example | What the engine must know | Kind of knowledge |
|---|---|---|
| "2 PSUs, 1 just failed — lose the other and the device dies" | The device *has a redundancy group* of 2 PSUs; required = 1; healthy = 1; **headroom = 0** | structural: redundancy group + component state |
| "A disk in a RAID array is degrading" | The array *has N member disks*; tolerable failures = N − min; current failures = M; the array is in a **reduced-redundancy** state | structural: containment + array policy + multi-state health |
| "An already-stressed cluster will stop responding under more traffic" | The cluster has a **capacity**; current load; **headroom = capacity − load**; and that incoming traffic is *directed at it* (a dependency edge) | structural: capacity model + dependency edge |

Every one of these is forward-reasoning over **structure**, not telemetry
volume. The telemetry ("PSU 2 reports failed", "disk read errors rising",
"CPU 85%") is the easy part — it is already in CNPG and SRQL-queryable. The
hard part is the structural model the reasoning runs on:

- **Containment** — device → its components (PSUs, fans, disks, sensors).
- **Redundancy groups** — "these components/nodes back each other up; K of N
  required."
- **Dependency edges** — "service A depends on B", "this workload depends on
  that datastore", "traffic flows X → Y."
- **Capacity & headroom** — a capacity *denominator* for services/clusters/
  devices, against which current load is a *numerator*.
- **Multi-state health** — `healthy / degrading / degraded / reduced-redundancy
  / failed`, not just up/down.

---

## 4. The structural gap — what SRQL can and cannot give the engine

We audited the schema, the AGE graph, the sysmon/SNMP collectors, the alert
system, and the relevant OpenSpec changes specifically for the five structural
needs above. Honest assessment:

| Need | In ServiceRadar today | SRQL-queryable? | Verdict |
|---|---|---|---|
| **Raw telemetry / utilization** (CPU%, mem, disk%, request rates, link bps) | ✅ `cpu/memory/disk/process_metrics`, `timeseries_metrics`, `otel_metrics` | ✅ yes | **Available.** The observation numerators are all there. |
| **Binary availability** (up/down) | ✅ `ocsf_devices.is_available`, `service_status.available` | ✅ yes | **Available**, but binary only. |
| **Network topology / adjacency** | ✅ AGE graph — `Device`/`Interface` vertices; `CONNECTS_TO`, `CANONICAL_TOPOLOGY`, `HAS_INTERFACE`, `MANAGED_BY`, `MTR_PATH`, etc. | ✅ via `graph_cypher` | **Available.** Network adjacency only — see below. |
| **Structured component state** (one row per PSU / fan / disk / array, with a health enum) | ⚠️ Only for hypervisor inventory: `virtualization_host_disks.health`, `virtualization_storage_systems.health` (free-text). Environmental SNMP (PSU/fan/temp) lands as **flat anonymous `timeseries_metrics` rows** — no "PSU #2 of device X" entity. No SMART/RAID for physical hosts. | partial | **Mostly missing.** |
| **Redundancy groups** ("K of N back each other up") | ❌ Nothing. No `REDUNDANT_WITH` edge, no group entity. | — | **Missing.** Largest gap. |
| **Dependency edges** (service→service, workload→datastore, traffic direction) | ❌ Nothing. AGE has only *network* adjacency. `service_status` has no inter-service edges. The "dependency catalog" change is about config delivery, not runtime dependency. | — | **Missing.** |
| **Device→component containment in the graph** | ❌ Components are not graph vertices. | — | **Missing.** |
| **Capacity / headroom** | ⚠️ Raw load only. The *one* real headroom signal is AGE interface edges carrying `capacity_bps` vs `flow_bps`. No capacity attribute on services/clusters/devices. | partial | **Mostly missing.** Engine has the numerator, not the denominator. |
| **Multi-state / degraded health** | ⚠️ Devices & services are binary. Multi-state exists only for *infrastructure* nodes (`health_events`: `healthy/degraded/offline/failing`) and as the God-View `causal_class` overlay. No "reduced-redundancy" state anywhere. | partial | **Mostly missing.** |

**Bottom line:** SRQL gives the engine a complete, uniform feed of
*observations* and *network adjacency*. It does **not** give it the *structural
model* the predictions require. That structure is a genuine net-new gap — there
is neither the schema nor the discovery to populate it today.

There are reusable foundations, though: the AGE graph is solid infrastructure
(idempotent, confidence-aware edge upsert) and can take new edge labels; the
`health_events` table is a working multi-state transition pattern; and two
in-flight OpenSpec changes are near-misses worth steering (see §6).

---

## 5. The division of labor — DeepCausality's half

This gap is not a blocker — it is the natural shape of the integration, and it
maps cleanly onto DeepCausality's own model:

| DeepCausality construct | Carries | Populated from |
|---|---|---|
| **Context / Contextoids** (hypergraph) | the structural world-model: components, redundancy groups, dependency edges, capacity | SRQL observations + AGE topology + operator-declared structure |
| **Hyperedges** | redundancy groups & multi-party dependencies — *a redundancy group is literally a hyperedge* | inferred (e.g. "device exposes 2 PSU OIDs") or declared |
| **Causaloids / CausaloidGraph** | the forward-reasoning: "healthy members < required → predict failure on next loss" | the engine — this is the actual causal logic |

Your three examples in this model:

- **PSU:** a hyperedge linking the device + its 2 PSU contextoids; a causaloid
  evaluates `healthy_members < required_members` → emits a "redundancy lost,
  next fault is fatal" effect.
- **RAID:** a hyperedge over the array's disk contextoids; a causaloid computes
  `tolerable_failures = members − min_members`, `headroom = tolerable −
  current_failures` → "reduced redundancy" / "next failure = data loss."
- **Cluster:** a capacity contextoid + a dependency edge for directed traffic;
  a causaloid computes `headroom = capacity − load` and reasons over projected
  load → "will stop responding under additional traffic."

ServiceRadar's job is to **feed the Context** (and ideally the structure). The
engine's job is the Context graph itself and the causaloid reasoning.

---

## 6. Recommended path

A **hybrid**, so the engine is useful immediately and gets better as
ServiceRadar's model grows:

**Near term — the engine owns its Context.**
Stand up a standalone Rust `causal-engine` service (a new `rust/causal-engine`
crate, or alongside `rust/consumers`). It:
1. Embeds the `rust/srql` crate → pulls current-state observations, binary
   availability, and AGE topology (`graph_cypher`) from CNPG.
2. Builds a DeepCausality **Context** from those observations, plus a
   **structure layer** that is initially **inferred + operator-declared**:
   - inferred — "device exposes N PSU OIDs ⇒ provisional redundancy group of
     N"; "RAID OIDs ⇒ array with member disks";
   - declared — a small operator-facing way to assert redundancy groups,
     service dependencies, and capacities the system can't discover.
3. Runs causaloid forward-inference and emits predictions (predicted failures,
   lost-redundancy warnings, blast radius, explanations).
4. Publishes verdicts onto the existing `signals.causal.>` subject — the
   `CausalSignals` processor already normalizes that into `ocsf_events`, so
   predictions become SRQL-queryable and the God-View overlay can render them
   with no new plumbing.

**Medium term — ServiceRadar grows the structural model, the engine reads it.**
The structure should not live only inside the engine — redundancy, dependency,
capacity, and component health are broadly useful (UI, alerting, inventory).
Recommended schema work, as OpenSpec proposals:
- **Structured environmental components.** Steer
  `add-device-environmental-snmp-metrics` so PSU/fan/temp/sensor polling
  produces **one structured row per component with a health enum**, not flat
  anonymous `timeseries_metrics`. This is the single highest-leverage change.
- **New AGE edge labels** — `CONTAINS` (device→component), `REDUNDANT_WITH` /
  a redundancy-group vertex, `DEPENDS_ON` (service/workload dependency). The
  AGE graph already supports confidence-weighted idempotent upsert.
- **Capacity attributes** on services/clusters/devices, so headroom is a real
  computed quantity rather than operator-set static thresholds.
- **Multi-state health** on devices/services (`add-service-oriented-plugin-
  monitoring` already proposes `OK/WARNING/CRITICAL/UNKNOWN` for checks and
  first-class service targets + bindings — extend it with a
  `reduced-redundancy` state and adopt it on devices).

As each lands, the engine swaps an inferred/declared Context slice for a
queried one — same `EmbeddedSrql` path, no architectural change.

**This also fixes today's causal chokepoint.** The current DeepCausality
integration (`god_view_nif`, see §7) is reactive and receives only a flattened
`Vec<u8>` of health bits. In the target architecture the standalone engine does
the real reasoning and `god_view_nif` is demoted to a thin renderer of
verdicts — the `Vec<u8>` boundary stops being a constraint.

---

## 7. What exists today — current DeepCausality integration

DeepCausality is integrated in **exactly one place**, and understanding its
limits explains the chokepoint above.

- **Crate:** `god_view_nif` — `elixir/web-ng/native/god_view_nif/`. A Rustler
  NIF (`cdylib`) compiled into the **web-ng** Elixir server; runs in-process on
  the BEAM. Not WASM, not a standalone service.
- **Deps:** `deep_causality 0.13.4`, `deep_causality_sparse 0.1.6`,
  `deep_causality_tensor 0.4.1`, `deep_causality_topology 0.5.0`,
  `deep_causality_core 0.0.5`, `roaring 0.11.3`, `ultragraph 0.8.14`.
- **What it does** (`god_view_nif/src/core/causality.rs`): builds a
  `CausaloidGraph` from the AGE topology, but the propagation step is a **stub**
  — root cause is picked by a heuristic (`max_by_key` on betweenness centrality,
  degree), and "blast radius" is a 3-hop BFS. It is **reactive blast-radius
  classification, not prediction.**
- **Input chokepoint:** the NIF entry point takes only
  `health_signals: Vec<u8>` (0=OK, 1=FAIL, 2=unknown, one per node) and
  `edges: Vec<(u32,u32)>`. All signal and structural richness is flattened away
  before it reaches the engine.
- **Data sources:** topology from the AGE graph (polled every 30s); node health
  from device availability only; an event overlay from `bmp_routing_events` +
  `ocsf_events` filtered to `signal_type IN ('mtr','bmp')`.
- **Already-built upstream normalizer:**
  `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex`
  consumes `arancini.updates.>`, `siem.events.>`, `signals.causal.>` and
  normalizes them into `ocsf_events` — this is the seam to publish engine
  verdicts back into.

**Relevant specs:** `openspec/specs/topology-causal-overlays/spec.md`,
`topology-god-view/spec.md`, `observability-signals/spec.md`.

---

## 8. Open questions for the team

1. **SRQL coupling:** depend on the `rust/srql` crate as an internal library,
   or deploy its axum server (port 8480) as a stable network boundary?
2. **Where does structure live?** Confirm the hybrid: engine carries an
   inferred/declared Context now, ServiceRadar grows real schema (components,
   redundancy, dependency, capacity, multi-state health) over time. Who owns
   the operator-declared-structure UX?
3. **Steer the in-flight changes:** `add-device-environmental-snmp-metrics`
   should emit *structured component rows*, not flat metrics, if causal
   reasoning is a goal. `add-service-oriented-plugin-monitoring` is the natural
   home for multi-state service health + dependency-style bindings.
4. **Discovery of redundancy/dependency:** how much can be inferred from SNMP
   (component OID enumeration) and flow data (traffic direction), and how much
   must operators declare?
5. **OpenSpec:** this is a new cross-cutting capability — per repo convention
   (`openspec/AGENTS.md`) it lands as an OpenSpec change proposal before
   implementation, extending `topology-causal-overlays` / `observability-
   signals` and adding new specs for component/redundancy/capacity modeling.
6. **Engine placement & tenancy:** standalone `rust/causal-engine`, run
   per-tenant (tenancy is namespace/account/schema-per-tenant); `god_view_nif`
   demoted to renderer.

---

## Appendix A — key file references

**SRQL (the uniform API)**
- `rust/srql/src/lib.rs` — `EmbeddedSrql`, `QueryEngine` (embeddable entry)
- `rust/srql/src/query/mod.rs` — entity dispatch (what SRQL can query)
- `rust/srql/src/server.rs`, `config.rs` — standalone HTTP server (port 8480)
- `elixir/serviceradar_srql/` — Rustler NIF (parse/translate only)
- `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` — `POST /api/query`
- `docs/docs/srql-language-reference.md`, `docs/docs/api-reference.md`

**Database / data model**
- `elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql` — baseline
- `elixir/serviceradar_core/priv/repo/migrations/` — schema migrations
- `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex` — AGE graph projection
- `platform.virtualization_host_disks` / `virtualization_storage_systems` — the only structured component health today

**Current DeepCausality integration**
- `elixir/web-ng/native/god_view_nif/` — `Cargo.toml`, `src/core/causality.rs`, `src/lib.rs`
- `elixir/web-ng/lib/serviceradar_web_ng/topology/{native,runtime_graph}.ex`
- `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex`

**Relevant OpenSpec**
- `openspec/specs/topology-causal-overlays/spec.md`, `topology-god-view/spec.md`
- `openspec/specs/observability-signals/spec.md`, `openspec/specs/age-graph/`
- `openspec/changes/add-device-environmental-snmp-metrics/` — steer toward structured components
- `openspec/changes/add-service-oriented-plugin-monitoring/` — multi-state service health
- `openspec/changes/add-structured-hypervisor-storage-enrichment/` — structured RAID/storage (unbuilt)

**Not a data API (for clarity)**
- `proto/data_service.proto` — `datasvc`, KV + object store only (port 50057)
- `proto/core_service.proto` — `core`, device/template lookups only

## Appendix B — how data enters CNPG (reference only)

You should integrate against CNPG, not these paths. Listed only so the picture
is complete.

- **Edge-agent path (mTLS gRPC):** `serviceradar-agent` → `agent-gateway` →
  `core` → CNPG. Carries availability/uptime, ICMP sweep, SNMP polling,
  discovery/mapping, sysmon, WASM plugin checks.
- **Bulk-collector path (NATS JetStream, stream `events`):** `flowgger`
  (syslog), `trapd` (SNMP traps), `otel` (OTLP), `flow-collector`
  (NetFlow/sFlow) -> core-elx EventWriter normalization/persistence -> CNPG.
- **Causal-signal path (NATS):** BMP/BGP (`ARANCINI_CAUSAL` stream), SIEM
  (`siem.events.>`), MTR/other (`signals.causal.>`) → `CausalSignals`
  processor → `ocsf_events` / `bmp_routing_events` in CNPG.

All of it is in CNPG within ~instantly of arrival, and all of it is then
SRQL-queryable.
