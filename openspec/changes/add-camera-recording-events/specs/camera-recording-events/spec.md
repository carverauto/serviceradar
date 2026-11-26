## ADDED Requirements

### Requirement: Block lifecycle events
Core SHALL publish one `block.cataloged` message on `camera.recording.blocks.v1` for every sealed recording catalog entry, and one `block.archive_verified` message when an entry's archive copy becomes verified. Each message MUST carry the catalog entry identity, camera source and stream profile, run and clock epoch, timeline bounds, time basis and uncertainty, `contiguous_with_previous`, fragment count, media bytes, and the frozen `init_sha256` and `descriptor_sha256` (or `receipt_sha256` for archive verification).

#### Scenario: Block cataloged
- **WHEN** a sealed block is cataloged
- **THEN** exactly one `block.cataloged` message is stored in `CAMERA_RECORDING_EVENTS` whose `descriptor_sha256` equals the catalog row's value

#### Scenario: Catalog transaction rolls back
- **WHEN** the transaction that inserts a catalog row rolls back
- **THEN** no `block.cataloged` message is published for it

#### Scenario: Archive verified
- **WHEN** a catalog entry's `archive_state` becomes `verified`
- **THEN** a `block.archive_verified` message carries the entry ID and the archive receipt's `receipt_sha256`

### Requirement: Custody change events
Core SHALL publish one message on `camera.recording.custody.v1` for every create, state change, update or delete of recording holds, recording policies (mode, storage and retention override fields), archive settings and NVR storage settings (retention and budget fields), every recording disposition, every camera availability transition, and every recording access audit row. Each message MUST carry the event kind, the transaction timestamp, the actor ID when known, the change source, the source record ID, and `before` and `after` projections of the custody-relevant fields.

#### Scenario: Retention override reduced
- **WHEN** a user changes a policy's archive retention override from 30 to 10 days
- **THEN** a `policy.updated` message carries the user's actor ID, `change_source` `action`, `before.archive_retention_days_override` 30 and `after.archive_retention_days_override` 10

#### Scenario: Hold released
- **WHEN** an accepted hold is released
- **THEN** a `hold.released` message carries the hold ID, window, releasing actor, release reason and creating actor

#### Scenario: Out-of-band change
- **WHEN** a hold row is updated by SQL outside the Ash actions
- **THEN** a custody message is still published with `actor_id` null and `change_source` `out_of_band`

### Requirement: Transactional trigger outbox and acknowledged relay
Events SHALL be captured by database triggers into `platform.camera_recording_event_outbox` in the writing transaction, and a single coordinator relay SHALL publish them in outbox order with a deterministic `Nats-Msg-Id`, deleting a row only after the stream acknowledges it. The relay MUST report outbox depth and oldest-row age and MUST raise a health event when the oldest row is older than 10 minutes.

#### Scenario: NATS unavailable
- **WHEN** NATS is unreachable for 30 minutes while blocks are cataloged
- **THEN** outbox rows accumulate, a health event is raised, and every row is published once NATS returns

#### Scenario: Relay restart after publish before delete
- **WHEN** the relay publishes a row and restarts before deleting it
- **THEN** the republished message has the same `Nats-Msg-Id` and the stream stores it once

### Requirement: Event payload boundaries
Recording event messages SHALL be JSON of at most 4 KiB and MUST NOT contain media bytes, storage credentials, bucket names, endpoints or object keys.

#### Scenario: Archive verified payload
- **WHEN** a `block.archive_verified` message is built
- **THEN** it contains the receipt digest but none of the receipt's object keys or bucket fields

### Requirement: Core-owned recording events stream
Core SHALL create and reconcile the `CAMERA_RECORDING_EVENTS` stream (subjects `camera.recording.>`, file storage, 7-day default `max_age`, finite `max_bytes` from chart values, metadata `serviceradar.owner` `core-elx`) when recording events are enabled, and the render-time JetStream budget MUST count it.

#### Scenario: Fresh install with recording enabled
- **WHEN** core starts with recording events enabled and the stream is absent
- **THEN** core creates it with a positive `max_bytes` and the owner metadata

### Requirement: Recording events consumer permission
The `CN=serviceradar-vantage` NATS identity SHALL be allowed to create and read a durable pull consumer on `CAMERA_RECORDING_EVENTS`, and core SHALL be allowed to publish on `camera.recording.>`.

#### Scenario: Permission rendering
- **WHEN** the chart is rendered with the Vantage provider enabled
- **THEN** the static user permissions test confirms the consumer grants for `CAMERA_RECORDING_EVENTS` and no new core-subject subscribe grants for that identity

### Requirement: Capability-gated provider evidence export
web-ng SHALL show an "Export evidence bundle" action on accepted holds only when the connected provider advertises the `evidence_bundle_export` capability, MUST authorize the user with the hold permission and camera scope, MUST record a `RecordingAccessAudit` row of kind `evidence_exported` before forwarding, and SHALL forward the request over `vantage.rpc.evidence.bundle.v1`.

#### Scenario: Provider absent
- **WHEN** no provider advertises `evidence_bundle_export`
- **THEN** the hold view shows no export action

#### Scenario: Authorized export
- **WHEN** a permitted user exports an accepted hold and the provider is connected
- **THEN** an `evidence_exported` access-audit row exists and the user receives the provider's download link
