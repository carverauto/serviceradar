## ADDED Requirements

### Requirement: Recording and storage settings view
The system SHALL provide a Recording & Storage view in the Settings catalog that permitted users can open from the navigation and from the command palette, and that remains listed when recording is not installed.
The view SHALL be gated by `settings.recording.view`, `settings.recording.manage` or `settings.recording.operate`, SHALL re-authorize every state-changing event, and SHALL load no database data during disconnected mount.

#### Scenario: Operator searches for cameras
- **GIVEN** a user holding `settings.recording.view`
- **WHEN** the user opens the Settings command palette and types "camera"
- **THEN** the palette SHALL list the Recording & Storage view
- **AND** selecting it SHALL navigate to `/settings/recording`

#### Scenario: Recording is not installed
- **GIVEN** core-elx reports that no NVR client configuration is installed
- **WHEN** a permitted user opens the view
- **THEN** the view SHALL state that the NVR is not installed and link the installation documentation
- **AND** SHALL NOT render empty recorder, destination or block lists as if none existed

#### Scenario: Unpermitted user
- **GIVEN** a user without any of the three recording settings permissions
- **WHEN** the user opens `/settings/recording` directly
- **THEN** access SHALL be denied at mount
- **AND** the view SHALL NOT appear in any Settings navigation surface for that user

### Requirement: Honest recorder and archive state
The system SHALL report recording installation, Core recovery gate state, each NVR member's readiness, recovery gate state and capacity, and archive configuration as separate states, and SHALL report an unreachable or refusing source as unknown rather than as empty or absent.
The settings view SHALL NOT open, close or otherwise change the deployment recovery gate.

#### Scenario: Recovery gate is closed
- **GIVEN** the NVR is installed and the deployment recovery gate is closed
- **WHEN** an operator opens the recorders tab
- **THEN** the view SHALL show the gate as closed for Core and for each member that reports it
- **AND** SHALL distinguish a gate that is not configured from one that is closed
- **AND** SHALL link the documented recovery procedure without offering a control that changes the gate

#### Scenario: Member is unreachable
- **GIVEN** one NVR member does not answer its status request within the deadline
- **WHEN** the recorders tab renders
- **THEN** that member's readiness and capacity SHALL be shown as unknown
- **AND** the other members SHALL still be shown with their reported state

#### Scenario: Local retention is not yet enforced
- **GIVEN** local capacity and age retention have not been implemented
- **WHEN** the recorders tab shows capacity
- **THEN** the view SHALL state that local blocks are not reclaimed by byte budget or maximum local age and that capture is refused when capacity is exhausted

#### Scenario: Local-only mode with no object storage configured
- **GIVEN** the NVR is installed and `archive_enabled` is false or no active archive destination is selected
- **WHEN** an operator opens the archive or recorders tab
- **THEN** the view SHALL report "Local only: no object storage configured" as a normal operating state rather than an error, warning or incomplete setup

### Requirement: Operator archive destinations
The system SHALL let a user with `settings.recording.manage` register an S3-compatible archive destination (endpoint, region, bucket and key prefix) as an immutable destination generation and select one active destination for new archive operations.
Changing any destination field SHALL register a new generation, and existing blocks and receipts SHALL keep the generation they were written under.

#### Scenario: Destination is edited
- **GIVEN** an active operator destination at generation 1
- **WHEN** the operator changes its bucket and saves
- **THEN** generation 2 SHALL be registered with a new destination fingerprint
- **AND** generation 1 and every receipt bound to it SHALL remain unchanged and visible

#### Scenario: Invalid endpoint
- **WHEN** the operator enters an endpoint with an IP literal, a non-443 port, a path or a scheme other than `https`
- **THEN** registration SHALL be refused
- **AND** the form SHALL identify the endpoint field as the reason

#### Scenario: Destination is shown as unqualified
- **WHEN** any destination is listed
- **THEN** the view SHALL show it as unqualified
- **AND** SHALL NOT describe a passed connectivity test as provider qualification

### Requirement: Archive credentials selected from the unified inventory
The system SHALL reference the archive writer credential, and an optional reader credential, by identifier from `platform.network_credential_secrets` under the `s3_compatible` descriptor, with restrictive foreign keys, inclusion in the credential-usage inventory and guarded deletion.
The recording settings SHALL NOT accept, display, store or log access-key material, and no Helm value, mounted file or environment variable SHALL supply an archive credential.

#### Scenario: Selecting a credential
- **GIVEN** a user holding `settings.recording.manage` and `settings.credentials.manage`
- **WHEN** the user opens the credential selector
- **THEN** it SHALL list only enabled `s3_compatible` credentials by name
- **AND** SHALL offer a link to create one in the credentials settings area instead of key fields

#### Scenario: Referenced credential deletion
- **GIVEN** the recording settings reference an `s3_compatible` credential
- **WHEN** an operator tries to delete that credential
- **THEN** the deletion SHALL be refused
- **AND** the credential's usage view SHALL list the camera archive as a consumer with a link to the recording settings

#### Scenario: Selected credential is disabled
- **GIVEN** the selected writer credential is disabled or deleted
- **WHEN** the archive tab renders or an archive operation starts
- **THEN** the view SHALL report the archive as unavailable because of the credential
- **AND** the operation SHALL NOT be sent to an NVR

### Requirement: Destination connectivity test from each recorder
The system SHALL let a user with `settings.recording.operate` test the active destination from each NVR member by writing, inspecting and reading back one deterministic probe object with the archive write options, and SHALL report the result per member and per stage.

#### Scenario: Test passes
- **WHEN** a member writes, inspects and reads back the probe object with a matching SHA-256
- **THEN** that member SHALL be shown as able to reach the destination with the time of the test
- **AND** the result SHALL be labeled a connectivity test, not a qualification

#### Scenario: Repeat test finds the existing probe
- **GIVEN** the probe object for this member and credential generation already exists
- **WHEN** the test runs again
- **THEN** the member SHALL verify the existing object by inspection and readback instead of failing
- **AND** a probe object with different content SHALL be reported as a conflict

#### Scenario: Provider rejects the credential
- **WHEN** the provider refuses the write
- **THEN** the member's result SHALL name the failing stage and the provider status class
- **AND** no credential or key material SHALL appear in the result, logs or operation record

### Requirement: Supervised operator recording operations
The system SHALL run operator-initiated captures, archive operations, destination tests and retrieval checks under core-elx supervision independent of the browser session, and SHALL record each as an operation with actor, target, state, bounded error class and timestamps.
The system SHALL NOT automatically retry an operation whose outcome is uncertain.

#### Scenario: Browser closes during a capture
- **GIVEN** an operator started a bounded capture to an NVR member
- **WHEN** the operator closes the page before it finishes
- **THEN** the capture SHALL run to completion or its deadline
- **AND** reopening the view SHALL show the recorded outcome

#### Scenario: Uncertain capture outcome
- **WHEN** a capture ends with an uncertain NVR ingest outcome
- **THEN** the operation SHALL be shown as outcome unknown with the retained block identity
- **AND** the system SHALL NOT start a replacement capture or target another member

#### Scenario: Supervisor restarts mid-operation
- **GIVEN** an operation record is still running after its deadline because core-elx restarted
- **WHEN** the view reads it
- **THEN** it SHALL be shown as outcome unknown rather than running

#### Scenario: Archive is busy
- **WHEN** the NVR reports that another archive operation is in progress
- **THEN** the operation SHALL be shown as refused because the recorder is busy, not as an archive failure

### Requirement: Core record of verified archive copies
The system SHALL persist each NVR archive receipt in Core as an append-only record bound to the destination generation, storage identity and block identity, and SHALL import receipts that an NVR holds but Core lacks.
A receipt record SHALL NOT be treated as archive publication, a qualified archive proof or authority to reclaim local media.

#### Scenario: Archive response is lost
- **GIVEN** an NVR wrote a receipt but Core did not receive the response
- **WHEN** receipt import runs
- **THEN** Core SHALL record the receipt under the destination generation that matches its destination exactly
- **AND** a receipt matching no single generation SHALL be reported as unmatched and not recorded

#### Scenario: Conflicting receipt
- **GIVEN** Core holds a receipt for a block and destination generation
- **WHEN** different receipt bytes arrive for the same identity
- **THEN** Core SHALL refuse them and keep the original record

### Requirement: Per-camera block locations
The system SHALL list a camera's recorded blocks in bounded pages and show, separately for the local copy and the archive copy, whether each is present, absent or unknown, together with the archive receipt details when one exists.
The system SHALL NOT infer that a copy is absent from an unreachable or refusing source, and SHALL NOT present Core's block reservation state as local seal state.

#### Scenario: Block is local and archived
- **GIVEN** the owning NVR reports the block sealed and Core holds its receipt
- **WHEN** the camera's block list renders
- **THEN** the block SHALL be shown as local and archived
- **AND** the receipt's object keys, lengths, SHA-256 values, ETags, optional object version IDs and verification time SHALL be available

#### Scenario: Owning NVR is unreachable
- **WHEN** the owning member does not answer the block lookup
- **THEN** the local copy SHALL be shown as unknown
- **AND** the archive copy SHALL still be shown from Core's receipt

#### Scenario: Local copy missing while a receipt exists
- **GIVEN** reclamation is not implemented
- **WHEN** the owning NVR reports a receipted block absent
- **THEN** the block SHALL be shown as archive only and flagged as an unexpected local loss

### Requirement: Independent retrieval checks
The system SHALL let a user with `settings.recording.operate` verify the local copy through the owning NVR and the archive copy against Core's receipt independently, reporting length and SHA-256 per object, and SHALL NOT substitute one copy for the other when a check fails.

#### Scenario: Archive check after local loss
- **GIVEN** a block's local copy is absent and Core holds its receipt
- **WHEN** the operator runs the archive retrieval check
- **THEN** the NVR SHALL read the archived objects with the reader credential and compare them to the receipt
- **AND** the result SHALL NOT depend on the local copy

#### Scenario: Copies disagree
- **WHEN** a retrieved object's length or SHA-256 differs from the receipt
- **THEN** the check SHALL fail for that object and name it
- **AND** the view SHALL NOT report the copy as retrievable

### Requirement: Runtime recording policy and hot retention settings
The system SHALL store per-camera recording policy and local retention choices as CNPG runtime settings with code defaults, a 24-hour default maximum local age ceiling (`max_local_age_mode = limited`, `max_local_age_seconds = 86400`, bounds 1 hour to 10 years, or `unlimited`), and no Helm-only configuration.
With archiving enabled, local storage SHALL operate as a byte-budget cache that evicts the oldest cataloged, reconciled, archive-verified local blocks when usage reaches the high-water mark down to the low-water mark or when a block exceeds a limited maximum local age ceiling, whichever comes first. Unarchived and unreconciled blocks SHALL NOT be evicted. Once a block's archive copy is verified, any hold SHALL pin the archive copy and the local copy SHALL remain evictable; before archive verification, or in local-only mode, a hold SHALL pin the local copy. In local-only mode, space eviction SHALL occur only under an explicitly confirmed `local_only_full_policy` (`overwrite_oldest` or `stop_when_full`, behaving as `stop_when_full` when unset) rather than reusing `max_local_age_seconds`.

#### Scenario: Archive is failing past the maximum local age
- **GIVEN** a camera records with local plus archive storage and uploads have failed past the maximum local age ceiling or into high-water usage
- **WHEN** retention evaluates its local blocks
- **THEN** unarchived blocks SHALL be retained
- **AND** the view SHALL report the retained backlog and the archive failure

#### Scenario: Hold on archive-verified block keeps local copy evictable
- **GIVEN** a block has a verified archive copy and an active hold
- **WHEN** local retention evaluates byte-budget watermarks or the maximum local age ceiling
- **THEN** the hold SHALL pin the archive copy and the local copy MAY be evicted

#### Scenario: Local-only full policy confirmation
- **GIVEN** a deployment records in local-only mode
- **WHEN** the operator configures local-only retention
- **THEN** `overwrite_oldest` SHALL state that eviction deletes the only copy and require explicit confirmation, and an unrecorded selection SHALL behave as `stop_when_full`

#### Scenario: Policy edit
- **WHEN** an operator changes a camera's recording destination
- **THEN** the change SHALL be applied as a recording assignment transition
- **AND** existing blocks SHALL keep their original storage and destination identity

### Requirement: Archive backlog and health reporting
The system SHALL report pending archive block count, oldest pending age, archive goodput relative to capture, and a non-draining backlog condition per recorder. Recorders SHALL publish backlog and goodput telemetry through JetStream for EventWriter persistence rather than writing it to a database.

#### Scenario: Backlog cannot drain
- **WHEN** archive goodput is less than or equal to ongoing capture
- **THEN** the health view SHALL report a non-draining backlog with the oldest pending age
- **AND** SHALL NOT show a recovery estimate

### Requirement: Source-forced recorded playback
The system SHALL let a user with recording-read permission force recorded playback on the per-camera timeline playback routes (`/api/cameras/:id/timeline/...`, defined by `add-nvr-retention-and-timeline-playback`, never `/recordings/:id`) to the local copy or to the archive copy, and SHALL report the forced source as unavailable rather than falling back to the other copy.

#### Scenario: Forced archive playback with local copy present
- **GIVEN** a block exists locally and in the archive
- **WHEN** the user plays it with the archive source forced
- **THEN** every fragment SHALL be read from the archive copy

#### Scenario: Forced local playback after local loss
- **GIVEN** a block's local copy is absent
- **WHEN** the user plays it with the local source forced
- **THEN** playback SHALL report the local copy unavailable
- **AND** SHALL NOT read the archive copy
