## ADDED Requirements

### Requirement: Independently scalable recorder pools
The system SHALL run continuous recording in separately deployable recorder pools with explicit source/profile assignments and capacity reservations, independently of core replicas, viewer sessions and optional media workers.

#### Scenario: Recording starts with no viewers
- **WHEN** an enabled recording policy receives an admitted assignment
- **THEN** the assigned recorder SHALL start and maintain ingest without an open viewer
- **AND** viewer attachment or departure SHALL not create a duplicate upstream for the same source/profile or end the recording assignment

#### Scenario: Pool capacity is exhausted
- **WHEN** a requested assignment exceeds any admitted bitrate, disk, I/O, network, connection, CPU or memory budget
- **THEN** the system SHALL reject or defer the assignment with the limiting resource identified
- **AND** SHALL preserve existing recording, telemetry and viewer reservations
- **AND** adding replicas SHALL not by itself move ownership or adopt another recorder's storage

### Requirement: Recording placement and durable storage are independent
The system SHALL support cloud recording with S3, customer-operated recording with durable local storage, and customer-operated recording with S3. A fully self-hosted local installation SHALL operate without SaaS connectivity, SaaS entitlement checks or S3 resources.

#### Scenario: Local-only installation
- **WHEN** an operator selects customer-operated recording with local retention
- **THEN** the deployment SHALL publish and play authorized recordings from its qualified local archive
- **AND** SHALL not provision buckets or require a cloud upload receipt for local availability
- **AND** admission SHALL account for the configured retention, holds and failure reserves on customer disks

#### Scenario: S3-backed retention
- **WHEN** an operator selects an S3-backed pool
- **THEN** the local reservation SHALL cover the declared upload outage, in-flight work, recovery and cache budgets
- **AND** long-term retention SHALL be allocated to the qualified object destination rather than automatically reserved on hot disks
- **AND** availability SHALL distinguish provisional local, verified archived, indexed and missing intervals

### Requirement: Fenced recording assignment handoff
The system SHALL bind capture to an authenticated source owner, recorder, storage lifetime and monotonic assignment epoch. Handoff SHALL reserve replacement capacity and prove retirement or effective fencing of the previous capture authority before activating a conflicting owner.

#### Scenario: Previous owner is unreachable
- **WHEN** a coordinator loses contact with an owner that may still hold an offline grant
- **THEN** heartbeat loss or a database revocation alone SHALL NOT authorize overlapping capture ownership
- **AND** the assignment SHALL remain unresolved until retirement, effective fencing or conservative grant expiry is established
- **AND** any resulting uncovered interval SHALL be recorded as a gap

#### Scenario: Drained handoff leaves pending uploads
- **WHEN** a recorder seals its last segment and hands off the source
- **THEN** the system SHALL durably retain responsibility for pending media and its original storage lifetime before activating the replacement
- **AND** SHALL reject stale live writes while allowing only explicitly reconciled, provenance-verified historical publications
- **AND** SHALL not retarget old files or manifests to the new owner

### Requirement: Filesystem media data path
The system SHALL write recording payloads to qualified bounded filesystem storage and, when configured, directly to the authorized S3 destination. NATS and JetStream SHALL carry control metadata, telemetry and bounded job references only, not camera media payloads or Object Store staging.

#### Scenario: Recorder seals a segment
- **WHEN** a complete segment and its initialization dependencies are ready
- **THEN** the recorder SHALL durably seal and journal them on its exclusive storage lifetime
- **AND** an S3-backed archiver SHALL upload from that filesystem without forwarding the payload through core or a message broker
- **AND** capture SHALL not require a remote broker quorum or central database round-trip per segment

#### Scenario: Disk reaches its admission limit
- **WHEN** remaining capacity cannot satisfy the admitted capture and recovery budget
- **THEN** the recorder SHALL stop admitting affected capture and report the uncovered intervals
- **AND** SHALL preserve reserved journal/control space, unarchived media and held footage
- **AND** SHALL not grow storage silently, overwrite pending footage or consume telemetry reservations

### Requirement: Durable local archive publication
A local-only recorder SHALL publish availability only after verifying sealed media, initialization dependencies and a durable recoverable manifest/catalog on its qualified storage lifetime. The system SHALL disclose the selected local failure tolerance without treating process-crash durability as proof of disk-loss survival.

#### Scenario: Restart between sealing and catalog publication
- **WHEN** a local recorder restarts after sealing a segment but before catalog publication
- **THEN** reconciliation SHALL verify complete media and dependencies and idempotently recover publication
- **AND** partial or corrupt segments SHALL remain unavailable with an explicit affected interval

#### Scenario: Local owner or volume is lost
- **WHEN** a requested recording's only verified copy is unavailable
- **THEN** playback SHALL report that loss rather than route to an unrelated volume or claim archival availability
- **AND** fallback SHALL require a verified authorized second copy
- **AND** retention, holds and export preservation SHALL apply to local archives as well as S3

### Requirement: Bounded upload recovery independent of index connectivity
An S3-backed recorder SHALL upload sealed segments promptly with bounded concurrency, retries and persistent multipart/reconciliation state. Reclamation SHALL require verified media, initialization dependencies, recoverable archive manifests and a durable retryable receipt; central index connectivity SHALL not be a prerequisite once those proofs exist.

#### Scenario: Upload succeeds but its reply is lost
- **WHEN** recovery discovers an ambiguous upload outcome
- **THEN** it SHALL reconcile the stable object identity, expected length and qualified checksum proof before retrying or reclaiming
- **AND** SHALL not infer content integrity from an ETag alone or overwrite a conflicting object
- **AND** abandoned multipart state SHALL be reconciled within its resource budget

#### Scenario: Recovery throughput cannot drain the backlog
- **WHEN** effective archive goodput is less than or equal to ongoing capture
- **THEN** the system SHALL report a non-draining backlog, oldest pending age and time-to-full
- **AND** SHALL enforce admission limits rather than claim a finite recovery ETA
- **AND** SHALL reserve independent telemetry/control capacity during recovery

### Requirement: Bounded customer-host offline authority
Customer-operated recorders paired with a remote coordinator SHALL use finite offline grants bound to assignment epoch, source, storage lifetime, policy revision and resource/credential budgets. A fully self-hosted local coordinator SHALL not require a SaaS grant.

#### Scenario: Remote coordinator is unavailable
- **WHEN** a recorder loses its remote control connection while its grant remains valid
- **THEN** authorized local capture SHALL continue within the admitted budget
- **AND** S3 archival, when selected and reachable, SHALL continue independently
- **AND** journaled receipts and gaps SHALL reconcile idempotently after reconnect

#### Scenario: Expiry or clock uncertainty after restart
- **WHEN** the recorder cannot conservatively establish remaining grant validity after expiry, reboot or clock rollback
- **THEN** it SHALL stop new capture and require renewed authority
- **AND** SHALL preserve existing media and pending work for authorized recovery
- **AND** SHALL not restart an expired grant's duration from zero

### Requirement: Preservation across recording mode changes
The system SHALL treat changes of pool, storage mode and destination as explicit transitions with new authority and retained historical storage identities, preserving authorization, residency restrictions, holds and active exports.

#### Scenario: Local archive changes to S3-backed capture
- **WHEN** an operator enables S3 for future recording
- **THEN** historical local recordings SHALL remain bound to their existing storage lifetime
- **AND** copying historical media SHALL require an explicit authorized migration with verified destination publication before permitted reclamation
- **AND** disabling or disconnecting a customer pool SHALL not authorize customer-disk deletion

### Requirement: Measured recording capacity qualification
The system SHALL qualify supported recorder profiles through synthetic media at increasing scale, declared per-mode SLOs, actual ingest/seal/upload/playback paths and fault injection. Estimates and visible hardware SHALL NOT establish a supported camera count.

#### Scenario: Capacity tier cannot meet its declared SLOs
- **WHEN** the qualification workload exceeds resource bounds, misses its coverage or recovery objective, or leaves unexplained gaps or duplicate accepted intervals
- **THEN** that tier SHALL fail qualification and remain unsupported
- **AND** the report SHALL retain workload, hardware, codec, storage mode and failure evidence
- **AND** a tier that was not exercised SHALL remain explicitly unqualified

### Requirement: Outbound playback from customer-hosted archives
Hosted playback of customer-hosted recordings SHALL use agent-established control and media connections when Cloud cannot reach the authorized archive directly. The runtime SHALL derive bounded ranges from trusted recording metadata after fresh recording-read and interval authorization, and SHALL NOT expose arbitrary paths, URLs or client-selected provider ranges through the bridge.

#### Scenario: Authorized playback with customer ingress denied
- **GIVEN** a verified recording is retained only on a customer recorder and inbound customer access is denied
- **WHEN** an authorized hosted user requests an interval
- **THEN** the runtime SHALL send a scoped recording/range request over the agent-established control channel
- **AND** the agent SHALL push the bounded response over an authenticated media RPC without Cloud dialing the recorder
- **AND** request identity, deadline, byte limits and cancellation SHALL remain enforced through disconnect and reconnect

#### Scenario: Edge is unavailable during playback
- **WHEN** an outbound bridge becomes unavailable
- **THEN** the runtime SHALL report local-only footage unavailable without disrupting otherwise authorized local recording
- **AND** playback MAY continue from a verified authorized cloud-reachable archive copy
- **AND** an S3 endpoint unreachable from Cloud SHALL NOT be reported as a working direct fallback

### Requirement: Bounded object archive playback
The system SHALL serve verified archive playback as authorized playable fragments or bounded ranges with initialization and keyframe dependencies. It SHALL enforce per-playback and aggregate read-ahead, byte and concurrency budgets without requiring a whole-recording local restore. Optional shared caches SHALL preserve fresh authorization and SHALL NOT consume recording spool reserves.

#### Scenario: Seek starts within a packed archive object
- **WHEN** an authorized viewer seeks to a recorded interval
- **THEN** the runtime SHALL map time to trusted immutable object identity and a valid decode boundary
- **AND** SHALL deliver only authorized media and necessary permitted initialization dependencies
- **AND** SHALL cancel obsolete prefetch without downloading the entire recording or exposing unrelated object intervals

#### Scenario: Viewers request cached fragments at independent positions
- **GIVEN** a shared fragment cache is enabled
- **WHEN** authorized viewers request the same immutable fragment
- **THEN** reads SHALL reuse cached bytes or coalesce identical in-flight fetches within the serving scope
- **AND** every served request SHALL retain fresh authorization, even on a cache hit
- **AND** viewers seeking to different intervals SHALL retain independent playback state

#### Scenario: Origin cannot keep up with playback
- **WHEN** origin latency or available goodput prevents the selected playback rate
- **THEN** playback SHALL expose buffering or unavailability while retaining its declared resource limits
- **AND** stalled or abandoned reads SHALL NOT consume unbounded cache or disrupt capture, archival or control
