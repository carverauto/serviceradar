# age-graph Specification

## Purpose
TBD - created by archiving change fix-core-elx-agtype-handling. Update Purpose after archive.
## Requirements
### Requirement: AGE Query Execution
The system SHALL execute Apache AGE Cypher queries through Postgrex without type handling errors.

#### Scenario: Interface graph upsert succeeds
- **WHEN** TopologyGraph receives interface data from mapper
- **THEN** the interface node is created/updated in the AGE graph
- **AND** no Postgrex type errors occur

#### Scenario: Link graph upsert succeeds
- **WHEN** TopologyGraph receives link data from mapper
- **THEN** the device and interface nodes are created/updated
- **AND** the CONNECTS_TO relationship is established
- **AND** no Postgrex type errors occur

### Requirement: AGE Result Type Handling
The system SHALL convert AGE agtype results to text format before returning from Postgrex queries.

#### Scenario: Agtype converted to text
- **WHEN** a Cypher query returns agtype values
- **THEN** the results are converted using `ag_catalog.agtype_to_text()`
- **AND** Postgrex successfully decodes the text result

### Requirement: Canonical AGE graph schema access
The system SHALL create and use the `platform_graph` AGE graph for topology projections in a dedicated schema, and the application role SHALL have USAGE/CREATE/ALL privileges on the `platform_graph` schema and own the AGE label tables.

#### Scenario: Graph schema privileges applied
- **GIVEN** the `platform_graph` schema exists and the AGE graph tables are owned by a superuser
- **WHEN** core-elx runs startup migrations
- **THEN** the `serviceradar` role has USAGE/CREATE and ALL on schema `platform_graph`
- **AND** the `serviceradar` role owns AGE label tables in `platform_graph`

#### Scenario: Topology projections target the canonical graph
- **GIVEN** mapper interface or topology data
- **WHEN** projections run
- **THEN** Cypher queries target graph `platform_graph`
- **AND** graph upserts complete without schema permission errors

### Requirement: Canonical Directional Edge Query Shape
The system SHALL project and query canonical topology edges from AGE in a render-ready directional format for GodView.

#### Scenario: AGE returns render-ready directional fields
- **GIVEN** canonical topology edges have been reconciled from mapper evidence
- **WHEN** GodView requests topology edges
- **THEN** each edge result includes `source`, `target`, `if_index_ab`, `if_index_ba`
- **AND** includes directional telemetry fields `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`
- **AND** includes `capacity_bps`, `telemetry_eligible`, and evidence metadata fields used for diagnostics

### Requirement: Reconciler-Owned Edge Arbitration
The system SHALL perform protocol/confidence arbitration for competing edge evidence before persisting/querying canonical AGE edges.

#### Scenario: Competing evidence is resolved in backend
- **GIVEN** multiple evidence records describe the same device pair (for example LLDP, CDP, SNMP-L2, UniFi)
- **WHEN** reconciliation runs
- **THEN** backend selects the canonical edge variant using deterministic arbitration rules
- **AND** AGE stores only the canonical edge for GodView consumption
- **AND** arbitration reason metadata is retained for diagnostics

### Requirement: AGE-authoritative topology read model
The system SHALL treat canonical Apache AGE topology edges as the authoritative source for topology rendering and downstream graph consumers.

#### Scenario: Renderer consumes canonical AGE edges
- **GIVEN** canonical topology edges are projected in AGE
- **WHEN** web topology views are generated
- **THEN** edge construction SHALL use canonical AGE adjacency
- **AND** rendering SHALL NOT require additional identity-fusion heuristics in the UI layer

### Requirement: Evidence-backed stale-edge lifecycle
The system SHALL expire inferred AGE edges when supporting evidence has aged beyond configured freshness windows.

#### Scenario: Stale inferred edge is retracted
- **GIVEN** an inferred edge has no supporting observations within the freshness window
- **WHEN** topology reconciliation runs
- **THEN** the inferred edge SHALL be marked stale and removed from canonical AGE adjacency
- **AND** direct evidence-backed edges SHALL remain unless they are also stale

### Requirement: Deterministic topology reset and rebuild
The system SHALL provide an operator-safe workflow to clear polluted topology evidence and deterministically rebuild AGE topology from fresh observations.

#### Scenario: Cleanup and rebuild produces bounded graph state
- **GIVEN** topology evidence and AGE edges are reset using the documented workflow
- **WHEN** fresh discovery jobs run and ingestion completes
- **THEN** rebuilt AGE adjacency SHALL be derived only from post-reset evidence
- **AND** validation queries SHALL report pre/post counts and unresolved endpoint totals

### Requirement: Confidence-aware topology edge lifecycle
The system SHALL maintain topology edges in AGE with confidence-aware projection and observation freshness controls.

#### Scenario: Idempotent edge upsert with confidence metadata
- **GIVEN** a topology link candidate eligible for projection
- **WHEN** projection runs repeatedly for the same source/target/interface tuple
- **THEN** the AGE edge SHALL be upserted once
- **AND** edge confidence and last-observed timestamp SHALL be updated in place

#### Scenario: Stale projected edge is retired
- **GIVEN** a projected topology edge has not been observed for longer than the configured stale threshold
- **WHEN** topology reconciliation runs
- **THEN** the edge SHALL be removed or marked inactive based on configured retention policy

### Requirement: MTR Path Graph Projection
The system SHALL project MTR trace paths into the `platform_graph` Apache AGE graph as `MTR_PATH` edges between Device or HopNode vertices, enabling topology visualization of network paths discovered by MTR probes.

#### Scenario: MTR path edges created from trace data
- **WHEN** an MTR trace result is ingested by the core system
- **THEN** for each consecutive responding hop pair (hop_n → hop_n+1), an `MTR_PATH` edge is MERGEd in `platform_graph`
- **AND** edge properties include `agent_id`, `avg_rtt_us`, `loss_pct`, `last_seen`, `protocol`
- **AND** hop IPs matching existing Device vertices reuse those vertices
- **AND** hop IPs not matching any known Device create HopNode vertices with `ip`, `hostname`, `asn`, `asn_org` properties

#### Scenario: Stale MTR path edges pruned
- **WHEN** an `MTR_PATH` edge has a `last_seen` timestamp older than the configured TTL (default 24 hours)
- **THEN** the edge is removed from `platform_graph` during the next pruning cycle
- **AND** orphaned HopNode vertices with no remaining edges are also removed

