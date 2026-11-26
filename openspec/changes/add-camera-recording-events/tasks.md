# Tasks: camera recording lifecycle and custody events

## 1. Outbox and triggers
- [ ] 1.1 Migration: `platform.camera_recording_event_outbox` (id bigserial, event_kind, source_table, source_id, payload jsonb, occurred_at) and trigger functions for catalog, holds, policies, archive settings, NVR storage settings, dispositions, camera availability and access audits
- [ ] 1.2 Whitelisted column projections per source table; tests that no credential, receipt object key or bucket field reaches the payload
- [ ] 1.3 `SET LOCAL serviceradar.actor_id` / `serviceradar.change_source` in recording, hold, policy and settings actions; tests for action and out-of-band writes

## 2. Stream and relay
- [ ] 2.1 Core-owned `CAMERA_RECORDING_EVENTS` creation and shape reconcile with `serviceradar.owner = core-elx`
- [ ] 2.2 Coordinator relay: bounded batches, deterministic `Nats-Msg-Id`, delete after PubAck, depth and age metrics, health event past 10 minutes
- [ ] 2.3 Envelope builder with 4 KiB bound and schema_version 1; golden JSON fixtures for every event kind

## 3. Helm and permissions
- [ ] 3.1 Chart values `cameraRecordingEvents.enabled` (default follows `nvr.enabled`) and stream size; include in the render-time JetStream budget and non-Helm presets
- [ ] 3.2 `_nats_static_users.tpl`: core publish `camera.recording.>`; `serviceradar-vantage` consumer grants on `CAMERA_RECORDING_EVENTS`
- [ ] 3.3 Extend `//helm/serviceradar:nats_static_user_permissions_test`

## 4. web-ng provider export
- [ ] 4.1 `evidence_exported` access-audit kind (resource, check constraint migration)
- [ ] 4.2 Capability-gated export action on accepted holds calling `vantage.rpc.evidence.bundle.v1` through the provider client
- [ ] 4.3 LiveView tests for provider absent, unauthorized, and authorized export

## 5. Docs and validation
- [ ] 5.1 Document the two subjects and envelope fields for integrators in `docs/docs/` (contract only)
- [ ] 5.2 Bazel: core unit tests for triggers and relay, web-ng unit tests, helm tests
- [ ] 5.3 `openspec validate add-camera-recording-events --strict`
