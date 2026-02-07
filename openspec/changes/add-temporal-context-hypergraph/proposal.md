# Change: Add Temporal Context Hypergraph for Relative Comparisons

## Why
The NetFlow observability module requires relative temporal comparisons (e.g., "Compare to Yesterday") to identify unusual traffic spikes and patterns. While basic time-shifted queries are possible, complex relative comparisons across multi-dimensional contexts (topology, service dependencies, etc.) benefit from a structured context hypergraph. This approach allows for structurally invariant and uniform access to relative temporal data, as suggested by the community and implemented in the `deep_causality` library.

## What Changes
- Integrate the `deep_causality` Rust library into the ServiceRadar ecosystem via a new Rustler NIF (`temporal_context_nif`).
- Implement a Temporal Context Hypergraph in Rust that models system relationships and temporal states.
- Implement `Indexable`, `RelativeIndexable`, and `TimeIndexable` traits to provide a uniform interface for accessing temporal data.
- Add a background process (e.g., via Oban or a scheduled task) to continuously update relative indices in the hypergraph.
- Extend the `web-ng` Elixir application to utilize this NIF for relative temporal queries in the NetFlow dashboard.

## Non-Goals
- Replacing TimescaleDB for raw flow storage.
- Real-time causality inference for all network events in the first iteration.

## Impact
- Affected components: `web-ng` (via new Rustler NIF).
- New component: `rust/temporal_context` and `web-ng/native/temporal_context_nif`.
- Data model: Complements existing flow data with a graph-based context layer.

## Risks / Considerations
- Memory overhead: The hypergraph must be memory-efficient as it resides in the NIF's memory space.
- Update latency: The frequency of relative index updates must be balanced with performance.
- Complexity: Introducing a hypergraph model adds architectural complexity; must be well-documented and strictly scoped.
