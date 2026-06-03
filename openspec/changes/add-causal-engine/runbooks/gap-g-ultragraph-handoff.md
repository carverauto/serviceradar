# Gap G — upstream `ultragraph` handoff (for the DeepCausality author)

> **Owner:** DeepCausality author (upstream `ultragraph` crate in `deepcausality-rs`).
> **ServiceRadar status:** the six graph causaloids stay stubbed until this lands and is pinned.
> **Decision (2026-06-02):** Gap G is a committed Phase-0 upstream dependency; ServiceRadar does
> not fork `ultragraph` — this is the spec to implement upstream.

## Why

`ultragraph 0.8` (the version the `god_view_nif` causality stub uses today) exposes only
`betweenness_centrality` + `freeze` on the `CentralityGraphAlgorithms` trait. The V1 causal
engine needs structural graph algorithms that are absent. Six of the thirteen V1 causaloids
reduce to single library calls once these land:

| Causaloid | Needs |
|---|---|
| C4 — management-unobservable suppression | `is_reachable` over the MANAGED_BY subgraph |
| C5 — articulation-point standing warning | `articulation_points` |
| C5b — bridge-edge standing warning | `bridges` |
| C7 — service-stack collapse prediction | `is_reachable` over the service-stack chain |
| C8 — BGP-withdrawal reachability degradation | `is_reachable` over the prefix→destination graph |
| C9 — shared-hop bottleneck | `pathway_betweenness_centrality` |

Plus `unfreeze` to complete the freeze/unfreeze lifecycle the engine drives per reasoning tick.

## What to add

A new `StructuralGraphAlgorithms` trait on the frozen `CsmGraph` state, mirroring the existing
`betweenness_centrality(directed, normalized)` API convention (explicit `directed` flag; results
are indices into the same node space):

```rust
pub trait StructuralGraphAlgorithms {
    /// Cut vertices whose removal increases the number of connected components.
    fn articulation_points(&self, directed: bool) -> Result<Vec<usize>, GraphError>;

    /// Cut edges whose removal increases the number of connected components.
    fn bridges(&self) -> Result<Vec<(usize, usize)>, GraphError>;

    /// Biconnected-components decomposition — the most general form; subsumes
    /// both articulation_points and bridges.
    fn biconnected_components(&self) -> Result<Vec<Vec<usize>>, GraphError>;

    /// Whether `target` is reachable from `source` over the (optionally directed) graph.
    fn is_reachable(&self, source: usize, target: usize, directed: bool) -> Result<bool, GraphError>;

    /// Betweenness restricted to a supplied set of observed pathways (e.g. MTR traces),
    /// rather than all shortest paths. Matches the shared-hop bottleneck use case (C9).
    fn pathway_betweenness_centrality(
        &self,
        pathways: &[Vec<usize>],
        normalized: bool,
    ) -> Result<Vec<f64>, GraphError>;
}
```

Plus `unfreeze` on the graph lifecycle (the inverse of the existing `freeze`) so the engine can
return to a mutable `DynamicGraph` when topology actually changes.

## Implementation notes

- One DFS pass over the CSR adjacency (Tarjan's algorithm). The biconnected-components
  decomposition is the most general and can back both `articulation_points` and `bridges`.
- Classical articulation-point/bridge detection is defined on **undirected** graphs, which
  matches ServiceRadar's `CONNECTS_TO` physical-link semantics; keep the `directed` flag for
  reachability where direction matters (MANAGED_BY, BGP prefix→destination).
- Roughly ~200 LOC including tests. No ServiceRadar-side schema or data work; ServiceRadar passes
  its existing `(node_id, edge_list)` and receives back lists of indices into the same node space.

## Tests

Against known graphs: Tarjan's original example, a Petersen graph, a star, a complete graph, and
two disjoint cliques joined by a single bridge. Bench `pathway_betweenness_centrality` against the
existing `betweenness_centrality` for comparison.

## ServiceRadar follow-up once released

1. Pin the `ultragraph` release version in `rust/causal-engine`'s `Cargo.toml` (tasks 0.1.3 / 1.1.3).
2. Un-stub causaloids C4, C5, C5b, C7, C8, C9 against the new trait (task 1.4.2).
3. Adopt `unfreeze` in the reasoner's topology-change path (task 1.3.2).
