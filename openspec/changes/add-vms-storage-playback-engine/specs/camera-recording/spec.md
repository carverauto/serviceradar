## ADDED Requirements

### Requirement: Fenced recording policy on shared ingest
The system SHALL authorize recording policies in CNPG/Ash and maintain one fenced recorder owner per source/profile while reusing the existing ingest and unified camera credentials.

#### Scenario: Stale recorder publishes after takeover
- **WHEN** a former owner submits a block or ownership mutation after a new epoch is assigned
- **THEN** publication SHALL be rejected without corrupting the new owner's index
- **AND** retries within the valid epoch SHALL preserve one stable block identity

#### Scenario: Durable stop races new recorder work
- **WHEN** an authenticated recording stop races recorder acquisition, renewal, block reservation or new dispatch marking
- **THEN** one durable control row SHALL serialize stop before the existing ownership locks and deny new rights after stop commits
- **AND** preservation through the original publication, freeze, release and late-observation fences SHALL remain available
- **AND** stop SHALL NOT erase retained bytes, reset unresolved dispatches or claim cancellation of remote work

#### Scenario: Recorder drains while live viewing continues
- **WHEN** an active recorder observes durable stop during renewal
- **THEN** its exact producer SHALL order recorder end after accepted media and retain unrelated live viewers
- **AND** the recorder SHALL finish and seal only within its original lease deadline
- **AND** failure or expiry SHALL preserve recoverable journaled bytes without claiming a completed seal or fleet-wide drain

### Requirement: Bounded seekable recording format
The system SHALL produce bounded keyframe-aligned fragments and immutable packed blocks with initialization references, versioned byte maps, codec configuration, clock provenance and explicit discontinuities.

#### Scenario: Keyframes or clock continuity are unavailable
- **WHEN** a source exceeds the keyframe/byte/time budget or reconnects with an uncertain clock
- **THEN** the recorder SHALL close or reject affected capture with an explicit gap or discontinuity
- **AND** SHALL not accumulate unbounded media or invent UTC continuity

#### Scenario: Unknown motion
- **WHEN** no analysis result exists for a fragment
- **THEN** its motion state SHALL remain unknown rather than asserting no motion

### Requirement: Provisional local playback
The system SHALL distinguish complete locally readable fragments from verified archival availability and serve local bytes only below a durably committed readable boundary.

#### Scenario: Seek before block upload
- **WHEN** an authorized user seeks to a completed fragment in an open local block
- **THEN** the range service SHALL serve only that complete authorized range and label it provisional
- **AND** SHALL not expose the incomplete append tail or claim S3 durability

#### Scenario: Local node loss
- **WHEN** local-only media cannot be recovered after node or storage loss
- **THEN** the system SHALL report unavailable coverage or loss
- **AND** SHALL fall back only where a verified archive actually exists

### Requirement: Verified recoverable archive publication
The system SHALL verify immutable media, initialization dependencies and recoverable manifests before publishing idempotent available index entries.

#### Scenario: Crash after upload before index
- **WHEN** upload succeeds and the recorder crashes before index publication
- **THEN** reconciliation SHALL verify the existing objects and publish at most one entry
- **AND** a checksum mismatch SHALL prevent availability and local reclamation

#### Scenario: Archive exists while central index is offline
- **WHEN** an edge archive has verified media, manifest and durable receipt but cannot update the central index
- **THEN** archival and global availability SHALL remain distinct
- **AND** the edge archive contract SHALL permit safe reclamation with retryable index delivery

### Requirement: Separate media control and telemetry stores
The system SHALL store recording/index/hold state in CNPG/Ash, durable media in purpose-scoped object storage, and observation/health telemetry through JetStream/EventWriter into its configured backend.

#### Scenario: Plugin or GPU worker reports media
- **WHEN** a source descriptor or worker result enters the platform
- **THEN** host policy SHALL determine authorized storage and projection
- **AND** workers SHALL not write database rows directly or embed video in telemetry results

### Requirement: Authorized bounded replay
The system SHALL authorize timeline, HLS manifest, media ranges and export operations and expose unavailable, provisional, expired and discontinuous intervals explicitly.

#### Scenario: Inspect a retained archive block
- **WHEN** an authenticated caller requests one camera's recording metadata
- **THEN** the system SHALL require current recording-read and inventory permissions and match the retained block to that camera
- **AND** live-video permission alone SHALL NOT authorize historical recording access
- **AND** the frozen fragment descriptor SHALL be returned only while the canonical archive proof chain is available, with late conflicts withholding it
- **AND** the metadata response SHALL NOT contain storage credentials, object locations or a future media-access grant

#### Scenario: Packed object contains footage outside access scope
- **WHEN** a user is authorized for only part of a packed object
- **THEN** the playback gateway SHALL enforce the permitted range/time scope
- **AND** SHALL not issue an object URL that grants the remaining footage

#### Scenario: Cross-block seeking and shared links
- **WHEN** an authorized user seeks across blocks or opens a camera/object/time link
- **THEN** the player SHALL receive correct init/range and discontinuity information
- **AND** the link SHALL grant no access by itself or contain reusable credentials
- **AND** dashboard disposal SHALL release viewer resources without stopping recording

### Requirement: Bounded cache and timeline projection
The system SHALL enforce cache/spool/read budgets and bounded timeline resolution while preserving authoritative coverage and aggregate freshness.

#### Scenario: Cache pressure and late publication
- **WHEN** cache capacity is exhausted or a previously missing block becomes available
- **THEN** verified cached copies SHALL be evicted before unarchived spool
- **AND** affected timeline aggregates SHALL be invalidated or refreshed without hiding gaps

### Requirement: Transactional evidence holds and export leases
The system SHALL serialize holds, exports and deletion decisions and confirm a hold only after verified durable storage protection can honor it.

#### Scenario: Hold races retention or termination
- **WHEN** a hold or export races a deletion claim
- **THEN** the metadata workflow SHALL select a consistent winner
- **AND** SHALL reject a hold on missing or temporary-only bytes
- **AND** provider cleanup SHALL not bypass accepted preservation obligations

#### Scenario: Evidence copy is interrupted
- **WHEN** copying a held interval fails before verification
- **THEN** the hold SHALL remain pending or failed and source deletion SHALL remain blocked by its preservation claim
- **AND** retry SHALL not advertise an unverified evidence copy

### Requirement: Verified retention and derivative lifecycle
The system SHALL verify eligible object/version deletion before completing metadata cleanup and SHALL preserve hold/export dependencies and immutable original provenance.

#### Scenario: Delete marker or partial cleanup
- **WHEN** storage deletion leaves protected versions or fails for part of the object set
- **THEN** cleanup SHALL remain retryable and SHALL not report physical deletion complete
- **AND** metadata chunks needed by surviving or protected media SHALL remain

#### Scenario: Derived export
- **WHEN** an annotated, transcoded or composed export is generated
- **THEN** the result SHALL reference original intervals/digests and render configuration
- **AND** SHALL not overwrite the original recording
