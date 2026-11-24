## ADDED Requirements

### Requirement: Event-triggered async VLM action captioning for Smart event clips
The system SHALL trigger asynchronous multi-frame VLM action captioning exclusively for sealed, non-quarantined `RecordingCatalogEntry` spans on caption-enabled `CameraRecordingPolicy` cameras where Stage 1 detection identified at least one Smart category (`person`, `animal`, `vehicle`, or `package`), persisting a durable CNPG outbox row (`platform.camera_visual_caption_jobs`) before publishing a metadata-only job envelope to NATS JetStream (`media.jobs.visual_caption.v1`) and projecting worker outputs idempotently from `media.results.visual_caption.v1` into `platform.camera_visual_clip_captions`.

#### Scenario: Smart detection span enqueues async caption job without blocking visual indexing
- **WHEN** `VisualIndexResultProjector` completes visual indexing for a sealed, playable `RecordingCatalogEntry` on a caption-enabled policy containing a detected `person`, `animal`, `vehicle`, or `package`
- **THEN** the system SHALL complete `VisualIndexJob` and surface thumbnails and detections immediately without waiting for VLM inference
- **AND** SHALL persist an idempotent `platform.camera_visual_caption_jobs` row keyed by `(catalog_entry_id, start_us, end_us, vlm_model_id, prompt_version)` and publish a metadata-only envelope to `media.jobs.visual_caption.v1` containing no media bytes or storage credentials

#### Scenario: Motion-only or empty recording block does not trigger VLM captioning
- **WHEN** `VisualIndexResultProjector` completes visual indexing for a `RecordingCatalogEntry` containing only raw motion or zero Smart detections (`person`, `animal`, `vehicle`, `package`)
- **THEN** the system SHALL NOT create a `platform.camera_visual_caption_jobs` row or enqueue any VLM inference work

#### Scenario: Redelivered JetStream caption result is projected idempotently
- **WHEN** a worker publishes a valid `media.results.visual_caption.v1` envelope containing `caption_text`, `action_tags`, and L2-normalized `caption_embedding` and the message is redelivered
- **THEN** `VisualCaptionResultProjector` SHALL upsert `platform.camera_visual_clip_captions` idempotently by `(catalog_entry_id, start_us, end_us, vlm_model_id, prompt_version)` without creating duplicate caption rows or allowing direct worker writes to CNPG

#### Scenario: Bounded historical backfill captions existing playable Smart clips
- **WHEN** an operator triggers bounded VLM caption backfill for a camera or policy
- **THEN** `VisualCaptionBackfill` SHALL enqueue `platform.camera_visual_caption_jobs` only for existing playable, non-quarantined `RecordingCatalogEntry` spans that contain Smart detections and lack a caption for the active `(vlm_model_id, prompt_version)`

### Requirement: Hybrid Reciprocal Rank Fusion search over visual embeddings and action captions
The system SHALL execute hybrid search in `ServiceRadar.Camera.SemanticSearch` using Reciprocal Rank Fusion (RRF) across pre-filtered `platform.camera_visual_clip_captions` PostgreSQL `websearch_to_tsquery` full-text matches, `caption_embedding` `pgvector` cosine matches, and existing `platform.camera_visual_embeddings` visual crop/scene cosine matches while enforcing `devices.view`, `devices.cameras.recordings.view`, authorized `ServiceRadar.Camera.Source` pre-filtering, and `RecordingAccessAudit` logging before any database or embedder execution.

#### Scenario: Natural-language action query matches captioned Smart clip via hybrid RRF
- **WHEN** an authorized operator searches for `"child doing pushups"`, `"delivery driver leaving a box"`, or `"dog sitting on the porch at night"` over a bounded time window
- **THEN** `SemanticSearch` SHALL pre-filter authorized `camera_source_id` values and playable non-quarantined `RecordingCatalogEntry` rows across both `camera_visual_clip_captions` (full-text `caption_tsv` and vector `caption_embedding`) and `camera_visual_embeddings`, fuse ranked candidates via Reciprocal Rank Fusion, and return ranked clip hits including `caption_text`, `action_tags`, capture-time camera labels, explicit `time_basis`, and normalized anchor bounding boxes

#### Scenario: Semantic synonym matches action caption via caption embedding vector
- **WHEN** an authorized operator searches for `"working out on the porch"` and a Smart clip is captioned `"A child doing pushups on the porch at night"`
- **THEN** the `caption_embedding` cosine similarity leg SHALL retrieve the captioned clip even without exact keyword overlap and fuse it into the ranked RRF results

#### Scenario: Unauthorized caller or out-of-scope camera is excluded before caption search
- **WHEN** a caller lacks `devices.view` or `devices.cameras.recordings.view` or requests a `camera_source_id` outside their authorized `Source` scope
- **THEN** `SemanticSearch` SHALL reject the request with `403 Forbidden` before querying `platform.camera_visual_clip_captions`, `platform.camera_visual_embeddings`, or the text embedder and SHALL leak zero caption text, tags, or scores from unauthorized cameras

### Requirement: Action caption retention purge, quarantine exclusion, and hold preservation
The system SHALL bind `platform.camera_visual_clip_captions` and `platform.camera_visual_caption_jobs` strictly to the retention, quarantine, and hold lifecycle of `platform.camera_recording_catalog` so deleted or quarantined footage can never surface via caption full-text or vector search while held evidence remains searchable.

#### Scenario: Terminal retention deletion or quarantine purges captions immediately
- **WHEN** a `RecordingCatalogEntry` reaches terminal deletion (`local_state = :reclaimed` and `archive_state` in `:deleted` or `:not_required`) or transitions to `local_state = :quarantined`
- **THEN** the system SHALL immediately delete all associated `platform.camera_visual_clip_captions` rows and cancel any pending or dispatched `platform.camera_visual_caption_jobs` rows for that `catalog_entry_id`

#### Scenario: Evidence hold preserves searchable action captions
- **WHEN** an accepted `RecordingHold` pins at least one verified copy of a `RecordingCatalogEntry` past normal retention limits
- **THEN** its `platform.camera_visual_clip_captions` rows SHALL remain intact and searchable via hybrid RRF search until the hold is released and all copies reach terminal deletion

### Requirement: Action caption surfacing on clip cards and playback modal
The system SHALL include `caption_text` and `action_tags` on semantic search hit responses and Smart event clip projections and SHALL render them on clip cards and inside the Clip Playback Modal without modifying underlying recorded media.

#### Scenario: Operator inspects captioned clip in search results and playback modal
- **WHEN** an authorized operator views a captioned Smart clip in search results or the camera recordings clip grid and opens the Clip Playback Modal
- **THEN** the UI SHALL display the clip's `caption_text` on the clip card and show the full `caption_text` and `action_tags` inside the Clip Playback Modal alongside timeline playback and non-destructive bounding-box overlays

### Requirement: Model-versioned 1152-d SigLIP2 visual embedder upgrade coexistence
The system SHALL support `siglip2-so400m-p14-384` (`1152`-d) visual and caption embeddings with dedicated `vector(1152)` HNSW cosine indexing alongside existing `768`-d `siglip-b16-384` rows, enforcing strict `(model_id, model_version, embedding_dim)` isolation during search and bounded historical backfill.

#### Scenario: 1152-d SigLIP2 backfill coexists with 768-d rows without cross-dimension mixing
- **WHEN** an operator deploys `siglip2-so400m-p14-384` (`1152`-d) and triggers bounded `VisualIndexBackfill` on a cluster containing existing `768`-d `siglip-b16-384` rows
- **THEN** the system SHALL store `1152`-d embeddings in `platform.camera_visual_embeddings` and `platform.camera_visual_clip_captions` indexed by partial `vector(1152)` HNSW cosine indexes without overwriting `768`-d rows
- **AND** `SemanticSearch` SHALL restrict vector comparisons strictly to rows matching the active `(model_id, model_version, embedding_dim)`
