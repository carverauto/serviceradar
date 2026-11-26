## ADDED Requirements

### Requirement: Pre-enablement security and read-grant ownership verification
The system SHALL verify job ownership (`job_id` belongs to `catalog_entry_id`) and frozen `descriptor_sha256` before cancelling or mutating any `platform.camera_visual_index_jobs` row in `VisualWorkerReadGrants`, and SHALL restrict NATS visual-index job, result, live-track, and text-embedding RPC subjects exclusively to authorized Core and `serviceradar-media-worker` identities.

#### Scenario: Read grant request with mismatched job and catalog entry is rejected without mutating job state
- **WHEN** an authenticated worker submits a read-grant request where `job_id` belongs to a different `catalog_entry_id` or supplies a mismatched `descriptor_sha256`
- **THEN** `VisualWorkerReadGrants` SHALL reject the request with an authorization or mismatch error before invoking `maybe_cancel_job`
- **AND** the unrelated job row SHALL remain untouched

#### Scenario: Non-media NATS identities cannot access visual search or live track subjects
- **WHEN** non-media components (such as telemetry collectors, agents, or legacy org identities) connect to NATS
- **THEN** their NATS permissions SHALL NOT grant publish or subscribe access to `media.jobs.visual_index.>`, `media.results.visual_index.>`, `media.rpc.visual_text_embed.>`, or `media.events.live_tracks.>`

### Requirement: Decoupled detector identity and structured sub-crop attributes
The system SHALL decouple `detector_model_id` and `detector_model_version` from `embedder_model_id` and `embedder_model_version` across Core dispatch, Helm configuration, and `serviceradar-media-worker`, and SHALL store structured sub-crop attributes (`upper_color`, `lower_color`, `object_class`, `track_id`) alongside each detection.

#### Scenario: Detector and embedder upgrades do not invalidate unrelated model identity
- **WHEN** an operator upgrades `detector_model_id` (such as `"yolox-s"`) while keeping `embedder_model_id = "siglip-b16-384"`
- **THEN** Core and Helm SHALL validate both `(detector_model_id, detector_model_version)` and `(embedder_model_id, embedder_model_version)` independently without blocking detector weight mounts

### Requirement: Partitioned halfvec visual embedding storage and high-throughput dispatch
The system SHALL store `platform.camera_visual_embeddings` in `timeline_ts_us`-partitioned PostgreSQL 18 tables using `halfvec(768)` HNSW indexes, maintain a composite `(state, deadline_at)` index on `platform.camera_visual_index_jobs`, and sustain outbox dispatch throughput above 318 jobs/s continuous arrival with at least 500 jobs/s burst drain via event-driven or sharded parallel dispatch (replacing the 16.7 jobs/s ceiling) without losing carried-forward validity intervals.

#### Scenario: Retention drop removes expired embedding partition without HNSW tombstone bloat
- **WHEN** a daily or weekly time-range partition of `platform.camera_visual_embeddings` ages past its configured retention window and holds no active `RecordingHold` rows
- **THEN** retention maintenance SHALL drop the expired partition directly rather than executing unpartitioned row-by-row HNSW `DELETE` and `VACUUM` sweeps

#### Scenario: Burst block sealing at 8,000-camera rate does not lag outbox dispatch
- **WHEN** 8,000 cameras seal blocks at 318 blocks/s (`4 Mbit/s`, `12 MiB` ceiling)
- **THEN** `VisualIndexDispatchWorker` (aided by Tier-1 metadata gating and parallel/event-driven batching) SHALL drain admitted pending jobs without falling behind steady-state arrival rate
- **AND** expired-job reconciliation SHALL use the `(state, deadline_at)` index
