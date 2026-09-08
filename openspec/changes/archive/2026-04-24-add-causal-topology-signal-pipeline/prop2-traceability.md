# prop2.md Traceability Matrix

Source: `prop2.md` (full pass completed across lines `1-1340`)

## Rules
- Every actionable item from `prop2.md` appears below with a unique ID.
- Each item has `Disposition`: `implement`, `defer`, or `reject`.
- `implement` items map to a spec delta and one or more tasks.
- `defer`/`reject` items include explicit rationale.
- No unmapped actionable items are allowed before change completion.

## Disposition Legend
- `implement`: In-scope for this change or directly mapped into related active changes.
- `defer`: Valid direction but deferred to follow-up changes after foundational contracts land.
- `reject`: Conflicts with established ServiceRadar architecture or current accepted direction.

## Exhaustive Item Matrix
| ID | Source Lines | prop2 Topic | Actionable Item Summary | Disposition | Spec Mapping | Task Mapping | Notes / Rationale |
|---|---|---|---|---|---|---|---|
| P2-001 | 31-45, 486-487, 507 | Identity collapse | Remove topology-based group merging (`mergeGroupsByTopologyLinks`) from dedup path | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.1, 4.2 | Core anti-hairball contract |
| P2-002 | 50-52 | UniFi identity | Ensure UniFi poller generates stable device IDs before dedup | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Align with deterministic identity anchors |
| P2-003 | 53-55, 507 | UI pruning | Preserve/strengthen `prune_ap_gateway_inference_edges` behavior | implement | `specs/topology-causal-overlays/spec.md` | `tasks.md` 3.2, 4.3 | Works with evidence-tier policy |
| P2-004 | 76-98 | Device ID functions | Normalize MAC-based IDs and prefix IP fallback IDs (`mac-*`, `ip-*`) | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Deterministic anchor policy |
| P2-005 | 99-119, 510-529 | `isDeviceMatch` | Match by DeviceID + normalized MAC; never fuzzy subnet/IP-only equivalence | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.1, 4.2 | Prevents false merges |
| P2-006 | 123 | Discovery seeding | Seed from gateway/root infrastructure for deterministic traversal | defer | related (`improve-mapper-topology-fidelity`) | future | Operational tuning, not core contract here |
| P2-007 | 137 | Cache reset | Clear mapper completed job cache before verification | defer | n/a | future runbook | Operational step, not spec behavior |
| P2-008 | 139 | Full discovery run | Execute full discovery for validation | defer | n/a | `tasks.md` 4.3 (validation intent) | Verification tactic |
| P2-009 | 148-159, 257-269, 507 | Ping sweeper perf | Replace per-target sweeper creation with shared persistent sweeper | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2, 4.3 | Performance + stability |
| P2-010 | 161-167, 269-271, 490 | RawData contract | Remove `map[string]interface{}` dumping; use typed/structured contracts | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Reduces normalization ambiguity |
| P2-011 | 168-174 | Seed strategy | Move from brute-force seeding to recursive deterministic expansion | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Already aligned with active topology change direction |
| P2-012 | 175-181 | Queue priority | Add infrastructure-first discovery prioritization | defer | related (`improve-mapper-topology-fidelity`) | future | Valuable, but beyond current contract baseline |
| P2-013 | 182-209 | God-engine split | Decompose monolithic `DiscoveryEngine` into pipeline stages/actors | defer | related (`refactor-lldp-first-topology-and-route-analysis`) | future | Broad refactor; track but phase later |
| P2-014 | 215-242 | Device schema | Introduce explicit identity/attributes model in discovery payloads | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Contract-level requirement in scope |
| P2-015 | 243-254 | Pipeline ordering | Enforce identity resolution before topology linking | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.1, 1.2 | Key anti-collapse rule |
| P2-016 | 286-374 | Worker refactor | Refactor worker into prepare/execute/finalize staged pipeline | defer | related (`improve-mapper-topology-fidelity`) | future | Implementation detail not mandatory spec surface |
| P2-017 | 388-411 | Relationship resolver | Centralize relationship resolution and publish only confidence-filtered links | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2, 4.3 | Deterministic topology contract |
| P2-018 | 411, 422-475 | Evidence tiers | Implement explicit confidence ranking (`direct` > `endpoint` > `inferred`) | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Aligns with LLDP-first refactor direction |
| P2-019 | 411 | Interface scope | Mapper interfaces should carry topology identity, not high-rate metrics payload duties | defer | related (`network-discovery`) | future | Architectural cleanup, not blocked for current change |
| P2-020 | 488, 507 | `updateInterfaceDeviceIDs` | Remove/simplify recursive post-hoc ID fixing | defer | related (`improve-mapper-topology-fidelity`) | future | Depends on upstream identity stabilizing refactor |
| P2-021 | 507 | `buildDeviceGroups` | Remove fuzzy grouping by name/IP/MAC blend | defer | related (`improve-mapper-topology-fidelity`) | future | Covered by broader dedup rewrite path |
| P2-022 | 507 | `deduplicateDevices` | Simplify dedup to stable identity-based rebuild | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.1 | Contract-level behavior |
| P2-023 | 507 | `trackJobProgress` | Replace heavy channel tracker with simpler atomic progress | defer | n/a | future | Internal perf refactor; optional |
| P2-024 | 507 | UniFi parser split | Replace global append patterns with staged link returns | defer | related (`refactor-lldp-first-topology-and-route-analysis`) | future | Refactor detail |
| P2-025 | 507 | UniFi uplink helpers | Normalize parent port fields during unmarshal | defer | related change | future | Implementation detail |
| P2-026 | 507 | `querySingleUniFiDevices` split | Separate discovery/interface/topology concerns | defer | related change | future | Broader parser decomposition |
| P2-027 | 507 | Remove `pingHost` | Delete/rework expensive per-target `pingHost` path | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Covered by shared sweeper item |
| P2-028 | 507 | Legacy speed extraction | Remove `extractSpeedFromOctetString` legacy path | defer | n/a | future | Hardware-compat tradeoff requires validation |
| P2-029 | 507 | `scanTargetForSNMP` breakup | Split god-function into identify/enrich/observe phases | defer | related change | future | Valid but large refactor |
| P2-030 | 510-567 | Strict identity rewrite | Update `isDeviceMatch` + `addOrUpdateDeviceToResults` + alias handling | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.1, 1.2, 4.2 | Complements P2-005 |
| P2-031 | 554-567 | `ensureDeviceID` | Deterministic MAC-first ID with explicit soft IP fallback | implement | `specs/network-discovery/spec.md` | `tasks.md` 1.2 | Complements P2-004 |
| P2-032 | 573-622 | Discovery JSON template | Adopt two-tier fast/topology + full/inventory scheduled profile | defer | n/a | future runbook | Deployment-specific tuning guidance |
| P2-033 | 640-642 | Metrics + secrets | Disable mapper metrics collection path and move API key to secret/env | defer | n/a | future hardening | Operational policy item |
| P2-034 | 654-690 | GodView ranking | Add node kind/priority weighting for layout anchoring | defer | related (`topology-god-view`) | future | UI strategy; may conflict with current snapshot contracts |
| P2-035 | 692-709 | Edge stability filter | Prune inferred edges when direct path exists | implement | `specs/topology-causal-overlays/spec.md` | `tasks.md` 3.2, 4.3 | Consistent with layer separation |
| P2-036 | 734-789 | Rust weighted layout | Implement hierarchical weighted layout in Rust NIF | defer | related (`topology-god-view`) | future | Needs compatibility review with existing NIF contracts |
| P2-037 | 821 | Mapper health supervisor | Add GenServer restart behavior if key node disappears | reject | n/a | n/a | Node-specific restart policy is brittle and not canonical behavior |
| P2-038 | 831-843, 864-870 | Root selection change | Replace degree-based root/ring strategy with role/weight-based hierarchical layout | defer | related (`topology-god-view`) | future | Good direction, pending existing layout roadmap alignment |
| P2-039 | 845-852 | Betweenness centrality | Remove per-snapshot betweenness centrality from hot path | defer | related (`topology-god-view`) | future | Perf tuning requires benchmarking in current code |
| P2-040 | 853-858 | Hypergraph overuse | Avoid hypergraph for basic binary L2/L3 layout edges | defer | related (`topology-god-view`) | future | Depends on finalized causal model usage |
| P2-041 | 877-881 | Edge telemetry parsing | Stop JSON parsing in Rust loop; send typed numeric telemetry from producer | defer | related change | future | Data contract adjustment needed |
| P2-042 | 903-909, 930-934 | Layout/logic split | Keep graph/causality for reasoning; use simpler hierarchical layout for geometry | implement | `specs/topology-causal-overlays/spec.md` | `tasks.md` 3.1, 3.2 | Core contract of this change |
| P2-043 | 910-916, 955-992 | Security/BGP hyperedges | Model security zones/BGP groups as causal hyperedges for blast-radius computation | defer | `specs/topology-causal-overlays/spec.md` (future extension) | future | Deferred until base causal ingestion stabilizes |
| P2-044 | 936-945 | Rust node schema | Extend node model with role/BGP/security/health fields | defer | future spec delta | future | Forward-looking data model extension |
| P2-045 | 1015-1022 | Snapshot layering | Evolve snapshot to layered physical/health/context payload | defer | related (`topology-god-view`) | future | Potentially breaking payload change |
| P2-046 | 1036-1057 | Causal signal model | Build categorized causal signals (health/security/routing types) | implement | `specs/observability-signals/spec.md` | `tasks.md` 1.3, 2.3 | In-scope normalization requirement |
| P2-047 | 1063-1084 | Complex causality NIF | Add causality evaluation entrypoint supporting BGP prefix groups | defer | `specs/topology-causal-overlays/spec.md` (future extension) | future | Defer to post-baseline causal phase |
| P2-048 | 1094-1102, 1324-1326 | Event-driven overlays | Process BMP as high-rate events updating overlay state without coordinate churn | implement | `specs/topology-causal-overlays/spec.md` | `tasks.md` 3.1, 3.2, 3.3 | In-scope core behavior |
| P2-049 | 1097, 1106, 1262 | Go mapper as BMP parser | Route BMP through Go mapper/event hub | reject | `specs/observability-signals/spec.md` | `tasks.md` 2.4 (boundary) | Conflicts with canonical risotto -> JetStream -> Broadway path |
| P2-050 | 1209-1214 | BGP group source | Resolve BGP prefix groups for causal overlay evaluation in Elixir | defer | future spec delta | future | Requires authoritative BGP data service integration |
| P2-051 | 1225-1300, 1333 | gRPC streaming BMP/SIEM path | Introduce SignalService server-stream from Go to Elixir | reject | `specs/observability-signals/spec.md` | `tasks.md` 2.4 (boundary) | Conflicts with event-bus ingestion architecture |
| P2-052 | 1301-1322 | Elixir gRPC consumer | Add persistent gRPC consumer in GodView stream process | reject | n/a | n/a | Superseded by Broadway consumer model |
| P2-053 | 1328 | Sub-second target | Achieve low-latency security propagation | implement | `specs/topology-causal-overlays/spec.md` | `tasks.md` 3.3, 4.1 | Captured as bounded-latency objective |

## Coverage Summary
- Total actionable items captured: `53`
- `implement`: `21`
- `defer`: `25`
- `reject`: `7`

## Notes on Duplicates and Conflicts
- `prop2.md` repeats several ideas in multiple variants; each distinct actionable variant is listed once with source-line references.
- Conflicting items were preserved and dispositioned explicitly (not silently dropped), especially around BMP ingestion (`gRPC stream` vs `risotto -> JetStream -> Broadway`).
- Several implementation-heavy refactors are intentionally deferred to avoid overlap/conflict with active changes:
  - `improve-mapper-topology-fidelity`
  - `refactor-lldp-first-topology-and-route-analysis`
  - `add-god-view-topology-platform`

## Deferred Item Group Mapping
- Mapper pipeline/boundary refactors:
  - Follow-up change: `refactor-mapper-discovery-pipeline-boundaries`
  - Item IDs: `P2-006`, `P2-007`, `P2-008`, `P2-012`, `P2-013`, `P2-016`, `P2-019`, `P2-020`, `P2-021`, `P2-023`, `P2-024`, `P2-025`, `P2-026`, `P2-028`, `P2-029`, `P2-032`, `P2-033`
- Topology layout stability/performance refactors:
  - Follow-up change: `refactor-topology-layout-stability-and-performance`
  - Item IDs: `P2-034`, `P2-036`, `P2-038`, `P2-039`, `P2-040`, `P2-041`, `P2-045`
- Advanced causal/hypergraph overlay extensions:
  - Follow-up change: `add-advanced-causal-hypergraph-overlays`
  - Item IDs: `P2-043`, `P2-044`, `P2-047`, `P2-050`

## Completion Gate
- This traceability matrix must stay synchronized with `tasks.md` and spec deltas.
- Change completion is blocked until every `implement` item is either fully delivered or explicitly re-dispositioned with rationale.
