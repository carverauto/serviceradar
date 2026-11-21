## ADDED Requirements

### Requirement: Media worker streams honour environment size overrides and budget checks
The `serviceradar-media-worker` stream ensure logic SHALL read `max_bytes` and `num_replicas` from `SERVICERADAR_JS_CAMERA_MEDIA_JOBS_MAX_BYTES`, `SERVICERADAR_JS_CAMERA_MEDIA_RESULTS_MAX_BYTES`, and `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` (and matching `_REPLICAS` variables) rather than hardcoding `512 MiB` / `2 GiB`, and the Helm chart SHALL include all media-worker and live-tracking streams in its render-time 85% `max_file_store` budget check.

#### Scenario: Environment override governs CAMERA_MEDIA_RESULTS size
- **WHEN** `SERVICERADAR_JS_CAMERA_MEDIA_RESULTS_MAX_BYTES` is set to a positive integer above the `2 GiB` fallback
- **THEN** `serviceradar-media-worker` (via shared `serviceradar-nats`) SHALL create or reconcile `CAMERA_MEDIA_RESULTS` with that exact `max_bytes`
- **AND** an invalid non-positive or non-integer value SHALL fail worker startup explicitly

#### Scenario: Demo NATS profile fits media worker streams without over-budget error
- **WHEN** `mediaWorker.enabled` is set to `true` with `nats.jetstream.profile` set to `small` (`36G` `max_file_store` and `36Gi` PVC) rather than `30G`
- **THEN** `helm template` render-time JetStream budget validation SHALL pass below the 85% `max_file_store` ceiling

### Requirement: Live tracking event stream fits JetStream sizing profiles
The system SHALL bind `CAMERA_LIVE_TRACKS` (`media.events.live_tracks.v1`) to a finite `max_bytes` (honoring `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` and `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_REPLICAS`, defaulting to `512 MiB` / `1` replica in `small` pilot profiles to stay within the `28.50 GiB` 85% ceiling and `2-4 GiB` in `large` ~8,000-camera deployments with `max_age` 1800-3600 s) and `DiscardPolicy::Old` in every JetStream sizing profile so bounded live object detection and tracking traffic (`~75-150 KB/s` opt-in at `<= 1,000` cams or `~200-400 KB/s` fleet `0.5 fps` substream + Tier-2 gate) cannot exhaust NATS file-store space or evict unrelated telemetry streams.

#### Scenario: Sustained live tracking burst respects finite stream cap
- **WHEN** live tracking publishes bounded detection and track-summary events across active cameras (`~75-400 KB/s` steady or burst traffic)
- **THEN** `CAMERA_LIVE_TRACKS` SHALL evict its oldest messages at its configured `max_bytes` ceiling (`SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES`) without starving `CAMERA_MEDIA_JOBS`, `CAMERA_MEDIA_RESULTS`, or telemetry streams
- **AND** Helm render-time budget checks SHALL account for `CAMERA_LIVE_TRACKS` alongside `CAMERA_MEDIA_JOBS` and `CAMERA_MEDIA_RESULTS` against the 85% `max_file_store` ceiling
