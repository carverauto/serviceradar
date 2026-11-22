## ADDED Requirements

### Requirement: Per-policy opt-in visual keyframe indexing and durable outbox admission
The system SHALL make recorded-video visual indexing opt-in per `CameraRecordingPolicy` (`visual_index_mode: :off | :keyframes`, default `:off`) and SHALL persist a durable CNPG outbox job (`platform.camera_visual_index_jobs`) before publishing metadata-only work to NATS JetStream (`media.jobs.visual_index.v1`) only for sealed, non-quarantined `RecordingCatalogEntry` blocks.

#### Scenario: Sealed block on indexing-enabled policy enqueues outbox job
- **WHEN** Core freezes and catalogs a sealed `RecordingCatalogEntry` (`local_state = present` or `archive_state = verified`) for a `CameraRecordingPolicy` with `visual_index_mode = :keyframes`
- **THEN** the system SHALL create an idempotent `platform.camera_visual_index_jobs` row keyed by `(catalog_entry_id, model_id, model_version)` and publish a metadata-only job envelope to `media.jobs.visual_index.v1` containing no media bytes or storage credentials

#### Scenario: Policy with visual indexing disabled creates no jobs
- **WHEN** Core registers a sealed `RecordingCatalogEntry` for a `CameraRecordingPolicy` with `visual_index_mode = :off` or with no policy row
- **THEN** the system SHALL NOT create a `platform.camera_visual_index_jobs` row or enqueue any GPU worker message

#### Scenario: Quarantined catalog entry is never admitted for visual indexing
- **WHEN** Core or the NVR reconciler registers or transitions a `RecordingCatalogEntry` with `local_state = :quarantined`
- **THEN** the system SHALL NOT enqueue a visual index job for that entry and SHALL cancel any pending job

#### Scenario: Exhausted worker retries reconcile to explicit terminal state
- **WHEN** a `media.jobs.visual_index.v1` job reaches `MaxDeliver` or exceeds its attempt budget without verified result ingestion
- **THEN** the outbox reconciler SHALL transition the `platform.camera_visual_index_jobs` row to `:failed_terminal` with a bounded error class and record a deduplicated health check via `TripwireHealth` rather than retrying indefinitely

### Requirement: Two-stage cropped subject and scene keyframe embeddings
The system SHALL index sampled IDR keyframes using a two-stage pipeline that combines localized foreground subject crop embeddings (`person`, `vehicle`, `bicycle`, `animal`, `package`) with full-scene keyframe embeddings tagged by explicit `(model_id, model_version, embedding_dim)`, and SHALL ingest worker outputs exclusively through NATS JetStream (`media.results.visual_index.v1`) into CNPG `pgvector` projections idempotently.

#### Scenario: Small foreground subject in wide-angle keyframe produces crop and scene embeddings
- **WHEN** `serviceradar-media-worker` processes a sampled IDR keyframe containing a detected foreground subject (such as a person in a wide-angle parking-lot scene)
- **THEN** Stage 1 SHALL extract bounded normalized `[x1, y1, x2, y2]` subject crops alongside the full-scene frame, Stage 2 SHALL compute L2-normalized embeddings for both the full scene (`embedding_kind = :scene`) and each admitted crop (`embedding_kind = :crop`) with structured class, confidence, and optional color attributes, and the worker SHALL publish the batch to `media.results.visual_index.v1` without writing directly to CNPG

#### Scenario: Redelivered JetStream result batch is ingested idempotently
- **WHEN** a worker crashes after publishing to `media.results.visual_index.v1` and a redelivered attempt publishes results for the same `(catalog_entry_id, model_id, model_version)`
- **THEN** the Core projection consumer SHALL upsert `platform.camera_visual_frames` and `platform.camera_visual_embeddings` idempotently by stable frame and crop identity, exposing at most one canonical projection set per `(catalog_entry_id, model_id, model_version)`

### Requirement: Pre-filtered authorized semantic clip search and access audit
The system SHALL enforce `devices.view` and `devices.cameras.recordings.view` permissions and pre-filter the caller's authorized `ServiceRadar.Camera.Source` scope and bounded time window before executing `pgvector` cosine similarity search, returning only playable non-quarantined clips with capture-time camera labels and explicit `time_basis` metadata while recording an append-only `RecordingAccessAudit` (`event_kind: :semantic_search`).

#### Scenario: Scoped operator searches across authorized cameras
- **WHEN** an authenticated user with `devices.view` and `devices.cameras.recordings.view` submits a semantic query (such as `"person in red dress"`) over a bounded time window
- **THEN** the search service SHALL resolve the caller's authorized camera `Source` IDs first, restrict `pgvector` HNSW cosine k-NN execution to those `camera_source_id` values and playable non-quarantined `RecordingCatalogEntry` rows, return bounded ranked hits with capture-time labels, explicit `time_basis` (`received` or `camera_reported`), normalized crop boxes, and seekable timeline intervals, and append a `RecordingAccessAudit` row with `event_kind = :semantic_search`

#### Scenario: Live-only viewer without recording playback permission is denied
- **WHEN** a user who holds live camera viewing permission but lacks `devices.cameras.recordings.view` requests `/api/cameras/search` or submits a LiveView semantic clip search
- **THEN** the system SHALL reject the request with `403 Forbidden` before invoking the text embedder or querying `platform.camera_visual_embeddings`

#### Scenario: Requested camera outside caller scope is excluded before vector search
- **WHEN** an operator filters semantic clip search by a `camera_source_id` outside their authorized `Source` scope
- **THEN** the system SHALL deny or exclude that camera before `pgvector` execution and SHALL leak zero similarity scores, timestamps, or bounding boxes from unauthorized cameras

### Requirement: Retention purge, quarantine exclusion and hold preservation of visual indexes
The system SHALL couple `platform.camera_visual_frames` and `platform.camera_visual_embeddings` strictly to the retention, quarantine, and hold lifecycle of `platform.camera_recording_catalog` so deleted or quarantined footage can never surface in semantic search while held evidence remains searchable.

#### Scenario: Terminal retention or capacity deletion purges visual embeddings while catalog tombstone remains
- **WHEN** a `RecordingCatalogEntry` reaches terminal deletion with no remaining playable copy (`local_state = :reclaimed` and `archive_state` in `:deleted` or `:not_required`) while the catalog row is retained as a 90-day tombstone
- **THEN** the system SHALL immediately delete all associated `platform.camera_visual_frames`, `platform.camera_visual_embeddings`, and pending `platform.camera_visual_index_jobs` rows for that `catalog_entry_id` so deleted footage cannot match any subsequent semantic search

#### Scenario: In-place quarantine purges visual index state immediately
- **WHEN** an existing `RecordingCatalogEntry` transitions to `local_state = :quarantined` (including `quarantine_in_place` when an unverified archive binding loses retained history or is compromised)
- **THEN** the system SHALL immediately delete any visual frames, embeddings, and pending visual index jobs for that entry and exclude it from all search queries

#### Scenario: Accepted evidence hold preserves searchable embeddings with pinned copy
- **WHEN** an accepted `RecordingHold` pins at least one verified copy (`:archive` or `:local`) of a `RecordingCatalogEntry` past normal local or object retention limits
- **THEN** the `RecordingCatalogEntry` and its `platform.camera_visual_frames` and `platform.camera_visual_embeddings` rows SHALL remain intact and searchable until the hold is explicitly released and all copies reach terminal deletion

#### Scenario: Model-version backfill skips deleted and quarantined catalog entries
- **WHEN** an operator triggers bounded re-indexing for a new `(model_id, model_version)`
- **THEN** the backfill scheduler SHALL enqueue jobs only for currently playable, non-quarantined `RecordingCatalogEntry` rows and SHALL NOT revive or re-index reclaimed, deleted, or quarantined blocks

### Requirement: Timeline deep-link seek and non-destructive bounding-box player overlay
The system SHALL surface semantic clip search in `/cameras` and `/cameras/:camera_source_id/recordings`, deep-linking every hit into unified timeline playback (`mode=timeline`) with timeline hit markers and a non-destructive client-side SVG/canvas bounding-box overlay that leaves original fMP4 media bytes unmodified.

#### Scenario: Investigator clicks semantic search hit to seek timeline player with bounding-box overlay
- **WHEN** an authorized investigator clicks a semantic search result for `"person in red dress"` on `Gate C2 / Camera 07`
- **THEN** the UI SHALL navigate to `/cameras/:camera_source_id/recordings?mode=timeline&from=...&to=...&seek=...`, seek `CameraTimelinePlayer` to the matched keyframe timestamp labelled with its explicit `time_basis` (`received` or `camera_reported`), and render the matched normalized `[x1, y1, x2, y2]` subject bounding box and class/score badge in a client-side overlay aligned to the displayed video frame

#### Scenario: Operator toggles overlay visibility without re-encoding or altering source media
- **WHEN** an operator toggles bounding-box overlays on or off during timeline playback
- **THEN** `CameraTimelinePlayer` SHALL show or hide the client-side SVG/canvas overlay immediately without server-side video transcoding, burned-in rendering, or modification of cached/archived CMAF fragments
