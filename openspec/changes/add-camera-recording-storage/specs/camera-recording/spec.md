## ADDED Requirements

### Requirement: Independent recording lifecycle on shared ingest
The system SHALL support authorized recording policies that reuse the existing
camera/profile ingest and retain a recorder lease independently of viewer leases.

#### Scenario: Last viewer leaves
- **WHEN** the last viewer disconnects while recording is active
- **THEN** recording SHALL continue under its recorder lease
- **AND** adding another viewer or analysis branch SHALL not open a duplicate upstream source

#### Scenario: Recorder overload
- **WHEN** recording exceeds its resource budget
- **THEN** admission/backpressure SHALL remain bounded and expose a recording gap
- **AND** recorder failure SHALL not block the existing live viewer path

### Requirement: Verified segmented recording publication
The system SHALL publish seekable recording intervals only after finalized,
bounded media objects pass integrity checks and an idempotent recording-index
transition marks them available.

#### Scenario: Crash during publication
- **WHEN** the recorder restarts after upload but before index publication
- **THEN** reconciliation SHALL verify and publish the existing segment or classify it as an orphan
- **AND** retry SHALL not create duplicate timeline entries or advertise partial media

#### Scenario: Source reconnect or codec change
- **WHEN** the capture stream reconnects, changes codec configuration or cannot provide a valid keyframe
- **THEN** the timeline SHALL retain an explicit discontinuity, unsupported interval or gap
- **AND** the recorder SHALL not accumulate an unbounded segment or invent clock continuity

### Requirement: Separate recording metadata, media and telemetry stores
Recording policy/index state SHALL reside in CNPG/Ash, durable media SHALL reside
in deployment-configured object storage, and recording telemetry SHALL traverse
JetStream/EventWriter into the configured telemetry backend without plugin-selected sinks.

#### Scenario: Plugin registers a camera
- **WHEN** an authorized plugin emits a camera descriptor
- **THEN** the platform SHALL resolve media routing and storage policy
- **AND** camera credentials SHALL use the unified credential model
- **AND** media bytes SHALL not be embedded in plugin result JSON, telemetry tables or Dgraph
