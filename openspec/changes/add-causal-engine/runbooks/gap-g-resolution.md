# Gap G — RESOLVED by `ultragraph 0.9.0` (no upstream PR needed)

> **Status:** closed. The design docs (`unblock-capabilities.md` / `Integration-assessment.md`)
> described Gap G as "implement the structural algorithms upstream in `ultragraph`," because they
> were written against `ultragraph 0.8` (the version `god_view_nif` pins). On inspecting the
> upstream repo (`github.com/deepcausality-rs/deep_causality`, `ultragraph` crate), the entire Gap G
> surface is **already implemented and published** in `ultragraph 0.9.0` (tagged `ultragraph-v0.9.0`,
> released 2025-08-27, on crates.io). There is therefore **no DeepCausality PR to open**.

## What already ships in `ultragraph 0.9.0`

Verified against the upstream source (real implementations, no `todo!`/`unimplemented!` stubs):

| Need (Gap G) | Upstream symbol | Trait |
|---|---|---|
| Articulation points | `articulation_points()` (undirected view) | `StructuralGraphAlgorithms` |
| Bridges | `bridges()` (undirected view, `(u, v)` with `u < v`) | `StructuralGraphAlgorithms` |
| Biconnected components | `biconnected_components()` | `StructuralGraphAlgorithms` |
| SCCs | `strongly_connected_components()` | `StructuralGraphAlgorithms` |
| Restricted-pathway betweenness (C9) | `pathway_betweenness_centrality(pathways: &[(usize, usize)], directed, normalized)` | `CentralityGraphAlgorithms` |
| Reachability (C4/C7/C8) | `is_reachable(start_index, stop_index)` | pathfinder |
| Freeze/unfreeze lifecycle | `freeze()` / `unfreeze()` | graph evolve |

## ServiceRadar action (no upstream work)

1. New crate `rust/causal-engine` depends on `ultragraph = "0.9"` (tasks.md 1.1.3) — the NIF currently
   pins `0.8`; the `god_view_nif` refactor (1.10) drops its `ultragraph` dep entirely.
2. Implement causaloids C4/C5/C5b/C7/C8/C9 against the existing trait methods (tasks.md 1.4.2).
   - `articulation_points()`/`bridges()` use the **undirected** view — matches `CONNECTS_TO`
     physical-link semantics (C5/C5b).
   - `is_reachable(start_index, stop_index)` for management reachability (C4) and BGP/service
     reachability (C7/C8) — confirm directedness against the engine's subgraph orientation during
     implementation.
   - `pathway_betweenness_centrality(pathways, directed, normalized)` for the MTR shared-hop
     bottleneck (C9); `pathways` are `(start, end)` node-index pairs.

No upstream dependency, no wait: the six graph causaloids are unblocked immediately by the version bump.
