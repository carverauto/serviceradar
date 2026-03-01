## ADDED Requirements
### Requirement: Layout and Causal Overlay Separation
The topology system SHALL evaluate structural layout and causal state overlays as separate phases.

#### Scenario: Causal update without topology revision
- **GIVEN** a causal signal update arrives and topology revision is unchanged
- **WHEN** the topology snapshot is refreshed
- **THEN** causal classifications SHALL update
- **AND** previously computed topology coordinates SHALL remain unchanged

#### Scenario: Topology revision triggers structural recomputation
- **GIVEN** topology evidence changes and creates a new topology revision
- **WHEN** the snapshot pipeline runs
- **THEN** structural layout SHALL be recomputed for the new revision
- **AND** causal classifications SHALL be recomputed against that revision

### Requirement: Bounded Overlay Update Under Event Bursts
The system SHALL apply backpressure-aware causal overlay updates so high-rate BMP/SIEM events do not require full topology recomputation per event.

#### Scenario: BMP burst coalesces overlay work
- **GIVEN** a burst of BMP events arrives within a short interval
- **WHEN** overlay processing executes
- **THEN** the system SHALL coalesce or batch overlay evaluations within configured bounds
- **AND** snapshot latency objectives SHALL remain within configured limits

### Requirement: AGE-Authoritative Topology Context for Overlays
Causal overlay evaluation SHALL consume AGE-authoritative topology context and SHALL NOT depend on UI-side identity fusion for adjacency reasoning.

#### Scenario: Overlay evaluation uses canonical graph context
- **GIVEN** canonical topology edges are projected in AGE
- **WHEN** causal overlay evaluation executes
- **THEN** adjacency reasoning SHALL use AGE-authoritative topology context
- **AND** overlay state SHALL remain aligned with canonical topology projections

#### Scenario: Unresolved endpoints do not trigger identity collapse
- **GIVEN** causal signals reference endpoints that are unresolved in canonical identity
- **WHEN** overlay state is computed
- **THEN** unresolved references SHALL remain explicit
- **AND** the system SHALL NOT merge identities based only on adjacency heuristics

### Requirement: Atmosphere Layer Causal Contract
God-View atmosphere overlays SHALL consume causal classifications and explainability metadata without forcing structural layout recomputation when topology revision is unchanged.

#### Scenario: Causal-only revision updates atmosphere layers
- **GIVEN** topology revision is unchanged and only causal signal state changes
- **WHEN** God-View refreshes overlay data
- **THEN** atmosphere-layer visual classes SHALL update from causal outputs
- **AND** node coordinates SHALL remain unchanged

### Requirement: prop2.md Traceability Coverage
The change implementation SHALL maintain explicit traceability to actionable `prop2.md` items so no actionable plan step is omitted without an explicit disposition.

#### Scenario: All actionable prop2 items are mapped
- **GIVEN** `prop2.md` contains numbered actionable items in the change traceability artifact
- **WHEN** implementation status is reviewed
- **THEN** each actionable item SHALL map to one or more implementation tasks and requirements
- **OR** SHALL be marked `defer` or `reject` with rationale

#### Scenario: Completion blocked for unmapped items
- **GIVEN** at least one actionable `prop2.md` item has no mapping or disposition
- **WHEN** the team attempts to mark the change complete
- **THEN** the change SHALL be considered incomplete until all items are mapped or dispositioned
