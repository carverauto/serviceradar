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

### Requirement: Deployment-bounded temporary object staging
Optional JetStream Object Store media staging SHALL require finite byte, age,
object-size and concurrency limits, explicit replicas/placement and an admission
budget that preserves non-media JetStream capacity.

#### Scenario: Staging enabled without a capacity plan
- **WHEN** staging lacks a positive TTL, finite byte cap or sufficient reserved capacity
- **THEN** recording admission SHALL be rejected with an actionable sizing error
- **AND** existing telemetry retention/capacity SHALL remain unchanged

#### Scenario: Archive outage outlasts staging
- **WHEN** an object cannot be archived before its safe upload deadline or admission hits the bucket cap
- **THEN** the system SHALL expose pending pressure and affected lost intervals
- **AND** SHALL not acknowledge archival retention, silently grow the bucket or evict telemetry
- **AND** cleanup SHALL handle incomplete uploads and expired object chunks

### Requirement: Separate recording metadata, media and telemetry stores
Recording policy/index state SHALL reside in CNPG/Ash, durable media SHALL reside
in deployment-configured object storage, and recording telemetry SHALL traverse
JetStream/EventWriter into the configured telemetry backend without plugin-selected sinks.

#### Scenario: Plugin registers a camera
- **WHEN** an authorized plugin emits a camera descriptor
- **THEN** the platform SHALL resolve media routing and storage policy
- **AND** camera credentials SHALL use the unified credential model
- **AND** media bytes SHALL not be embedded in plugin result JSON, telemetry tables or Dgraph

### Requirement: Disconnected edge recording and continuous archival
The disconnected-edge recording profile SHALL capture bounded segments into a
configured local JetStream Object Store without hub connectivity and SHALL
continuously archive finalized segments whenever permanent object storage is
reachable, with restart-safe retry state and finite offline authorization/capacity.

#### Scenario: Hub disconnected but archive reachable
- **WHEN** the edge cannot reach the central NATS hub or CNPG but can reach its authorized S3 destination
- **THEN** capture and archival SHALL continue within the local policy and storage budget
- **AND** completed segments SHALL become eligible for upload immediately
- **AND** leaf reconnection SHALL not be required to start archival

#### Scenario: Reclaim before central index catches up
- **WHEN** segment and initialization objects plus a recoverable archive manifest have been verified in permanent storage
- **AND** an archival receipt has been persisted locally for retryable index delivery
- **THEN** local segment bytes MAY be reclaimed without waiting for central CNPG
- **AND** loss of the edge after reclamation SHALL not prevent index recovery from archive manifests
- **AND** globally available playback SHALL not be advertised before index/authorization publication completes

#### Scenario: Offline capture restarts and later reconnects
- **WHEN** the edge captures for its configured offline window, restarts and later regains connectivity
- **THEN** completed-object and journal reconciliation SHALL recover pending archival work
- **AND** retries and duplicate receipts SHALL not create duplicate segments or index entries
- **AND** a leaf connection or PubAck alone SHALL not be treated as archival success

#### Scenario: Catch-up cannot exceed ongoing capture
- **WHEN** archive goodput is no greater than the incoming media rate
- **THEN** the operator SHALL see non-draining backlog, expiry risk and time-to-full
- **AND** the configured admission policy SHALL bound recording resource use and account for gaps
- **AND** telemetry and control bandwidth/storage reservations SHALL remain enforced

### Requirement: Authorized replay and retention
The system SHALL provide bounded timeline, seek and export operations with
resource authorization, visible gaps and a reconciled retention/hold lifecycle.

#### Scenario: Shared map or recording link
- **WHEN** a recipient opens a link naming a camera, object or recording interval
- **THEN** the host SHALL authorize access independently of the link
- **AND** the link SHALL contain no source credential or durable object-store access token
- **AND** unavailable or expired footage SHALL be identified explicitly

#### Scenario: Hold conflicts with deletion
- **WHEN** a retention deletion races a hold request
- **THEN** an atomic index transition SHALL determine which operation is accepted
- **AND** the system SHALL not confirm a hold on deleted or temporary-only media
- **AND** deletion SHALL be rechecked in object storage before marking it complete
