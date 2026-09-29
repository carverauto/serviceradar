## ADDED Requirements

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
