# Change: Publish camera recording lifecycle and custody events on JetStream

## Why

Recording blocks, holds, retention settings and deletions are visible today only
inside core-elx: block cataloging is announced through an in-process notify and
Phoenix PubSub, and hold, policy and settings history lives in AshPaperTrail
version tables that are purged after 180 days. Integrations that run as separate
services (third-party VMS and evidence-management systems, compliance archivers,
and commercial add-ons such as the Vantage provider) cannot follow the recording
lifecycle without reading core tables directly, which couples them to internal
schemas and misses changes made outside the Ash actions.

## What Changes

- Add a core-owned JetStream stream `CAMERA_RECORDING_EVENTS` with two subjects:
  - `camera.recording.blocks.v1`: one message when a block is cataloged and one
    when its archive copy is verified, carrying identity, timeline, time basis
    and the digests already frozen on the catalog row (`init_sha256`,
    `descriptor_sha256`) and archive receipt (`receipt_sha256`).
  - `camera.recording.custody.v1`: one message for each change to recording
    holds, recording policies, archive settings, NVR storage settings, recording
    dispositions, camera availability, and recording access audits, with actor,
    timestamp, and before/after values of the fields that affect retention or
    custody.
- Capture events with a database-trigger outbox in the same transaction as the
  change, so changes made outside the Ash actions are published too and are
  marked `change_source: "out_of_band"`. A relay publishes outbox rows with
  PubAck and deletes them only after acknowledgment.
- Grant `CN=serviceradar-vantage` a durable pull consumer on
  `CAMERA_RECORDING_EVENTS`, and core publish rights on `camera.recording.>`.
- web-ng: when a connected provider advertises the `evidence_bundle_export`
  capability, show an "Export evidence bundle" action on accepted holds, record a
  new `RecordingAccessAudit` kind `evidence_exported`, and forward the request to
  the provider over `vantage.rpc.evidence.bundle.v1`. Without the capability,
  nothing is shown.

No media bytes, storage credentials, bucket names or object keys are published.

## Impact

- Affected specs: new `camera-recording-events`.
- Related changes: builds on the catalog, holds and dispositions defined in
  `add-nvr-retention-and-timeline-playback` and the settings in
  `add-nvr-operator-settings`; follows `jetstream-storage-budget` for stream
  sizing and ownership.
- Affected code: `elixir/serviceradar_core` (migration for the outbox table and
  triggers, outbox relay, stream ownership, actor context in recording actions),
  `elixir/web-ng` (provider export action, access-audit kind),
  `helm/serviceradar` (stream sizing values, render-time budget,
  `_nats_static_users.tpl`, `nats_static_user_permissions_test`).
- Storage: a few hundred bytes per block and per custody change; 7-day default
  retention with a finite `max_bytes`.
