## ADDED Requirements

### Requirement: Native prefix snapshot construction

The system SHALL construct prefix-tag snapshots in a packed native trie using
bounded row batches from Elixir and publish an immutable opaque resource through
`:persistent_term`. Elixir SHALL remain the sole owner of snapshot queries and
CNPG connections. The native engine SHALL be the production default; the pure
Elixir engine SHALL remain available for tests and explicit configuration.

#### Scenario: Provider-scale snapshot construction

- **WHEN** a synthetic snapshot with hundreds of thousands of mostly IPv6 prefixes is loaded
- **THEN** the builder stores nodes in native memory without a BEAM map per address bit
- **AND** publication stores a resource reference without copying the tree into the literal area
- **AND** database reads and row conversion use bounded batches

#### Scenario: Unchanged snapshot

- **WHEN** the source's deterministic fingerprint or immutable snapshot token matches the installed snapshot
- **THEN** Elixir retains the current version without calling native construction or publication

#### Scenario: Failed build retains the resident snapshot

- **WHEN** a query, append, or finalization fails
- **THEN** the last complete snapshot remains active and the failure is reported
- **AND** a partial builder cannot become the active snapshot

### Requirement: Native lookup compatibility and resource safety

The native engine SHALL return the full containing chain most-specific first,
including same-prefix VRF variants, existing duplicate-merge semantics, and
structured threat-intel member metadata. It SHALL accept a binary address at the
NIF boundary and return only matching entry maps. Published snapshots SHALL be
immutable, and native panics SHALL return an Elixir error with unwinding enabled
in the shipped build.

#### Scenario: Nested prefixes and VRF variants

- **WHEN** an IP matches nested prefixes and multiple VRFs at one prefix
- **THEN** the result matches the pure Elixir engine's chain, canonical prefixes, ordering, tags, and metadata

#### Scenario: Concurrent publication

- **WHEN** readers retain an old resource while a new snapshot is installed
- **THEN** each reader completes against a valid complete snapshot without a builder lock
- **AND** the old native memory is reclaimed only after its final reference is released

#### Scenario: Contained panic

- **WHEN** a native build operation panics
- **THEN** the NIF returns an error, the VM survives, and the failed builder cannot be published

### Requirement: External prefix snapshots belong to ingestion nodes

The system SHALL materialize provider and threat-intel tries only on ingestion
nodes. Web nodes SHALL NOT build these sources on boot, retries, invalidation,
or explicit source refresh. Peer joins SHALL NOT rebuild external tries.
Authorized settings previews SHALL continue to work through core lookup or an
explicit local-only preview, without treating an unavailable core as an empty
external match. Stored flow readers SHALL NOT re-enrich historical rows.

#### Scenario: Web node boot and invalidation

- **WHEN** a web node boots or receives provider or threat-intel invalidation
- **THEN** it does not execute those sources' trie-build paths

#### Scenario: Preview with core unavailable

- **WHEN** an authorized user requests an effective IP preview and no core lookup succeeds
- **THEN** the UI reports preview unavailability rather than asserting no external tags match

#### Scenario: Flow ingestion after publication

- **WHEN** EventWriter receives a flow from JetStream after a native snapshot is published
- **THEN** source and destination tags, provenance, and provider fields are derived at ingest using the resident trie
- **AND** the configured telemetry backend receives the enriched row without changing its storage routing
