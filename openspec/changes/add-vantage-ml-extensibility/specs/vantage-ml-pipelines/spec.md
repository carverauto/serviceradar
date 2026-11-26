## ADDED Requirements

### Requirement: Declarative Vantage ML pipeline definitions and camera targeting
The system SHALL persist declarative Vantage ML pipeline definitions in CNPG (`platform.camera_vantage_pipelines`, Ash resource `ServiceRadar.Camera.VantagePipeline`) declaring stable reverse-DNS `pipeline_id`, SemVer `version`, camera targeting (SRQL selector or policy binding), trigger specification (`on_sealed_block`, `on_stage1_detection` with object class and minimum confidence filters, or opt-in `live_keyframe_tap`), optional ROI zone masks, input mode (`full_frame`, `detection_crop`, or `multi_frame_track`), per-track and per-minute execution budgets, execution target (`camera_vlm` or external `vantage.worker.v1` capability with optional fallback), and a reference to a declared `signal_schema`.

#### Scenario: Pipeline triggers on Stage 1 vehicle detections within configured ROI
- **GIVEN** an enabled `VantagePipeline` targeting cameras matching `tag:gate-entry` with `trigger.kind = "on_stage1_detection"`, `trigger.object_classes = ["vehicle"]`, `trigger.min_confidence = 0.55`, and `input.mode = "detection_crop"`
- **WHEN** `VisualIndexResultProjector` projects a sealed block for `Gate West 01` containing a tracked `vehicle` detection (`confidence = 0.87`) inside the active ROI
- **THEN** the system SHALL admit an idempotent CNPG outbox job (`platform.camera_vantage_jobs`) keyed by `(pipeline_id, pipeline_version, catalog_entry_id, target_key)` within the pipeline's configured rate budget
- **AND** SHALL NOT admit a job for frames containing only non-matching classes (such as `person`) or detections outside the ROI

#### Scenario: Disabled or rate-exceeded pipeline sheds work without impacting recording
- **WHEN** a `VantagePipeline` is disabled or exceeds its `max_jobs_per_minute` budget during a traffic burst
- **THEN** the dispatcher SHALL drop or defer excess pipeline admissions with explicit telemetry counters
- **AND** continuous NVR recording, live viewer relays, and Stage 1/2 visual indexing SHALL continue uninterrupted

### Requirement: Generic retention-coupled Vantage observation store, JetStream ingestion, and OCSF projection
The system SHALL ingest custom Vantage ML pipeline results exclusively over NATS JetStream (`media.results.vantage.v1` on `CAMERA_MEDIA_RESULTS`) through a Core `EventWriter` processor into `platform.camera_vantage_observations` (`ServiceRadar.Camera.VantageObservation`), SHALL validate every observation's `attributes` against the pipeline's registered `signal_schema`, SHALL strictly couple recorded observations to `RecordingCatalogEntry` retention, quarantine, and hold lifecycles, and SHALL optionally project canonical OCSF events carrying `metadata.service_radar.signal_schema`.

#### Scenario: Valid worker observation is projected idempotently with OCSF event and searchable text
- **GIVEN** an active `VantageJob` for `Gate West 01` and a valid `media.results.vantage.v1` envelope reporting category `"license_plate"`, label `"SR-0100"`, normalized bbox `[0.42, 0.58, 0.51, 0.63]`, a `14 KiB` Baseline JFIF crop JPEG, and schema-valid `attributes` (`{"plate_text": "SR-0100", "region": "US-CO"}`)
- **WHEN** Core's `EventWriter` consumes the result envelope (and even if the same JetStream message is redelivered)
- **THEN** Core SHALL upsert at most one canonical `platform.camera_vantage_observations` row keyed by `observation_key`, populate `search_tsv`, mark the `VantageJob` completed, and emit a canonical OCSF event carrying `metadata.service_radar.signal_schema` so `StatefulAlertRule`s and Dashboard SDK `useDashboardEvents` receive it
- **AND** workers SHALL NEVER write directly to CNPG or StarRocks

#### Scenario: Schema violation or oversized crop is rejected cleanly
- **WHEN** a `media.results.vantage.v1` payload fails the pipeline's `signal_schema` validation, includes an out-of-bounds bbox, or carries a `crop_jpeg` exceeding `32 KiB`
- **THEN** the projector SHALL reject and dead-letter the invalid payload without persisting unvalidated attributes or crashing the consumer

#### Scenario: Terminal recording deletion or quarantine purges recorded observations while holds preserve them
- **WHEN** a `RecordingCatalogEntry` reaches terminal deletion or transitions to `local_state = :quarantined`
- **THEN** the system SHALL immediately delete all linked `platform.camera_vantage_observations` and cancel pending `platform.camera_vantage_jobs` for that `catalog_entry_id`
- **AND** when an accepted `RecordingHold` pins a verified copy of the block, its `platform.camera_vantage_observations` rows SHALL remain searchable until the hold is released

### Requirement: Ramp 1 declarative VLM pipelines over full-resolution cropped keyframes
The system SHALL support zero-code declarative VLM pipelines (`runner: "camera_vlm"`) executed by `serviceradar-media-worker` against the configured `serviceradar-camera-vlm` (`crane-serve` / `llama-server` / external OpenAI-compatible `/v1/chat/completions` endpoint using unified CNPG credentials and `ServiceRadar.HTTP.EgressClient`), extracting full-resolution cropped keyframes via scoped Fragment Read Grants rather than `480x270` full-scene thumbnails and validating structured JSON output against the pack's schema before publishing observations.

#### Scenario: Declarative VLM ALPR pipeline reads a plate from a full-resolution vehicle crop
- **GIVEN** a `VantagePipeline` with `runner: "camera_vlm"`, `input.mode: "detection_crop"`, `max_frames_per_track: 3`, and a versioned JSON prompt for license plate extraction
- **WHEN** `serviceradar-media-worker` executes the admitted `media.jobs.vantage.vlm.v1` job for a tracked vehicle on `Gate West 01`
- **THEN** the worker SHALL obtain a scoped Fragment Read Grant, verify fragment SHA-256 digests, decode up to 3 best-quality IDR keyframes at native resolution, extract padded vehicle crops (`<= 640px`, `<= 96 KiB`) only when bbox width meets `min_bbox_width_px`, invoke `camera_vlm` with thinking disabled and bounded `max_tokens`, apply multi-frame consensus over valid JSON responses, and publish normalized observations to `media.results.vantage.v1`

#### Scenario: Truncated or non-JSON VLM response is rejected without poisoning observations
- **WHEN** the VLM endpoint returns truncated `<think>` output, malformed JSON, or fields failing the pipeline's schema regex constraints
- **THEN** the worker SHALL reject the malformed output, increment bounded parse-failure metrics, and publish zero fabricated observations

### Requirement: Ramp 2 external Vantage Worker protocol and multi-language SDK
The system SHALL define an open, language-agnostic `vantage.worker.v1` protocol (JetStream capability-routed jobs `media.jobs.vantage.<capability_slug>.v1`, execution-time scoped Fragment Read Grants, SHA-256 fragment verification, heartbeat capability registration, and `media.results.vantage.v1` publication) accompanied by `serviceradar-sdk-vantage` providing a Rust core crate and Python PyO3 bindings plus a synthetic local development harness, so external ML pipelines (including copyleft or commercial engines) operate across a clean process and network boundary outside ServiceRadar OSS.

#### Scenario: External Rust or Python worker processes synthetic block with zero database credentials
- **GIVEN** an external worker built against `serviceradar-sdk-vantage` (Rust crate or Python PyO3 package) advertising capability `"vantage.alpr.v1"`
- **WHEN** Core dispatches a `VantageJob` to `media.jobs.vantage.vantage_alpr_v1.v1`
- **THEN** the SDK SHALL authenticate to `POST /v1/media/workers/read-grants`, fetch and SHA-256-verify `init.mp4` and sampled fragments, decode full-resolution RGB frames (exposed as zero-copy NumPy arrays in Python), invoke the author's `process_frame(ctx)` handler, validate returned observations, and publish to `media.results.vantage.v1` before acknowledging the JetStream message

#### Scenario: Local synthetic dev harness validates a worker without cluster infrastructure
- **WHEN** an author runs the `serviceradar-sdk-vantage` local harness (or `serviceradar-cli vantage dev --fixture ./synthetic-vehicle.mp4`)
- **THEN** the harness SHALL decode the synthetic clip locally, invoke `process_frame(ctx)` with identical `VantageFrameContext` geometry, validate emitted observations against the pack's `signal_schema`, and report pass/fail diagnostics without requiring NATS, CNPG, or Kubernetes

### Requirement: Authorized SRQL queries, Vantage search, and non-destructive timeline overlays for custom observations
The system SHALL expose `platform.camera_vantage_observations` through SRQL (`in:camera_observations` via `AshAdapter`), integrate observation full-text and attribute matching into `ServiceRadar.Camera.SemanticSearch` with `RecordingAccessAudit` logging, and render pack observations on Vantage's timeline scrubber rail and clip playback modal as non-destructive client-side overlays driven by the pack's `display_contract`.

#### Scenario: Authorized operator searches and queries custom ALPR observations
- **GIVEN** an authenticated user holding `devices.view` and `devices.cameras.recordings.view` authorized for `Gate West 01`
- **WHEN** the user searches `"SR-0100"` in Vantage search or runs `in:camera_observations category:license_plate label:SR-0100` via SRQL
- **THEN** the system SHALL pre-filter by the user's authorized camera `Source` IDs and playable non-quarantined recordings, return matching observations with capture-time camera labels, explicit `time_basis`, normalized bboxes, and deep-link seek timestamps, and record a `RecordingAccessAudit` entry
- **AND** clicking a result SHALL seek `CameraTimelinePlayer` to the observation timestamp and render its non-destructive bounding-box and label overlay without altering recorded media bytes

#### Scenario: Unauthorized viewer receives zero leaked observations
- **WHEN** a user lacking `devices.cameras.recordings.view` or lacking access to `Gate West 01` queries `in:camera_observations` or searches `"SR-0100"`
- **THEN** the system SHALL deny or exclude unauthorized cameras before querying `platform.camera_vantage_observations` and SHALL leak zero labels, crops, or timestamps

### Requirement: Forward-compatible live keyframe tap execution mode
The system SHALL design the `vantage.worker.v1` `VantageFrameContext` and `VantagePipeline` schema with an explicit `source_mode` (`recorded_block` or `live_keyframe_tap`) so Phase 3 can feed low-latency keyframes from the bounded camera-sharded live-tap lane (`longshore_mailbox`, `<= 8` frames/camera, drop-oldest backpressure) into the identical SDK `process_frame(ctx)` handler for real-time operational guidance (such as automated vehicle or equipment bay docking alignment) without breaking recorded-block pipelines or viewer relays.

#### Scenario: Same SDK worker handler operates in live keyframe tap mode under bounded backpressure
- **GIVEN** a `VantagePipeline` configured with `source_mode: "live_keyframe_tap"` targeting `Bay 04 Approach` and a worker built with `serviceradar-sdk-vantage` advertising `supported_source_modes: ["recorded_block", "live_keyframe_tap"]`
- **WHEN** live keyframes arrive from the camera-sharded bounded live-tap lane (`<= 8` frames/camera)
- **THEN** the worker's `process_frame(ctx)` handler SHALL receive `VantageFrameContext` with `source_mode = LiveKeyframeTap` and emit real-time observations to `media.results.vantage.v1` for immediate Vantage overlay and Dashboard SDK `useDashboardEvents` delivery
- **AND** if the worker stalls or crashes, excess frames SHALL be dropped at the camera mailbox with explicit drop metrics while live viewer playback and continuous recording remain unaffected

### Requirement: Reference Apache-2.0 ALPR Solution Pack with Ramp 1 to Ramp 2 upgradeability
The system SHALL ship a first-party Apache-2.0 reference ALPR Solution Pack (`io.serviceradar.vantage-alpr`) using strictly synthetic test fixtures that operates out-of-the-box on Ramp 1 (`camera_vlm`) and automatically upgrades job routing to Ramp 2 when a healthy external worker advertising `vantage.alpr.v1` is connected, without linking any AGPL or proprietary ALPR code into ServiceRadar OSS.

#### Scenario: ALPR pack runs on Ramp 1 by default and transitions cleanly to Ramp 2 worker
- **GIVEN** `io.serviceradar.vantage-alpr` installed with `worker_dependencies: [{capability: "vantage.alpr.v1", optional: true, fallback_runner: "camera_vlm"}]`
- **WHEN** no external `vantage.alpr.v1` worker is online
- **THEN** `VantagePipelineDispatcher` SHALL route vehicle crop jobs to the Ramp 1 `camera_vlm` lane
- **AND** when a healthy worker advertising `vantage.alpr.v1` registers, subsequent jobs SHALL route to `media.jobs.vantage.vantage_alpr_v1.v1` producing observations conforming to the identical `alpr_plate_read` signal schema, alert rules, and ALPR dashboard
