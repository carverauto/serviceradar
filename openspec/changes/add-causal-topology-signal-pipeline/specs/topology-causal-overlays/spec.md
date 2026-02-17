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
