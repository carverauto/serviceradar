## ADDED Requirements

### Requirement: Bounded full-resolution detection and ROI crop extraction from verified fragments
The system SHALL provide a bounded full-resolution crop extraction path in `serviceradar-media-core` and `serviceradar-media-worker` that decodes SHA-256-verified IDR keyframes at native camera resolution, enforces a configurable minimum detection pixel dimension (`min_bbox_width_px`), extracts padded normalized bounding-box or ROI crops before optional bounded downscaling (`<= 640px`, `<= 96 KiB` Baseline JFIF JPEG), and never relies on `480x270` full-scene thumbnails for OCR or fine-detail Vantage pipelines.

#### Scenario: Vehicle detection crop preserves readable native pixel density for ALPR
- **GIVEN** a `1920x1080` SHA-256-verified IDR keyframe containing a Stage 1 `vehicle` detection with normalized bbox `[0.30, 0.45, 0.55, 0.80]` (`480x378` native pixels)
- **WHEN** `serviceradar-media-core` extracts a crop with `crop_padding_ratio = 0.15`, `min_bbox_width_px = 96`, and `max_crop_dimension = 640`
- **THEN** the cropper SHALL slice the padded region directly from the native `1920x1080` decoded RGB frame (rather than from a `480x270` thumbnail) and encode a valid Baseline JFIF JPEG within `96 KiB`

#### Scenario: Undersized distant detection is skipped before VLM or worker inference
- **WHEN** a detected `vehicle` bbox in a decoded keyframe is narrower than `min_bbox_width_px`
- **THEN** the cropper SHALL skip inference for that crop with an explicit metric reason (`crop_below_min_dimension`) rather than wasting GPU capacity on an unreadable region

### Requirement: Generalized Vantage external worker capability admission and scoped read grants
The system SHALL extend `POST /v1/media/workers/read-grants` and the worker capability admission contract to support external `vantage.worker.v1` workloads authenticated with workload-scoped `vantage_worker` identities, advertising supported capabilities, `supported_source_modes` (`recorded_block`, `live_keyframe_tap`), execution backend, and model version metadata on `/readyz` and `media.workers.heartbeat.v1`, while issuing strictly catalog-entry-scoped `:reader`-only S3 or low-priority local NVR read grants bound to active `VantageJob` rows.

#### Scenario: Authenticated external Vantage worker receives catalog-entry-scoped read grant
- **GIVEN** an authenticated `vantage_worker` workload pulling an active `VantageJob` from `media.jobs.vantage.vantage_alpr_v1.v1`
- **WHEN** the worker posts to `POST /v1/media/workers/read-grants` naming `job_id`, `catalog_entry_id`, and `descriptor_sha256`
- **THEN** the grant endpoint SHALL verify the `vantage_worker` workload identity, confirm the referenced `VantageJob` is active and the `RecordingCatalogEntry` is playable and non-quarantined, and return only the short-lived `:reader`-only S3 grant or local NVR analysis token and frozen SHA-256 digests for the sampled fragment byte ranges

#### Scenario: Unmatched job or revoked worker identity is refused read access
- **WHEN** a worker requests a read grant for a `catalog_entry_id` with no active `VantageJob`, a mismatched `descriptor_sha256`, or an unauthorized/expired workload identity
- **THEN** the grant endpoint SHALL fail closed (`401`/`403`/`410`) and issue zero storage credentials or presigned URLs

### Requirement: Forward-compatible live keyframe tap frame contract for external workers
The system SHALL define a canonical `vantage.worker.v1` frame envelope carrying `source_mode` (`recorded_block` or `live_keyframe_tap`), `camera_source_id`, `stream_profile_id`, `frame_sequence`, `timeline_ts_us`, `time_basis`, optional `catalog_entry_id`, optional upstream Stage 1 detections, and bounded frame bytes or scoped read reference so Phase 3 live keyframe tap feeders can stream bounded frames from `longshore_mailbox` camera lanes into external Vantage workers without altering worker handler interfaces or jeopardizing live viewing and recording.

#### Scenario: Live keyframe tap mailbox drops excess frames without stalling recording or viewers
- **WHEN** a `live_keyframe_tap` worker cannot keep pace with incoming keyframes on `Bay 04 Approach` and the per-camera `longshore_mailbox` reaches its `8`-frame bound
- **THEN** the feeder SHALL drop oldest queued frames with explicit drop metrics (`serviceradar_vantage_live_tap_dropped_total`)
- **AND** Membrane live viewer playback and continuous CMAF recording for `Bay 04 Approach` SHALL continue without backpressure or frame stalls
