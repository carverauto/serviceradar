## Context
Issue #2834 proposes a high-scale, causality-aware topology experience that unifies physical/logical relationships with incident blast-radius visualization. The existing UI has strong charting and topology foundations but lacks a single high-density rendering path and causal overlay model.

## Goals / Non-Goals
- Goals:
  - Provide a single operator view for large topology state with causal blast-radius overlays.
  - Keep causal decision logic server-side and rendering logic client-side.
  - Maintain low-latency interactions through binary transport and GPU-first rendering.
  - Minimize JavaScript main-thread object churn/GC pressure at 100k+ nodes.
  - Deliver the full telemetry atmosphere in phase 1 (topology, causality, flow/health/utilization overlays, and high-density interaction controls).
- Non-Goals:
  - Replacing every existing dashboard in phase 1.
  - Full custom rendering engine from scratch if existing GPU-capable web stack components satisfy SLOs.
  - Introducing multitenancy routing or per-tenant topology partitions.
  - Deferring telemetry atmosphere layers to a later phase.

## Phase 1 Scope Boundaries
- In scope (phase 1):
  - Topology graph rendering at 100k+ scale with Arrow snapshot streaming.
  - Causal blast-radius overlays and explainability surface in the primary God-View UX.
  - Full telemetry atmosphere overlays (flow, health, utilization, and anomaly-highlight layers).
  - Semantic zoom, structural reshape transitions, and interactive filter/selection controls.
  - Wasm-backed local traversal/filter/interpolation for heavy interaction paths.
- Out of scope (phase 1):
  - Predictive "what-if" simulation and autonomous remediation workflows.
  - Full replacement of every legacy page/report outside the God-View surface.
  - Per-tenant partitioning semantics or multitenancy behavior changes.

## Decisions
- Decision: Use versioned binary topology snapshots (Arrow IPC + metadata) as the canonical stream payload.
  - Alternatives considered: JSON/REST snapshots, protobuf-only row payloads.
  - Rationale: minimizes client parse overhead and supports direct typed buffer handling.
- Decision: Use `deck.gl` with WebGPU mode as the default God-View renderer on supported clients.
  - Alternatives considered: canvas-only custom rendering, WebGL-only baseline.
  - Rationale: `deck.gl` provides a mature high-density visualization stack while WebGPU offers the best path for throughput and latency targets.
- Decision: Implement hybrid filtering where backend emits causal state bitmaps and frontend applies visual states.
  - Alternatives considered: backend pre-filtered payload variants, frontend-only causal inference.
  - Rationale: preserves backend authority for causality while retaining interactive UI performance.
- Decision: Encode topology layout/state in Rust via Rustler NIF and pass Arrow-compatible buffers from Elixir orchestration.
  - Alternatives considered: Elixir-side binary packing as the long-term solution.
  - Rationale: Rust provides the required memory/layout control and performance characteristics for 100k+ node workloads.
- Decision: Add a Wasm client compute layer for Arrow buffer operations (filtering/traversal/interpolation), keeping per-node operations out of JavaScript where possible.
  - Alternatives considered: JS-only client compute over Arrow typed arrays.
  - Rationale: reduces GC pressure and frame-time jitter at 100k+ scale while preserving interactivity during heavy updates.
- Decision: Run DeepCausality/UltraGraph analytics on a cloned graph that is frozen for read-only algorithms, while the live reference graph remains mutable.
  - Alternatives considered: freezing the single live graph behind a mutex.
  - Rationale: clone-and-freeze avoids blocking ingestion/mutation paths during analysis windows and prevents dropped update operations.
- Decision: Define explicit "structural reshape" operations that trigger backend recomputation.
  - Alternatives considered: making all reshapes purely client-driven.
  - Rationale: layout/collapse semantics for very large graphs require server-owned topology math.

## UltraGraph Analytics Profile (Phase 1)
- Runtime model:
  - Maintain a continuously mutating reference `UltraGraph` for topology ingestion.
  - On analytics tick, clone the reference graph, `freeze()` the clone, run analytical algorithms, publish derived metrics, and drop the clone.
  - Never freeze the live reference graph in the hot path.
- Supported algorithm set (initial):
  - `betweenness_centrality()` for mission-critical bottleneck ranking and blast-radius amplification weighting.
  - `strongly_connected_components()` for loop domains / fault-island identification.
  - `has_cycle()` and `find_cycle()` for control-plane loop diagnostics.
  - `shortest_path()` / `shortest_path_len()` / `shortest_weighted_path()` for dependency traversal and path impact narratives.
  - `is_reachable()` for directional dependency assertions.
  - `topological_sort()` for DAG-only dependency ordering checks.
- Operational interpretation:
  - A node with extreme `betweenness_centrality` MUST be surfaced as a critical transit bottleneck.
  - If that node transitions to down/degraded, the causal overlay MUST elevate incident severity and expected blast radius accordingly.

## Runtime Graph Layer (Phase 1.1)
- AGE remains canonical storage and mutation source.
- `web-ng` runs a supervised runtime graph cache process that periodically hydrates topology from AGE.
- Runtime cache storage is backed by a Rust NIF resource to reduce BEAM heap churn from repeated large link projections.
- Current implementation:
  - Elixir performs AGE query only and forwards raw graph rows.
  - Rust resource ingests/normalizes AGE rows (`runtime_graph_ingest_rows/2`), owns cached link rows, and serves read access to snapshot builders.
- Completed in Phase 1.1:
  - Hydration and snapshot-build read path run through Rust resource-owned graph structures for topology indexing/normalization.
  - Layout + causal graph topology resolve via resource-backed indexed edge lookup (`runtime_graph_indexed_edges`).
  - Snapshot payload encoding resolves edge topology from the runtime graph resource (`runtime_graph_encode_snapshot`) via shared Rust Arrow encode internals.

## Snapshot Contract (Schema Version 1)
- Transport:
  - Arrow IPC stream payload with two batches: `nodes` and `edges`.
  - Side metadata envelope included per snapshot revision.
- Nodes batch (required columns):
  - `node_index:u32`, `node_id:utf8`, `node_type:utf8`, `x:f32`, `y:f32`, `status_code:u8`, `causal_class:u8`.
- Nodes batch (optional columns):
  - `z:f32`, `severity:u8`, `size:f32`, `color_rgba:fixed_size_binary[4]`.
- Edges batch (required columns):
  - `edge_index:u32`, `edge_id:utf8`, `source_index:u32`, `target_index:u32`, `edge_type:utf8`.
- Edges batch (optional columns):
  - `weight:f32`, `status_code:u8`, `color_rgba:fixed_size_binary[4]`.
- Referential contract:
  - `edges.source_index` and `edges.target_index` MUST reference existing `nodes.node_index` values.
- Metadata envelope (required):
  - `schema_version`, `snapshot_revision`, `generated_at`, `graph_id`, `node_count`, `edge_count`, `bitmap_version`, `bitmap_offsets`.
- Metadata envelope (optional):
  - `flags` map for renderer/runtime hints.
- Versioning rules:
  - Minor-compatible additions are allowed only via optional columns/flags.
  - Required-field changes require a new `schema_version`.
  - Clients MUST reject unsupported versions and keep last accepted revision active.

## Causal Contract (Version 1)
- Class set (required, exhaustive):
  - `root_cause`, `affected`, `healthy`, `unknown`.
- Wire encoding:
  - `causal_class` column uses `u8` codes (`0=unknown`, `1=healthy`, `2=affected`, `3=root_cause`).
- Bitmap contract:
  - Per revision, emit mutually-exclusive bitmaps:
    - `causal.root_cause`
    - `causal.affected`
    - `causal.healthy`
    - `causal.unknown`
  - All node indices MUST be covered by exactly one class bitmap.
- Precedence rule:
  - When multiple signals match a node, assign by precedence:
    - `root_cause` > `affected` > `healthy` > `unknown`.
- Explainability payload (required per node for root_cause/affected, baseline for others):
  - `causal_class`
  - `confidence` (`0.0..1.0`)
  - `signal_categories`
  - `explanations`
  - `model_revision`
  - `evaluated_at`
- UI behavior:
  - God-View details panel always displays class + confidence.
  - Root-cause and affected nodes display signal categories and explanation strings.
  - Unknown nodes display explicit uncertainty/insufficient-evidence messaging.

## Risks / Trade-offs
- Rust NIF and Arrow integration adds complexity and operational debugging overhead.
  - Mitigation: schema versioning, decode validation tests, and strict resource-path contract checks.
- Large graph updates may exceed frame/update budgets on lower-end clients.
  - Mitigation: adaptive level-of-detail and bounded update cadence.
- Wasm integration increases frontend build/runtime complexity.
  - Mitigation: phase rollout with strict perf gates and explicit failure telemetry.
- Causal attribution confidence may vary by telemetry completeness.
  - Mitigation: expose confidence and evidence fields in operator UX.

## Migration Plan
1. Ship backend snapshot and bitmap contract behind feature flag.
2. Ship web-ng God-View reader/renderer with fallback empty/error states.
3. Enable in demo/internal environments and measure SLO compliance.
4. Expand rollout after performance and reliability sign-off.

## Open Questions
- What minimum hardware/browser profile defines supported 60fps behavior?
- What instrumentation thresholds should gate broad rollout after internal/demo validation?

## Performance Validation (2026-02-14)
- Environment:
  - Local Docker Compose CNPG on `localhost:5455` with mTLS certs.
  - `web-ng` runtime connected to the same CNPG.
  - Kubernetes `demo` namespace rollout with `SERVICERADAR_GOD_VIEW_ENABLED=true`.
- Commands executed:
  - `make build-web-ng` (Bazel remote build) -> success for `//docker/images:web_ng_image_amd64`.
  - `mix run` benchmark script invoking:
    - `ServiceRadarWebNG.Topology.GodViewStream.latest_snapshot/0` (20 runs)
    - `ServiceRadarWebNG.Topology.Native.encode_snapshot/8` (synthetic 100k)
    - `ServiceRadarWebNG.Topology.Native.evaluate_causal_states/2` (synthetic 100k)
- Results:
  - DB-backed snapshot build (current dataset, 70 nodes): `p50=14.12ms`, `p95=35.26ms`.
  - NIF Arrow encode (100,000 nodes, 99,999 edges): `33.96ms` (`~4.8MB` payload).
  - NIF causal evaluation (100,000 nodes): `103.23ms`.
  - `demo` authenticated endpoint checks:
    - `/topology` returns `200` for authenticated session.
    - `/topology/snapshot/latest` returns `200` with Arrow payload (`ARROW1` magic) and God-View headers (`x-sr-god-view-*`).
    - Endpoint latency over 20 samples via authenticated session: `p50=197ms`, `p95=213ms`, `max=242ms`.
- Conclusion:
  - Current backend snapshot SLO budgets are met on local representative validation paths.
  - Broad enablement remains gated on production-like browser/GPU frame-time validation under true 100k rendered scenes.
