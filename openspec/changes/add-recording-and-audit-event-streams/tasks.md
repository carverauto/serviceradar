# Tasks: recording lifecycle and configurable audit event streams

## 1. Outbox, registry and triggers
- [ ] 1.1 Migration: `camera_recording_event_outbox`, `audit_event_outbox`, `audit_event_sources` (with its unconditional scope trigger)
- [ ] 1.2 Base-table trigger functions for the seven `recording.*` sources and the catalog block events, with whitelisted projections
- [ ] 1.3 Generic triggers for PaperTrail `<table>_versions` (insert, delete) and `api_events` (insert, delete, filtered by resource), gated by the registry
- [ ] 1.4 `SET LOCAL serviceradar.actor_id` / `serviceradar.change_source` in audited actions, the retention workers (`retention`), and the boot sync (`configuration`)
- [ ] 1.5 Per-resource redaction lists from PaperTrail `ignore_attributes` and `sensitive?`; 32 KiB cap with `changes_sha256`
- [ ] 1.6 Retention-purge summary events in `AuditVersionRetentionWorker` and `ApiEvent.delete_older_than`

## 2. Streams, relay and status
- [ ] 2.1 Core-owned `CAMERA_RECORDING_EVENTS` and `AUDIT_CHANGE_EVENTS` creation and shape reconcile
- [ ] 2.2 Coordinator relay for both outboxes: bounded batches, `Nats-Msg-Id`, delete after PubAck, depth/age metrics and health event
- [ ] 2.3 Boot sync of `auditEvents.sources` into the registry; validation of resource names
- [ ] 2.4 `audit.capture.v1.status` publisher reading `pg_trigger`
- [ ] 2.5 Golden JSON fixtures for every event kind

## 3. Helm and permissions
- [ ] 3.1 Values `auditEvents.*` and `cameraRecordingEvents.*`; stream sizes in the render-time budget and non-Helm presets
- [ ] 3.2 `_nats_static_users.tpl`: core publish grants; `serviceradar-integrity-forwarder` user
- [ ] 3.3 Extend `//helm/serviceradar:nats_static_user_permissions_test`

## 4. web-ng provider export
- [ ] 4.1 `evidence_exported` access-audit kind (resource and check constraint migration)
- [ ] 4.2 Capability-gated export action on accepted holds via `vantage.rpc.evidence.capabilities.v1` and `vantage.rpc.evidence.bundle.v1`
- [ ] 4.3 LiveView tests: provider absent, unauthorized, authorized export

## 5. Docs and validation
- [ ] 5.1 Integrator docs for the subjects, envelope, source IDs and capture status (contract only)
- [ ] 5.2 Core tests: triggers (action and out-of-band writes, rollback), registry scope events, redaction, purge summaries, relay, capture status
- [ ] 5.3 `openspec validate add-recording-and-audit-event-streams --strict`
