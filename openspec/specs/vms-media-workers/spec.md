# vms-media-workers Specification

## Purpose
Standalone multi-architecture Rust GPU media workers (`serviceradar-media-worker`) for recorded-video keyframe decoding, neural inference, execution-time scoped fragment read grants with mandatory SHA-256 verification, and reserved interactive text-embedding RPC capacity.

## Requirements
### Requirement: Standalone GPU media worker capability admission
The system SHALL execute recorded-block visual decoding and neural inference in a standalone multi-architecture (`linux/amd64` and `linux/arm64`) `serviceradar-media-worker` OS process outside the BEAM ERTS cluster, and SHALL admit jobs only after verifying the configured hardware execution provider, model artifact SHA-256 digests, and GPU sharing class at startup without silent CPU fallback.

#### Scenario: Verified GPU execution provider startup admission
- **WHEN** `serviceradar-media-worker` starts with `execution_backend` set to `tensorrt` or `cuda` on an `amd64` or `arm64` GPU node
- **THEN** the worker SHALL verify the pinned detector and vision-language model SHA-256 digests, execute a synthetic forward-pass self-test on the configured execution provider, and report the observed architecture, driver/CUDA version, GPU sharing class (`physical`, `mig`, or `time_sliced`), and loaded `(model_id, model_version, embedding_dim)` before pulling jobs from `media.jobs.visual_index.v1`

#### Scenario: Missing GPU runtime or unsupported execution provider fails closed
- **WHEN** `serviceradar-media-worker` is configured for `tensorrt` or `cuda` acceleration and the NVIDIA device plugin, CUDA/TensorRT runtime, or device memory check fails initialization
- **THEN** the worker SHALL fail readiness explicitly and refuse to pull visual indexing jobs
- **AND** the worker SHALL NOT fall back to unbounded CPU inference unless `execution_backend` is explicitly configured as `cpu_explicit` with bounded single-worker concurrency

#### Scenario: Media worker crash or exhaustion isolates recording and live playback
- **WHEN** all `serviceradar-media-worker` replicas crash, restart, or saturate their GPU concurrency semaphore
- **THEN** continuous NVR capture, archive uploads, live camera relay sessions, and recorded HLS timeline playback SHALL continue operating normally in the BEAM cluster without interruption

### Requirement: Execution-time scoped fragment read grants and digest verification
The system SHALL issue short-lived, catalog-entry-scoped fragment read grants to authenticated `serviceradar-media-worker` workloads at job execution time, restricting archive access to `:reader`-only (`GET`, `HEAD`) `CredentialBrokerGrant` leases resolved from `platform.network_credential_secrets` for `longshore` byte-range reads or dedicated low-priority NVR analysis read slots, and SHALL verify every fetched `init.mp4` and fragment byte range against the frozen descriptor SHA-256 before decoding.

#### Scenario: Ranged archive keyframe fetch through short-lived reader grant
- **WHEN** a `serviceradar-media-worker` instance requests an execution-time read grant for an active visual index job whose `RecordingCatalogEntry` is served from S3-compatible object storage
- **THEN** the grant endpoint SHALL authenticate the `media_worker` workload identity, resolve a short-lived `:reader`-only (`GET`, `HEAD`) `CredentialBrokerGrant` through `ArchiveCredentialResolver` from `platform.network_credential_secrets` locked to the binding's HTTPS host, bucket, and prefix, and return only the sampled keyframe fragment byte ranges and frozen SHA-256 digests
- **AND** the worker SHALL fetch `init.mp4` and the sampled fragment byte ranges via `longshore` without downloading unsampled fragments or reading any Kubernetes Secret for bucket credentials

#### Scenario: Local NVR keyframe fetch isolated from interactive playback slots
- **WHEN** a `serviceradar-media-worker` instance executes a visual index job whose `RecordingCatalogEntry` has `local_state = present` on a reachable NVR member
- **THEN** the worker SHALL fetch `init.mp4` and sampled keyframe fragments from the NVR read listener using a short-lived token bound to `(storage_id, block_key)` inside a dedicated low-priority analysis read pool
- **AND** analysis reads SHALL NOT consume slots from the NVR interactive viewer playback read pool or archive upload read pool

#### Scenario: Fragment SHA-256 mismatch or expired capability aborts indexing
- **WHEN** fetched `init.mp4` or fragment bytes do not match the frozen descriptor SHA-256 or the execution-time read grant expires mid-job
- **THEN** the worker SHALL abort decoding if digests mismatch or request a fresh grant if still authorized, and SHALL NOT publish visual embeddings for unverified bytes

#### Scenario: Queued block deleted or quarantined before grant issuance
- **WHEN** a worker requests a read grant for a `catalog_entry_id` that has transitioned to `local_state = quarantined` or has no remaining playable copy (`local_state = reclaimed` and `archive_state` in `deleted` or `not_required`)
- **THEN** the grant endpoint SHALL refuse media access with an explicit terminal gone status and the worker SHALL acknowledge the JetStream job as skipped without retrying

### Requirement: Reserved interactive text-embedding capacity
The system SHALL serve interactive search query text embeddings over a dedicated workload-authenticated NATS request/reply lane (`media.rpc.visual_text_embed.v1`) with reserved execution capacity and a bounded timeout so bulk keyframe backfill on `media.jobs.visual_index.v1` cannot starve user search queries.

#### Scenario: Interactive search query during heavy historical backfill
- **WHEN** an operator submits a natural-language camera search query while `media.jobs.visual_index.v1` has a multi-hour backlog of queued recording blocks
- **THEN** `serviceradar-media-worker` SHALL execute the text-tower forward pass on reserved interactive capacity outside the video-indexing semaphore using the exact requested `(model_id, model_version, embedding_dim)` within the configured interactive deadline (default `250 ms`)

#### Scenario: Compatible text-embedding worker unavailable or timed out
- **WHEN** no `serviceradar-media-worker` serving the requested `(model_id, model_version, embedding_dim)` responds within the interactive deadline
- **THEN** the search service SHALL fail closed with an explicit embedder-unavailable status and SHALL NOT substitute embeddings from an incompatible model version or dimension

