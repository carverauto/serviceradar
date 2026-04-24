# Design: Temporal Context Hypergraph for Relative Comparisons

## Architecture Overview
The temporal context hypergraph provides a structured way to handle relative temporal comparisons in ServiceRadar. It leverages the `deep_causality` library's indexing traits to provide uniform access to temporal data points across different contexts (e.g., NetFlow, system metrics).

### Components
1. **`temporal_context_nif` (Rust)**: A Rustler-based NIF that wraps the `deep_causality` hypergraph.
2. **Context Hypergraph**: A hypergraph where nodes represent temporal states and edges represent relationships (e.g., "next in time", "same service in previous window").
3. **Relative Accessors**: Structurally invariant interfaces based on specific `deep_causality` indexing traits.
4. **Update Scheduler (Elixir)**: An **AshOban** scheduler that triggers the update of relative indices in the Rust-managed hypergraph.

## Data Model
- **Nodes**: Represent a specific (entity, time_bucket) pair.
- **Hyperedges**: Connect nodes across different dimensions (e.g., all traffic for a specific service over the last 24 hours).
- **Relative Indices**: Each node maintains indices relative to its peers (e.g., `-1` for the same bucket 24 hours ago).

## Implementation Details

### Rust Traits (deep_causality)
We will leverage and implement the following traits from `deep_causality` for our hypergraph nodes to ensure uniform data and time indexing:
- `DataIndexable`: Base trait for data indexing.
- `DataIndexCurrent`: Provides access to the current data index.
- `DataIndexPrevious`: Provides access to the previous data index.
- `TimeIndexable`: Base trait for temporal indexing.
- `TimeIndexCurrent`: Provides access to the current time index.
- `TimeIndexPrevious`: Provides access to the previous time index.

These traits allow the hypergraph to maintain a consistent state of "what is happening now" vs "what happened then" across different data types.

### NIF Interface
```rust
#[rustler::nif]
pub fn add_node(env: Env, data: Term) -> Term { ... }

#[rustler::nif]
pub fn update_indices(env: Env) -> Term { ... }

#[rustler::nif]
pub fn get_relative_value(env: Env, node_id: u64, offset: i64) -> Term { ... }
```

### Update Mechanism
An **AshOban** scheduler (configured in the `core-elx` control plane) will trigger the `update_indices/0` NIF function at regular intervals. This ensures that relative temporal links (like "previous window") are recalculated as the system time advances, maintaining the structural invariance of the accessors.

## Use Case: NetFlow Relative Comparison
1. The UI requests flow data for "Now" and "Yesterday".
2. Instead of two separate expensive SQL queries, the system uses the Temporal Context Hypergraph to identify the relevant comparative nodes.
3. The hypergraph provides the "Yesterday" baseline context, which can be used to overlay data on the UI.

## Performance Considerations
- The hypergraph will be stored in a `rustler::ResourceArc` to persist across NIF calls.
- Construction of the graph should be incremental to avoid large re-computations.
- Memory usage must be monitored, especially with high-cardinality NetFlow data; aggregation will be used at the node level.
