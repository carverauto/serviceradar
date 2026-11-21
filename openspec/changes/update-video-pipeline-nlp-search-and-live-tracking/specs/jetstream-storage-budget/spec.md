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
The system SHALL bind `CAMERA_LIVE_TRACKS` (`media.events.live_tracks.v1`) to a finite `max_bytes` and `DiscardPolicy::Old` in every JetStream sizing profile so live object detection and tracking traffic cannot exhaust NATS file-store space or evict unrelated telemetry streams.

#### Scenario: Sustained live tracking burst respects finite stream cap
- **WHEN** live tracking publishes high-rate detection and track-summary events across active cameras
- **THEN** `CAMERA_LIVE_TRACKS` SHALL evict its oldest messages at its configured `max_bytes` ceiling without starving `CAMERA_MEDIA_JOBS`, `CAMERA_MEDIA_RESULTS`, or telemetry streams
