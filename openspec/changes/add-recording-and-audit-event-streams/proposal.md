# Change: Publish recording lifecycle and configurable audit events on JetStream

## Why

Recording blocks, holds, retention settings, deletions and other audited changes are visible
today only inside core-elx:

- Block cataloging is announced only through an in-process notify and Phoenix PubSub.
- AshPaperTrail version tables (45 resources) and the AshEvents `api_events` log are read only by
  the in-product audit history.
- Those audit records are purged after 180 days.
- Writes that bypass the Ash actions leave no audit record at all.

External services that need a durable, complete feed cannot follow the recording lifecycle or the
audit trail without reading core tables directly. Examples are SIEM and compliance archivers,
third-party VMS and evidence-management systems, and commercial add-ons such as the ServiceRadar
integrity forwarder. Reading the tables directly couples those services to internal schemas and
misses out-of-band changes.

## What Changes

- **Recording lifecycle events.** Add a core-owned stream `CAMERA_RECORDING_EVENTS` carrying
  `camera.recording.blocks.v1`. It publishes:
  - `block.cataloged`, with identity, timeline, time basis, `init_sha256` and
    `descriptor_sha256`;
  - `block.archive_verified`, with `receipt_sha256`.
- **Configurable audit event stream.** Add a core-owned stream `AUDIT_CHANGE_EVENTS` carrying
  `audit.changes.v1.<source_id>`. Operators choose sources through the Helm value
  `auditEvents.sources`. Three kinds of source exist:
  - **Recording custody sources**, captured by base-table triggers so that out-of-band SQL writes
    are recorded too: recording holds, recording policies, archive settings, NVR storage settings,
    recording dispositions, camera availability, and recording access audits. These are enabled
    by default whenever recording is enabled.
  - **PaperTrail sources**, `paper_trail:<Resource>`, captured by triggers on that resource's
    version table.
  - **AshEvents sources**, `ash_events:<Resource>`, captured by a trigger on `api_events`,
    filtered by resource.
- **Changes to coverage are themselves events.** The effective source set is synced from Helm
  into `platform.audit_event_sources` at boot. Every change to that table publishes
  `audit.scope.v1`, so narrowing what is audited is visible. Version-row deletes made by the
  retention workers publish a single summary event. Any other delete of an audit row publishes an
  event marked `change_source: "out_of_band"`.
- **Capture status.** Core publishes `audit.capture.v1.status` every 60 s with:
  - the effective source set;
  - each source's trigger state, read from `pg_trigger`;
  - the outbox depth and oldest-row age;
  - the last event ID.

  Consumers can therefore detect that a trigger was disabled or a source switched off.
- **Outbox delivery.** Every event is captured by a database trigger into an outbox in the same
  transaction as the change. A coordinator relay publishes with PubAck and deletes a row only once
  the stream acknowledges it.
- **Payload rules.**
  - Payloads respect each resource's PaperTrail `ignore_attributes` and Ash `sensitive?`
    attributes; values of those attributes are replaced with `"[redacted]"`.
  - Payloads never contain media, credentials, bucket names, endpoints or object keys.
  - Payloads over 32 KiB carry a digest of the full change instead of the change itself.
- **NATS identity.** Add a static NATS user `CN=serviceradar-integrity-forwarder` that may only
  consume `CAMERA_RECORDING_EVENTS` and `AUDIT_CHANGE_EVENTS`, read the capture status, and serve
  `vantage.rpc.evidence.>`. Core gains publish rights on `camera.recording.>` and `audit.>`.
- **web-ng export action.**
  - **Gating:** when a provider answers `vantage.rpc.evidence.capabilities.v1` with
    `evidence_bundle_export`, web-ng shows an "Export evidence bundle" action on accepted holds.
  - **Audit and forwarding:** it records a new `RecordingAccessAudit` kind, `evidence_exported`,
    then forwards the request over `vantage.rpc.evidence.bundle.v1`.
  - **No provider:** without that answer, nothing is shown.

## Impact

- **Affected specs:** new `camera-recording-events` and `audit-event-stream`.
- **Related changes and specs:**
  - builds on the catalog, holds and dispositions from `add-nvr-retention-and-timeline-playback`;
  - builds on the settings from `add-nvr-operator-settings`;
  - builds on the AshEvents adoption boundary from `add-ash-events-audit-log`;
  - follows `jetstream-storage-budget` for stream sizing and ownership.
- **Affected code:**
  - `elixir/serviceradar_core`: outbox table, trigger functions, source registry sync, actor
    context in audited actions, relay, capture-status publisher, retention-worker summary
    events, stream ownership.
  - `elixir/web-ng`: provider export action and the new access-audit kind.
  - `helm/serviceradar`: `auditEvents.*` and `cameraRecordingEvents.*` values, stream sizes in the
    render-time budget, `_nats_static_users.tpl`, and `nats_static_user_permissions_test`.
- **Storage:** a few hundred bytes per block and per audited change. Both streams have finite
  `max_bytes`, and retention defaults to 7 days.
