## ADDED Requirements

### Requirement: Graph versions are Dgraph namespaces
The system SHALL version topology by placing each complete graph in its own Dgraph namespace: one live namespace, zero or more snapshot namespaces, and optional scratch namespaces. The system SHALL NOT version edges with valid_from/valid_to on the live graph.

#### Scenario: Live queries do not filter time
- **WHEN** God View or `in:graph` reads topology
- **THEN** the query runs against the live namespace
- **AND** it does not include a valid_from or as_of predicate

#### Scenario: Yesterday is a different namespace
- **GIVEN** a snapshot catalog row for as_of yesterday
- **WHEN** topology at that time is queried
- **THEN** the same canonical-edge DQL runs against that snapshot namespace
- **AND** the live namespace is not mutated

#### Scenario: Namespaces are not joined
- **WHEN** yesterday is compared to today
- **THEN** each namespace is queried separately
- **AND** no DQL statement spans both namespaces

### Requirement: Snapshot catalog
The system SHALL persist an Ash-backed `topology_graph_snapshots` catalog in `platform` mapping `as_of`, reason, and Dgraph namespace id.

#### Scenario: Scheduled snapshot is recorded
- **WHEN** a scheduled snapshot job completes
- **THEN** a catalog row exists with reason `scheduled`, a namespace id, and a content fingerprint
- **AND** the snapshot namespace contains the topology schema

#### Scenario: Snapshots are gated
- **WHEN** the projector runs a heartbeat that does not change any `link_key`
- **THEN** no new Dgraph namespace is created

### Requirement: Scratch namespace for proposed graphs
The system SHALL project a proposed config or change into a scratch Dgraph namespace without writing the live namespace, so a later consumer can diff proposed vs live with the same DQL.

#### Scenario: Dry-run does not touch live
- **WHEN** the dry-run projector is given parsed facts for a proposed config
- **THEN** candidate edges land only in a scratch namespace
- **AND** the live namespace is unchanged
- **AND** the catalog records the scratch namespace as reason `dry_run`

### Requirement: Snapshot retention
The system SHALL expire snapshot and scratch namespaces according to the catalog's retention class and SHALL drop only the named namespace's topology predicates, never `drop_all`.

#### Scenario: Expired snapshot is removed
- **GIVEN** a catalog row whose retention has elapsed
- **WHEN** GC runs
- **THEN** that Dgraph namespace's topology predicates are removed
- **AND** other namespaces remain

### Requirement: Evidence refs on live edges
The system SHALL store on each live `TopologyEdge` the evidence that justified it (mapper key, config revision, and/or change id) so "why is this edge here" does not require opening a snapshot.

#### Scenario: Config-projected edge cites the revision
- **GIVEN** an edge projected from a config revision
- **WHEN** a client reads that edge from the live namespace
- **THEN** its provenance names that `network_config_revisions` id
- **AND** the config body is not stored on the edge

### Requirement: Mutation index is not the graph-at-T
The system MAY record append-only `topology_graph_mutations` rows (`as_of`, `op`, `link_key`, `payload_hash`, `evidence_refs`) as an index for "which edges cite revision R". Graph-at-T SHALL still be answered by a snapshot namespace, not by replaying that index as the product query surface.

#### Scenario: Revision R lookup uses the index
- **GIVEN** mutations whose `evidence_refs` include config revision R
- **WHEN** provenance is queried for R
- **THEN** those `link_key`s are returned
- **AND** reconstructing the full neighbourhood at T uses the snapshot namespace for T
