## NEW Requirements

### Requirement: Temporal Context Hypergraph Integration
The system SHALL integrate the `deep_causality` library into a dedicated Rust-based NIF to manage a temporal context hypergraph.

#### Scenario: Registering a temporal event in the hypergraph
- **GIVEN** the `temporal_context_nif` is loaded
- **WHEN** a new NetFlow aggregation bucket is created
- **THEN** the system adds a corresponding node to the temporal context hypergraph
- **AND** the node implements the `TimeIndexable` trait.

### Requirement: Relative Temporal Indexing
The system SHALL provide a uniform interface for accessing nodes relative to their temporal position in the hypergraph.

#### Scenario: Accessing the previous temporal window
- **GIVEN** a node exists for the current time bucket in the hypergraph
- **WHEN** the system requests the node at relative offset `-1` (previous window)
- **THEN** the hypergraph returns the correct previous node via the `RelativeIndexable` trait
- **AND** the access is structurally invariant across different context types.

### Requirement: Continuous Index Updates
The system SHALL continuously update relative indices in the temporal context hypergraph to maintain accuracy as time progresses.

#### Scenario: Periodic index update
- **GIVEN** a set of nodes with relative temporal links
- **WHEN** the periodic update task executes
- **THEN** the hypergraph updates its internal relative indices to reflect the current wall-clock time
- **AND** the `get_relative` accessors reflect the updated temporal state.
