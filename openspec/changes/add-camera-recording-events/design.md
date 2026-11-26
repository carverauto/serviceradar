# Design: camera recording lifecycle and custody events

## Context

- `ServiceRadar.Camera.RecordingBlocks.freeze_and_catalog/6` creates the catalog
  row and broadcasts `RecordingPubSub.broadcast_updated(..., :block_cataloged)`;
  nothing leaves the BEAM cluster.
- `RecordingHold`, `CameraRecordingPolicy`, `RecordingArchiveSettings` and
  `NVRStorageSettings` keep history through AshPaperTrail; the
  `AuditVersionRetentionWorker` purges versions after 180 days.
- `RecordingDisposition` and `RecordingAccessAudit` are append-only by trigger.
- Hold release currently needs the same permission as hold creation. This change
  does not alter that; it makes releases observable.
- `ServiceRadar.NATS.DurablePublish` and `ServiceRadar.Inventory.ExposureOutboxRelay`
  are the existing publish-after-commit patterns.

## Goals / Non-Goals

- Goals: a complete, ordered-per-source, at-least-once feed of recording
  lifecycle and custody changes that external services can consume without
  reading core tables; nothing published for a transaction that rolls back.
- Non-Goals: changing hold or retention semantics, adding a two-person release
  rule, publishing media or storage locations, defining what consumers do with
  the events.

## Decisions

### D1. Trigger-based outbox instead of Ash after_action hooks
A Postgres trigger on each source table inserts a row into
`platform.camera_recording_event_outbox` in the writing transaction.
- Catches every write path, including migrations, manual SQL and future code that
  bypasses the Ash action, which an after_action hook cannot.
- Actor context: recording actions run `SET LOCAL serviceradar.actor_id` and
  `SET LOCAL serviceradar.change_source = 'action'` inside their transaction; the
  trigger reads both with `current_setting(..., true)`. When unset, the event
  carries `actor_id: null` and `change_source: "out_of_band"`.
- Source tables and operations:
  - `camera_recording_catalog`: INSERT of a sealed row (`block.cataloged`);
    UPDATE of `archive_state` to `verified` (`block.archive_verified`).
  - `camera_recording_holds`: INSERT, state changes (`hold.created`,
    `hold.accepted`, `hold.released`).
  - `camera_recording_policies`: INSERT, UPDATE of `mode`, `storage`,
    `archive_retention_override_mode`, `archive_retention_days_override`,
    DELETE (`policy.*`).
  - `camera_recording_archive_settings`, `camera_nvr_storage_settings`: UPDATE of
    retention and budget fields (`archive_settings.changed`,
    `storage_settings.changed`).
  - `camera_recording_dispositions`: INSERT (`disposition.recorded`).
  - `camera_sources`: UPDATE of `availability_status` (`camera.availability_changed`).
  - `camera_recording_access_audits`: INSERT (`access.recorded`).
- The trigger stores only a whitelisted projection of columns (before and after),
  never free-form blobs, receipts with object keys, or credentials.

*Alternative:* `DurablePublish` from after_action hooks. Rejected for custody
events because it misses out-of-band writes, which are exactly the changes an
auditor needs to see.

### D2. Relay
A coordinator-only relay (same shape as `ExposureOutboxRelay`) reads outbox rows
in `id` order in bounded batches, publishes with `Nats-Msg-Id` =
`<event_kind>:<source_table>:<source_id>:<outbox_id>`, and deletes a row only
after PubAck. It reports outbox depth and oldest-row age as health metrics and
raises a health event when the oldest row is older than 10 minutes.

### D3. Envelope
Every message is JSON, at most 4 KiB, with common fields: `schema_version` (1),
`event_id` (outbox id), `event_kind`, `occurred_at` (transaction timestamp,
microseconds), `actor_id`, `change_source`, `source_table`, `source_id`,
`camera_source_id`, `stream_profile_id` (when applicable). Kind-specific fields:
- `block.cataloged`: `catalog_entry_id`, `block_key`, `storage_id`, `run_id`,
  `clock_epoch`, `timeline_start_us`, `timeline_end_us`, `time_basis`,
  `time_uncertainty_us`, `contiguous_with_previous`, `fragment_count`,
  `media_bytes`, `init_sha256`, `descriptor_sha256`, `sealed_at`.
- `block.archive_verified`: `catalog_entry_id`, `receipt_sha256`, `archived_at`.
- custody kinds: `before` and `after` objects holding the whitelisted fields.

### D4. Stream
`CAMERA_RECORDING_EVENTS`, subjects `camera.recording.>`, file storage, limits
retention, `max_age` 7 days, finite `max_bytes` from chart values counted in the
render-time JetStream budget, duplicate window 2 minutes, metadata
`serviceradar.owner = core-elx`. Core creates and reconciles it; consumers never
create it.

### D5. Permissions
- core-elx identity: publish `camera.recording.>`.
- `CN=serviceradar-vantage`: consumer create/info/next/ack on
  `CAMERA_RECORDING_EVENTS` only, through
  `$JS.API.CONSUMER.*.CAMERA_RECORDING_EVENTS.>` and
  `$JS.API.CONSUMER.MSG.NEXT.CAMERA_RECORDING_EVENTS.>`. Narrowing the existing
  broad `$JS.API.>` grant on that identity is tracked separately.

### D6. Provider export action in web-ng
The export action reuses the existing provider client and capability gate. web-ng
checks `devices.cameras.recordings.hold` plus camera scope, writes the
`evidence_exported` access-audit row, then calls the provider. Failure modes are
shown to the user; web-ng never builds or stores the bundle itself.

## Risks / Trade-offs

- Triggers add write cost to custody tables: these are low-rate tables; the
  catalog trigger adds one small insert per block (at most a few per second per
  deployment).
- Outbox growth if NATS is down: bounded by a max-rows guard that raises a
  critical health event; rows are never dropped.
- Payload privacy: hold `reason` text can contain case detail; it is included
  because custody consumers need it, and the stream is readable only by
  identities granted above.

## Migration Plan

1. Migration adds the outbox table and triggers; the relay starts disabled until
   the stream exists.
2. Core creates the stream on startup when recording is enabled
   (`cameraRecordingEvents.enabled`, default follows `nvr.enabled`).
3. Rollback: disable the value; triggers keep writing to the outbox, which is
   truncated by an operator task if the feature is permanently removed.

## Open Questions

- Should the outbox also back-publish catalog rows created before the migration?
  Proposed: no; consumers start from the stream's first message.
