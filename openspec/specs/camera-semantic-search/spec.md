# camera-semantic-search Specification

## Purpose
Opt-in semantic visual clip search over recorded camera keyframes. ServiceRadar covers per-policy outbox admission, RBAC and camera-scope pre-filtering with access auditing, retention, quarantine, and hold lifecycle alignment, and timeline deep-link player overlays. Query execution is served by the commercial Vantage addon over the documented `vantage.rpc.*` contract; without it, search fails closed.

## Requirements
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

### Requirement: Idempotent visual index result ingestion
The system SHALL ingest worker outputs exclusively through NATS JetStream (`media.results.visual_index.v1`) and SHALL project them into CNPG idempotently.

#### Scenario: Redelivered JetStream result batch is ingested idempotently
- **WHEN** a worker crashes after publishing to `media.results.visual_index.v1` and a redelivered attempt publishes results for the same `(catalog_entry_id, model_id, model_version)`
- **THEN** the Core projection consumer SHALL upsert `platform.camera_visual_frames` and `platform.camera_visual_embeddings` idempotently by stable frame and region identity, exposing at most one canonical projection set per `(catalog_entry_id, model_id, model_version)`

### Requirement: Pre-filtered authorized semantic clip search and access audit
The system SHALL enforce `devices.view` and `devices.cameras.recordings.view` permissions and resolve the caller's authorized `ServiceRadar.Camera.Source` scope and bounded time window in web-ng before forwarding a search to the Vantage provider over `vantage.rpc.semantic_search.v1`, SHALL forward only authorized `camera_source_id` values, and SHALL record an append-only `RecordingAccessAudit` (`event_kind: :semantic_search`) for every executed search.

#### Scenario: Scoped operator searches across authorized cameras
- **WHEN** an authenticated user with `devices.view` and `devices.cameras.recordings.view` submits a semantic query over a bounded time window
- **THEN** web-ng SHALL resolve the caller's authorized camera `Source` IDs first, send only those IDs to the Vantage provider, return the bounded hits with capture-time labels, explicit `time_basis` (`received` or `camera_reported`), and seekable timeline intervals, and append a `RecordingAccessAudit` row with `event_kind = :semantic_search`

#### Scenario: Live-only viewer without recording playback permission is denied
- **WHEN** a user who holds live camera viewing permission but lacks `devices.cameras.recordings.view` requests `/api/cameras/search` or submits a LiveView semantic clip search
- **THEN** the system SHALL reject the request with `403 Forbidden` before calling the Vantage provider

#### Scenario: Requested camera outside caller scope is excluded before the provider call
- **WHEN** an operator filters semantic clip search by a `camera_source_id` outside their authorized `Source` scope
- **THEN** web-ng SHALL deny the request before calling the Vantage provider and SHALL leak zero scores, timestamps, or bounding boxes from unauthorized cameras

#### Scenario: Search fails closed without the Vantage provider
- **WHEN** `SERVICERADAR_VANTAGE_RPC_ENABLED` is not `true`, or the provider does not answer
- **THEN** `/api/cameras/search` SHALL return `503` and the LiveView surfaces SHALL report search as unavailable, without any in-process fallback

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

