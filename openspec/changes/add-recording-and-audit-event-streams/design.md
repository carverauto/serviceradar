# Design: recording lifecycle and configurable audit event streams

## Context

- **Block cataloging.** `ServiceRadar.Camera.RecordingBlocks.freeze_and_catalog/6` creates each
  catalog row and broadcasts `:block_cataloged` on Phoenix PubSub only.
- **Audit history.** It comes from three places:
  - AshPaperTrail versions on 45 resources;
  - AshEvents `platform.api_events`, used today only by `StatefulAlertRule`;
  - append-only tables for dispositions and access audits.

  `ServiceRadar.Security.AuditHistory` already reads PaperTrail and AshEvents through
  operator-configurable allow-lists.
- **Audit retention.** `AuditVersionRetentionWorker` purges PaperTrail versions after 180 days.
  `ApiEvent` has a `delete_older_than` action.
- **Existing publish patterns.** `ServiceRadar.NATS.DurablePublish` and
  `ServiceRadar.Inventory.ExposureOutboxRelay` both publish only after commit.

## Goals / Non-Goals

- **Goals:**
  - a complete, at-least-once feed of recording lifecycle events and operator-selected audit
    sources;
  - nothing published for a rolled-back transaction;
  - out-of-band writes captured;
  - consumers able to see when capture is narrowed or disabled.
- **Non-Goals:**
  - changing hold, retention or audit semantics;
  - publishing media or storage locations;
  - defining what consumers do with the events.

## Decisions

### D1. Trigger outbox
Postgres triggers on each source table insert into `platform.camera_recording_event_outbox` and
`platform.audit_event_outbox` within the writing transaction. This catches every write path,
including migrations, manual SQL and code that bypasses Ash. An Ash `after_action` hook would
catch none of those.

- **Actor context.** Audited actions run `SET LOCAL serviceradar.actor_id` and
  `SET LOCAL serviceradar.change_source` (`action`, `retention`, `system`). Triggers read both
  with `current_setting(..., true)`. When neither is set, the event carries `actor_id: null` and
  `change_source: "out_of_band"`.
- **Source registry.** Each trigger checks a small `platform.audit_event_sources` table
  (`source_id`, `enabled`) before writing. Migrations install triggers for every supported
  source. Enabling a source flips a row and needs no DDL.
- **Supported sources.**

  | Source ID | Table and trigger | Events |
  | --- | --- | --- |
  | `recording.holds` | `camera_recording_holds` (base) | created, accepted, released, other updates |
  | `recording.policies` | `camera_recording_policies` (base) | insert, update of `mode`, `storage`, retention override fields, delete |
  | `recording.archive_settings` | `camera_recording_archive_settings` (base) | update of retention and budget fields |
  | `recording.storage_settings` | `camera_nvr_storage_settings` (base) | update of retention and budget fields |
  | `recording.dispositions` | `camera_recording_dispositions` (base) | insert |
  | `recording.camera_availability` | `camera_sources` (base) | update of `availability_status` |
  | `recording.access` | `camera_recording_access_audits` (base) | insert |
  | `paper_trail:<Resource>` | `<table>_versions` | insert; delete (see D4) |
  | `ash_events:<Resource>` | `api_events` filtered by `resource` | insert; delete (see D4) |

  The `recording.*` sources use base-table triggers, so they work even for writes that skip
  PaperTrail.
- **Block events.** `camera_recording_catalog` gets a separate trigger that emits
  `block.cataloged` on INSERT of a sealed row, and `block.archive_verified` when `archive_state`
  changes to `verified`.

### D2. Source selection from Helm, and scope events
- **Helm values.**

  ```yaml
  auditEvents:
    enabled: true                 # default follows nvr.enabled
    sources:
      recordingCustody: true      # all recording.* sources
      paperTrail: []              # e.g. [ServiceRadar.Identity.RoleBinding]
      ashEvents: []               # e.g. [ServiceRadar.Observability.StatefulAlertRule]
  ```

- **Sync at boot.** At boot, core reconciles `platform.audit_event_sources` with these values,
  setting `SET LOCAL serviceradar.change_source = 'configuration'`.
- **Scope events.** A trigger on `audit_event_sources` that cannot be disabled through the
  registry publishes `audit.scope.v1` for every change. Each scope event carries the source,
  before and after state, change source and actor. Turning off a source is therefore always
  announced.
- **Unknown resources.** A resource name in Helm that is not a supported PaperTrail or AshEvents
  resource fails chart validation in core at boot. It is logged and reported in capture status,
  and does not crash core.

### D3. Payload projection and redaction
- **Base-table sources** publish a whitelisted projection of columns as `before` and `after`.
- **PaperTrail sources** publish the version row's `version_action_type`, `version_source_id`,
  `changes` and actor fields.
- **AshEvents sources** publish `resource`, `action`, `record_id`, `changed_attributes`, actor
  and `metadata.source`.
- **Redaction.** Attribute values listed in the resource's PaperTrail `ignore_attributes`, or
  marked `sensitive?`, become `"[redacted]"`. The attribute name is kept, so the fact that it
  changed is still visible. A generated module per resource carries its redaction list and is
  tested.
- **Size cap.** Payloads are capped at 32 KiB. Above that, `changes` is replaced by
  `changes_sha256` and `truncated: true`.

### D4. Deletes of audit rows
- **Retention purges.** `AuditVersionRetentionWorker` and `ApiEvent.delete_older_than` set
  `change_source = 'retention'`. Their per-row deletes are suppressed. Each run instead publishes
  one `audit.retention_purged` summary per source, with count, cutoff and actor.
- **All other deletes.** Any other delete of a version or `api_events` row publishes a delete
  event with the old row's identifiers and `change_source` (`out_of_band` when unset).

### D5. Relay and capture status
- **Relay.** A coordinator-only relay, shaped like `ExposureOutboxRelay`, reads each outbox in
  `id` order in bounded batches. It publishes with
  `Nats-Msg-Id = <outbox>:<id>` and deletes rows only after PubAck.
- **Health metrics.** The relay reports depth and oldest-row age, and raises a health event when
  the oldest row is older than 10 minutes.
- **Capture status.** Every 60 s, core publishes `audit.capture.v1.status`:

  ```json
  {"schema_version":1,"published_at":"...","sources":[{"source_id":"recording.policies",
   "enabled":true,"trigger_state":"enabled","last_event_id":12345}],
   "outbox":{"depth":0,"oldest_age_s":0},"unknown_configured_sources":[]}
  ```

  `trigger_state` is read from `pg_trigger.tgenabled`, and is `missing` when the trigger has been
  dropped.

### D6. Envelope
Every message is JSON with these fields:
- `schema_version` (1);
- `event_id` (outbox id);
- `event_kind`, `source_id`;
- `occurred_at` (transaction timestamp, microseconds);
- `actor_id`, `change_source`;
- `source_table`, `source_id_value`;
- `camera_source_id` and `stream_profile_id` where they apply;
- the kind-specific fields from D1 and D3.

Block messages are at most 4 KiB. Audit messages are at most 32 KiB.

### D7. Streams
Both streams are core-owned, using file storage, limits retention, `max_age` of 7 days, a finite
`max_bytes` from chart values counted in the render-time budget, a 2-minute duplicate window, and
metadata `serviceradar.owner = core-elx`.
- `CAMERA_RECORDING_EVENTS` carries `camera.recording.>`.
- `AUDIT_CHANGE_EVENTS` carries `audit.changes.v1.>`, `audit.scope.v1` and
  `audit.capture.v1.status`.

### D8. Permissions
- **core-elx** may publish `camera.recording.>` and `audit.>`.
- **The new `CN=serviceradar-integrity-forwarder`** may:
  - create, read and ack consumers on the two streams, via
    `$JS.API.CONSUMER.*.<STREAM>.>` and `$JS.API.CONSUMER.MSG.NEXT.<STREAM>.>`;
  - subscribe to `integrity.rpc.evidence.>`;
  - publish `_INBOX.>`.

  It gets no other core subjects. Narrowing the broad `$JS.API.>` grant on the existing
  `serviceradar-vantage` identity is tracked separately.

### D9. Provider export action in web-ng
- **Capability probe.** web-ng probes `integrity.rpc.evidence.capabilities.v1` and fails closed.
- **Authorization and audit.** It checks `devices.cameras.recordings.hold` plus camera scope,
  writes the `evidence_exported` access-audit row, then calls `integrity.rpc.evidence.bundle.v1`.
- **No bundle storage.** web-ng never builds or stores the bundle itself.

## Risks / Trade-offs

- **Trigger write cost.** Custody and version tables are low-rate. The catalog trigger adds one
  small insert per block. A registry lookup per write is an index probe on a tiny table.
- **A superuser can still disable triggers.** That cannot be prevented here. The trigger state is
  in every capture-status message, and a consumer that stops receiving status sees the silence.
- **Outbox growth while NATS is down.** A max-rows guard raises a critical health event. Rows are
  never dropped.
- **Payload privacy.** Hold `reason` text and audit `changes` may contain case or configuration
  detail. Sensitive attributes are redacted, and the streams are readable only by the identities
  granted above.

## Migration Plan

1. The migration adds the outbox tables, the source registry, and the triggers with every
   source disabled. The relay waits for its streams to exist.
2. Core creates the streams and syncs sources from Helm at boot when `auditEvents.enabled` or
   recording is enabled.
3. To roll back, disable the values. The sources flip to disabled, which is announced on
   `audit.scope.v1`, and the triggers stop writing.

## Open Questions

- Should block events also back-publish catalog rows created before the migration? Proposed: no.
- Should the 32 KiB cap be configurable per source?
