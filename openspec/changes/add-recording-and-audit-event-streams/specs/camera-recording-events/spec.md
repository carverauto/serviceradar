## ADDED Requirements

### Requirement: Block lifecycle events
Core SHALL publish one `block.cataloged` message on `camera.recording.blocks.v1` for every sealed recording catalog entry, and one `block.archive_verified` message when an entry's archive copy becomes verified. Each message MUST carry the catalog entry identity, camera source and stream profile, run and clock epoch, timeline bounds, time basis and uncertainty, `contiguous_with_previous`, fragment count, media bytes, and the frozen `init_sha256` and `descriptor_sha256` (or `receipt_sha256` for archive verification). Messages MUST NOT contain media bytes, credentials, bucket names, endpoints or object keys.

#### Scenario: Block cataloged
- **WHEN** a sealed block is cataloged
- **THEN** exactly one `block.cataloged` message is stored in `CAMERA_RECORDING_EVENTS` whose `descriptor_sha256` equals the catalog row's value

#### Scenario: Catalog transaction rolls back
- **WHEN** the transaction that inserts a catalog row rolls back
- **THEN** no `block.cataloged` message is published for it

#### Scenario: Archive verified
- **WHEN** a catalog entry's `archive_state` becomes `verified`
- **THEN** a `block.archive_verified` message carries the entry ID and the receipt's `receipt_sha256`, and none of the receipt's object keys

### Requirement: Core-owned recording events stream
Core SHALL create and reconcile `CAMERA_RECORDING_EVENTS` (subjects `camera.recording.>`, file storage, 7-day default `max_age`, finite `max_bytes` from chart values, metadata `serviceradar.owner` `core-elx`) when recording events are enabled, and the render-time JetStream budget MUST count it.

#### Scenario: Fresh install with recording enabled
- **WHEN** core starts with recording events enabled and the stream is absent
- **THEN** core creates it with a positive `max_bytes` and the owner metadata

### Requirement: Capability-gated provider evidence export
web-ng SHALL show an "Export evidence bundle" action on accepted holds only when a provider answers `integrity.rpc.evidence.capabilities.v1` with `evidence_bundle_export`, MUST authorize the user with the hold permission and camera scope, MUST record a `RecordingAccessAudit` row of kind `evidence_exported` before forwarding, and SHALL forward the request over `integrity.rpc.evidence.bundle.v1`.

#### Scenario: Provider absent
- **WHEN** no provider answers the evidence capabilities request
- **THEN** the hold view shows no export action

#### Scenario: Authorized export
- **WHEN** a permitted user exports an accepted hold and the provider is connected
- **THEN** an `evidence_exported` access-audit row exists and the user receives the provider's download link
