## ADDED Requirements

### Requirement: Deployment-bounded filesystem staging
The recorder SHALL use qualified filesystem storage with finite byte, age, segment-size and concurrency budgets and physical reservations that preserve telemetry/control capacity. Camera media SHALL NOT use JetStream Object Store staging or broker payload forwarding.

#### Scenario: Staging configured without a capacity plan
- **WHEN** storage lacks finite admitted bounds or sufficient qualified reserved capacity
- **THEN** recording admission SHALL be rejected with an actionable sizing error
- **AND** existing telemetry retention/capacity SHALL remain unchanged

#### Scenario: Archive outage outlasts the buffer
- **WHEN** unarchived media reaches the configured pressure or safe admission boundary
- **THEN** the system SHALL expose pending pressure and stop affected new capture with explicit gap intervals
- **AND** SHALL not acknowledge archival retention, silently grow storage, delete unarchived or held media, or evict telemetry
- **AND** cleanup SHALL reconcile incomplete local records and uploads without consuming reserved control/journal space

### Requirement: Disconnected edge recording and continuous archival
The disconnected-edge recording profile SHALL capture bounded segments on its
qualified exclusive filesystem without hub connectivity, with restart-safe state
and finite offline authorization/capacity. S3-backed mode SHALL continuously archive
finalized segments whenever its authorized destination is reachable; local-only
mode SHALL publish and retain verified local media without requiring S3.

#### Scenario: Hub disconnected but archive reachable
- **WHEN** an S3-backed edge cannot reach the central NATS hub or CNPG but can reach its authorized S3 destination
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
- **THEN** sealed-media and journal reconciliation SHALL recover pending archival work
- **AND** retries and duplicate receipts SHALL not create duplicate segments or index entries
- **AND** a leaf connection or PubAck alone SHALL not be treated as archival success

#### Scenario: Catch-up cannot exceed ongoing capture
- **WHEN** archive goodput is no greater than the incoming media rate
- **THEN** the operator SHALL see non-draining backlog, expiry risk and time-to-full
- **AND** the configured admission policy SHALL bound recording resource use and account for gaps
- **AND** telemetry and control bandwidth/storage reservations SHALL remain enforced

#### Scenario: Local-only operation needs no archive endpoint
- **WHEN** the configured mode retains recordings locally and the cloud is unreachable
- **THEN** valid local authority SHALL permit capture and durable local publication within the retention budget
- **AND** local playback SHALL use the authorized local read boundary without an S3 receipt or SaaS check
- **AND** retained media SHALL remain subject to holds, explicit retention and truthful local failure guarantees
