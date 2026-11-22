# Design: Semantic visual clip search and Rust GPU media workers

## Context & Scope

This design delivers the visual search portion of Stage P3 in [add-vms-storage-playback-engine/media-workers.md](../add-vms-storage-playback-engine/media-workers.md) ("GPU workers, media plugins and searchable derivatives") and [cloud-control-plane.md](../add-vms-storage-playback-engine/cloud-control-plane.md) (`C3. GPU placement and environment isolation`) on top of the shipped continuous NVR catalog, retention, hold, and timeline playback architecture in [add-nvr-retention-and-timeline-playback](../add-nvr-retention-and-timeline-playback/design.md).

With continuous NVR recording active, a deployment accumulates thousands of sealed CMAF blocks (`init.mp4`, `media.m4s`, `descriptor.json`) per camera per day in `ServiceRadar.Camera.RecordingCatalogEntry` (`platform.camera_recording_catalog`). Investigators can scrub any camera's timeline by wall-clock window via `CameraTimelineController` and `CameraLive.Recordings`, but finding an event described visually -- such as `"person in red dress"`, `"forklift near bay door"`, or `"white cargo van"` -- still requires manual scrubbing across hours of footage.

### Goals

- Enable open-vocabulary natural-language visual search across recorded camera footage with sub-second interactive query latency (`< 250 ms` p95 text-embedding + `pgvector` k-NN over authorized cameras).
- Accurately match fine-grained foreground subject attributes (clothing color, carried packages, vehicle type) inside wide-angle 1080p and 4K surveillance frames by combining Stage 1 object/subject crop detection with Stage 2 vision-language embeddings alongside full-scene embeddings.
- Isolate native video decoding (`H.264` / `HEVC` IDR keyframes) and GPU inference (`ort` / ONNX Runtime with TensorRT and CUDA) inside a standalone stateless Rust daemon (`serviceradar-media-worker`) outside the BEAM ERTS cluster, supporting both `linux/amd64` (x86_64 NVIDIA nodes) and `linux/arm64` (Grace/DGX-class GPU nodes).
- Enforce strict ServiceRadar architectural boundaries:
  - All asynchronous job dispatch (`media.jobs.visual_index.v1`) and worker result ingestion (`media.results.visual_index.v1`) traverse NATS JetStream; workers never write directly to CNPG or StarRocks.
  - All S3-compatible archive credentials remain in `platform.network_credential_secrets` and are resolved at execution time into short-lived `:reader`-only (`GET`, `HEAD`) `CredentialBrokerGrant` documents via `ArchiveCredentialResolver` for bounded `longshore_s3` byte-range reads -- never Kubernetes bucket Secrets or long-lived presigned URLs.
  - Visual frames and embeddings in CNPG (`platform.camera_visual_frames`, `platform.camera_visual_embeddings`) are bounded search projections tightly coupled to `RecordingCatalogEntry` retention, `RecordingHold` preservation, and quarantine exclusion.

### Non-Goals

- Live per-frame RTSP stream inference on every compressed frame (ephemeral live relay taps remain handled by `BoomboxBranchManager` / `BoomboxSidecarManager` in `serviceradar_core_elx`; recorded-block indexing operates on sealed catalog blocks).
- Writing an unbounded raw `vms_ai_events` detection firehose into CNPG. Per `media-workers.md` ("Transcript and semantic search contract (P3)"), CNPG holds bounded, retention-coupled VMS search projections via Ash resources, whereas worker operational/health telemetry flows through JetStream and `EventWriter` to the configured telemetry store (StarRocks when enabled, CNPG otherwise).
- Audio speech transcription (`Whisper`), optical character recognition (OCR/ALPR), face recognition/biometrics, or PostGIS spatial field-of-view intersection, each of which remains a separate P3 contract.

```
+-------------------------------------------------------------------------+
| Core / Web-NG (BEAM ERTS Cluster)                                       |
|                                                                         |
|  RecordingBlocks.freeze_and_catalog/6                                   |
|     |-- sealed non-quarantined RecordingCatalogEntry                    |
|     +-- CameraRecordingPolicy (visual_index_mode == :keyframes)         |
|            |                                                            |
|            v                                                            |
|  CNPG Outbox: platform.camera_visual_index_jobs                         |
|            |                                                            |
|            +---> NATS JetStream: media.jobs.visual_index.v1             |
|                                                                         |
|  Internal Workload API: POST /v1/media/workers/read-grants              |
|     |-- verifies active job + playable non-quarantined catalog entry    |
|     |-- local copy -> scoped NVR analysis read grant                    |
|     +-- archive copy -> ArchiveCredentialResolver (:reader GET/HEAD)    |
|                                                                         |
|  JetStream Projector <--- media.results.visual_index.v1                 |
|     +-- idempotent upsert -> platform.camera_visual_frames              |
|                              platform.camera_visual_embeddings (HNSW)   |
|                                                                         |
|  CameraSemanticSearchController / CameraLive.{Index,Recordings}         |
|     |-- 1. RBAC (devices.view + devices.cameras.recordings.view)        |
|     |-- 2. Pre-filter authorized Camera.Source UUIDs                    |
|     |-- 3. NATS RPC: media.rpc.visual_text_embed.v1 (<= 250 ms)         |
|     |-- 4. pgvector HNSW cosine k-NN + RecordingCatalogEntry playable   |
|     +-- 5. Append RecordingAccessAudit (event_kind: :semantic_search)   |
+-------------------------------------------------------------------------+
             |                     |                       ^
   pull jobs |         read grants |                       | publish results
             v                     v                       | & text vectors
+-------------------------------------------------------------------------+
| Standalone Rust Pod: serviceradar-media-worker (Outside BEAM ERTS)      |
|  - Multi-arch OCI: linux/amd64 + linux/arm64 (Helm mediaWorker.*)       |
|  - Startup capability probe: ort TensorRT / CUDA / explicit CPU         |
|  - Byte-range IDR keyframe reader: NVR read listener OR longshore_s3    |
|  - SHA-256 verification against frozen descriptor before decode         |
|  - Stage 1: RT-DETR / YOLO subject detector (person/vehicle/package)    |
|  - Stage 2: SigLIP / MobileCLIP vision + reserved text tower            |
+-------------------------------------------------------------------------+
```

---

## 1. Standalone Rust GPU Media Worker Architecture

### 1.1 Crate, Multi-Arch Packaging, and ERTS Isolation

A new Rust binary crate `rust/media-worker` produces `serviceradar-media-worker` and its multi-architecture OCI image (`linux/amd64` and `linux/arm64`) under Bazel (`--config=remote`). Supporting both `amd64` and `arm64` from day one allows identical worker deployments across standard x86_64 NVIDIA datacenter GPUs and ARM64 NVIDIA Grace / DGX-class GPU nodes without architecture-specific forks.

`serviceradar-media-worker` runs as a stateless OS process completely outside the BEAM ERTS cluster:

- Zero CUDA, TensorRT, ONNX Runtime, or video-codec NIFs are loaded into `serviceradar-core-elx`, `serviceradar-web-ng`, or `serviceradar-nvr`.
- Workers hold no Erlang distribution cookie and cannot invoke RPC inside BEAM nodes.
- If a malformed bitstream, GPU OOM, or driver reset terminates `serviceradar-media-worker`, Kubernetes restarts only the stateless worker pod; ongoing NVR capture, archive uploads, live WebRTC/HLS relay sessions, and timeline playback continue unaffected.

### 1.2 Why Membrane `Boombox` Stays for Live Taps While Recorded Indexing Uses Rust

`serviceradar_core_elx` already includes `BoomboxBranchManager` and `BoomboxSidecarManager` for tapping live camera relay sessions where compressed access units are already flowing through Membrane pipelines in memory. Recorded-block semantic indexing solves a fundamentally different workload:

1. **Asynchronous byte-range I/O over sealed CMAF blocks**: Sealed NVR blocks consist of `init.mp4` plus 2 s keyframe-aligned CMAF fragments inside `media.m4s` (up to 150 fragments / 16 MiB per block). Re-hydrating full Membrane pipelines per historical block inside BEAM schedulers adds unnecessary memory churn, whereas Rust can parse `sidx`/`moof`/`trun` boxes directly, fetch only the sampled IDR keyframe byte slices via `longshore_s3` (pinned in `Cargo.toml`), verify SHA-256 digests in place, and decode single IDR NAL units without inter-frame decoder state.
2. **Batched GPU tensor execution**: Stage 1 object detection (`NMS` + crop extraction + bilinear letterbox resize) feeds directly into a single batched Stage 2 vision-encoder tensor (`[1 + N_crops, 3, H, W]`) inside ONNX Runtime (`ort`) over pinned device memory, avoiding cross-process frame serialization between a decoder process and an inference server.
3. **Independent elastic scaling**: Operators can scale `serviceradar-media-worker` from `0` replicas (when semantic search is unused) to `N` replicas on dedicated tainted GPU node pools (`gpu-worker-pool`) without resizing `core-elx` or `nvr` StatefulSets.

### 1.3 Execution Provider Capability Matrix and Zero Silent CPU Fallback

Per `media-workers.md` ("Reject work beyond measured budgets; no silent expensive CPU fallback") and `cloud-control-plane.md` (`C3. GPU placement and environment isolation`), `serviceradar-media-worker` enforces explicit capability admission at startup before subscribing to `media.jobs.visual_index.v1`:

| `execution_backend` | Intended environment | Required runtime proof at startup | Default concurrency | Silent fallback |
| --- | --- | --- | --- | --- |
| `tensorrt` | Production NVIDIA GPU pools (`amd64` / `arm64`) with persistent engine cache volume | NVIDIA driver + CUDA + TensorRT EP init, SHA-256 model digest verification, synthetic warmup forward pass within budget | Configurable (`1..8` streams per GPU replica) | Forbidden; fails `/readyz` on EP init error |
| `cuda` (default when `mediaWorker.enabled=true`) | Production NVIDIA GPU pools (`amd64` / `arm64`) without TensorRT engine build wait | NVIDIA driver + CUDA EP init, free VRAM >= configured floor, SHA-256 model digest verification, synthetic warmup forward pass | Configurable (`1..4` streams per GPU replica) | Forbidden; fails `/readyz` on EP init error |
| `cpu_explicit` | Synthetic CI tests and explicit low-rate lab evaluation only | Explicit `SERVICERADAR_MEDIA_WORKER_EXECUTION_BACKEND=cpu_explicit` opt-in, SHA-256 model digest verification, bounded single-slot semaphore (`concurrency = 1`) and strict per-minute frame cap | `1` (hard ceiling `2`) | N/A (explicitly opted in) |

At boot, the worker inspects NVML / device properties (when on NVIDIA hardware) to classify the GPU sharing mode (`physical`, `mig`, `time_sliced`, or `cpu_explicit`) per `cloud-control-plane.md` C3:

- NVIDIA time-sliced GPU shares (`nvidia.com/gpu` replicas > 1 on one physical GPU without MIG) provide no hardware memory isolation; when `gpu_sharing_class = time_sliced` is detected or declared, the worker caps batch size and per-replica `ort` arena memory explicitly rather than assuming full physical VRAM.
- Pinned ONNX model artifacts (`detector.onnx`, `vision_encoder.onnx`, `text_encoder.onnx`, `tokenizer.json`) are loaded from a read-only verified model directory populated either from a Bazel-pinned OCI init/volume artifact or fetched exclusively through `ServiceRadar.HTTP.EgressClient` and verified against configured SHA-256 digests before `ort::Session` creation.

### 1.4 Helm Scheduling, Placement, and Network Isolation

Helm adds an opt-in `mediaWorker:` block in `helm/serviceradar/values.yaml` (`mediaWorker.enabled: false` by default, zero live hostnames baked into templates):

- `mediaWorker.replicas` (default `1` when enabled), `mediaWorker.image`, `mediaWorker.executionBackend` (`cuda` default).
- `mediaWorker.gpu.enabled` (`true` default), `mediaWorker.gpu.resourceName` (`nvidia.com/gpu`), `mediaWorker.gpu.count` (`1`), `mediaWorker.gpu.sharingClass` (`physical` | `mig` | `time_sliced`).
- `mediaWorker.nodeSelector` (for example `{"serviceradar.io/gpu-pool": "gpu-worker-pool"}`) and `mediaWorker.tolerations` (for example tolerating `nvidia.com/gpu=present:NoSchedule`).
- `mediaWorker.healthPort` (`/healthz` liveness and `/readyz` capability-verified readiness).
- **Kubernetes `NetworkPolicy`**: `serviceradar-media-worker` pods are permitted egress ONLY to:
  1. NATS JetStream (`4222` mTLS);
  2. Internal workload grant endpoint on `web-ng` / `core-elx` (`POST /v1/media/workers/read-grants`);
  3. Owning `serviceradar-nvr` read listener port when local NVR reads are enabled;
  4. Configured HTTPS object-storage endpoints (`TCP 443`) and OTEL collector (`serviceradar-otel:4317`).
  Direct egress to CNPG (`5432`) and StarRocks is denied at the network policy layer as well as application configuration.

---

## 2. Durable Job Queue & Execution-Time Read Capabilities

### 2.1 Policy Opt-In and Transactional CNPG Outbox (`platform.camera_visual_index_jobs`)

Visual indexing is opt-in per camera stream profile on `ServiceRadar.Camera.CameraRecordingPolicy` (`platform.camera_recording_policies`, PaperTrail audited):

- `visual_index_mode`: `:off | :keyframes` (default `:off`).
- `visual_index_min_interval_ms`: integer (default `2000`, range `1000..30000`, required when `:keyframes` and `nil` or default otherwise).
- `visual_index_max_frames_per_block`: integer (default `64`, range `1..150`).

When `RecordingBlocks.freeze_and_catalog/6` (live seal or lookup) or `NVRReconcileJob` (historical freeze `R3`) creates a **sealed, non-quarantined** `RecordingCatalogEntry` (`recording_block_id IS NOT NULL` and `local_state != :quarantined`), Core checks the entry's `CameraRecordingPolicy` inside the same transaction (or immediately via idempotent catalog registration hook):

- If `visual_index_mode == :keyframes` and an active visual model configuration `(model_id, model_version, embedding_dim)` is enabled, Core inserts `ServiceRadar.Camera.VisualIndexJob` (`platform.camera_visual_index_jobs`) with unique identity `(catalog_entry_id, model_id, model_version)`.
- Quarantined catalog entries (`local_state == :quarantined`, whether created by `register_quarantined` or transitioned by `quarantine_in_place`) NEVER create visual index jobs.

`platform.camera_visual_index_jobs` schema:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` (UUIDv7) | Primary key |
| `catalog_entry_id` | `uuid` | `NOT NULL`, FK `ON DELETE CASCADE` to `platform.camera_recording_catalog(id)` |
| `camera_source_id` | `uuid` | `NOT NULL`, denormalized for backlog metrics and policy cancellation |
| `stream_profile_id` | `uuid` | `NOT NULL` |
| `model_id` | `text` | `NOT NULL` (for example `"siglip-b16-384"` or `"mobileclip-s2"`) |
| `model_version` | `text` | `NOT NULL` (for example `"2026.1"`) |
| `embedding_dim` | `integer` | `NOT NULL`, `CHECK (embedding_dim IN (512, 768, 1024))` |
| `sample_interval_ms` | `integer` | `NOT NULL`, default `2000` |
| `max_frames` | `integer` | `NOT NULL`, default `64` |
| `state` | `text` | `pending`, `published`, `completed`, `skipped_deleted`, `failed_terminal`, `cancelled` |
| `attempt_count` | `integer` | `NOT NULL`, default `0` |
| `max_attempts` | `integer` | `NOT NULL`, default `5` |
| `jetstream_seq` | `bigint` | Nullable; recorded on JetStream publish |
| `last_error_class` | `text` | Nullable, bounded `[a-z0-9_:-]{1,64}` |
| `published_at`, `completed_at`, `inserted_at`, `updated_at` | `timestamptz` | Lifecycle timestamps |

### 2.2 Metadata-Only JetStream Pull Queue and `MaxDeliver` Reconciliation

An outbox relay worker in `serviceradar_core` publishes `pending` rows to NATS JetStream subject `media.jobs.visual_index.v1` (stream `CAMERA_MEDIA_JOBS`, finite `MaxBytes` and `MaxAge: 72h`, deduplicated via `Nats-Msg-Id: visual-index:<job_id>`) and marks the row `published`.

The job message envelope is strictly bounded metadata (`<= 4 KiB`) and carries **zero video bytes and zero storage credentials**:

```json
{
  "schema_version": 1,
  "job_id": "01933b40-0000-7000-8000-000000000021",
  "catalog_entry_id": "00000000-0000-4000-8000-000000000011",
  "camera_source_id": "00000000-0000-4000-8000-000000000007",
  "stream_profile_id": "00000000-0000-4000-8000-000000000008",
  "storage_id": "00000000-0000-4000-8000-000000000009",
  "block_key": "2222222222222222222222222222222222222222222222222222222222222222",
  "descriptor_sha256": "3333333333333333333333333333333333333333333333333333333333333333",
  "init_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
  "model_id": "siglip-b16-384",
  "model_version": "2026.1",
  "embedding_dim": 768,
  "sample_interval_ms": 2000,
  "max_frames": 64,
  "budget_ms": 30000,
  "deadline_unix_ms": 1794950400000
}
```

Workers pull batches (`batch = 1..4` matching available GPU slots) from durable pull consumer `camera_visual_index_worker_v1` (`AckWait = 60s`, `MaxDeliver = 5`, bounded `MaxAckPending`):

- While decoding and running `ort` inference, the worker sends periodic JetStream `WPI` (`in_progress`) heartbeats up to `budget_ms`.
- Per `media-workers.md` ("MaxDeliver exhaustion is explicitly reconciled to terminal/quarantined state; it is not assumed to create an automatic dead-letter queue"), Core subscribes to `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.CAMERA_MEDIA_JOBS.camera_visual_index_worker_v1` AND runs a periodic Oban reconciliation sweep over `camera_visual_index_jobs` rows stuck in `published` past `max_attempts * AckWait`, marking exhausted jobs `failed_terminal` (`last_error_class = "max_deliver_exhausted"`) and raising deduplicated `TripwireHealth.record/4` check `camera.visual_index.failed_terminal`.

### 2.3 Execution-Time Scoped Read Grants (`NVR` Analysis Pool and `longshore_s3`)

Because a job can sit in `media.jobs.visual_index.v1` during a GPU burst or maintenance window, embedding presigned URLs or static credentials in the queue message would either expire prematurely or violate least-privilege custody (`media-workers.md` lines 21-23). Instead, at execution time `serviceradar-media-worker` calls `POST /v1/media/workers/read-grants` over mTLS / internal workload listener, authenticating with a dedicated domain-separated `media_worker` workload token (never human RBAC, never `account`, `entitlements`, or `ingest` tokens).

The grant endpoint executes the following steps:

1. Verifies the `media_worker` workload token and checks that `job_id` exists in `platform.camera_visual_index_jobs` in state `published` (or `pending`) for `catalog_entry_id`.
2. Loads `RecordingCatalogEntry` and its frozen `RecordingBlock` descriptor:
   - If the catalog entry is missing, `local_state == :quarantined`, or no playable copy remains (`local_state == :reclaimed` and `archive_state` in `[:deleted, :not_required]`), transitions the job to `skipped_deleted` and answers `410 Gone` (`{"error": "source_deleted_or_quarantined"}`). The worker ACKs the JetStream message immediately without retry.
3. Selects the deterministic sampled fragment list from the frozen descriptor (`fragment_index`, `media_offset_ns`, derived `timeline_ts_us`, byte `offset`, byte `length <= 4 MiB`, and per-fragment `sha256` where `keyframe == true` spaced by at least `sample_interval_ms`, capped at `max_frames`). Because NVR fragments are cut at keyframes at `>= 2 s` (`packaging.ex:52-60`), sampling at `2000 ms` selects at most 1 keyframe per fragment; coarser intervals (for example `4000 ms` or `6000 ms`) skip intermediate fragments entirely.
4. Resolves the read transport capability (TTL `300 s`):
   - **Preferred Path A -- Archive S3 Byte-Range Read via `longshore_s3`** (whenever `archive_state == :verified`, or when `local_state != :present`):
     - Core resolves a short-lived (`ttl_seconds: 300`) `:reader`-only (`["HEAD", "GET"]`) `CredentialBrokerGrant` via `ArchiveCredentialResolver.resolve_for_binding/4` from `platform.network_credential_secrets` (locked to `https://<host>:443/<bucket>/<namespace>/*`, for example `https://objects.example.com:443/example-archive/nvr/*`).
     - Returns the exact `<prefix>/<storage_id>/<block_key>/init.mp4` and `<prefix>/<storage_id>/<block_key>/media.m4s` keys, expected ETags/object versions from `NVRArchiveReceipt`, sampled byte ranges `[offset, offset + length - 1]`, frozen SHA-256 digests, and the ephemeral runtime reader credential document held only in worker memory for that job.
     - Note why archive S3 reads are preferred when `archive_state == :verified`: reading ranged fragments directly from object storage via `longshore_s3` keeps historical backfill completely off the NVR member's local disk I/O path.
   - **Path B -- Local NVR Analysis Read Pool** (when `local_state == :present` and the block is local-only or not yet `verified` in object storage):
     - Issues a short-lived (`300 s`) read capability bound to `(storage_id, block_key)` against the owning NVR member's read listener (`GET /v1/blocks/<block_key>/init` and `GET /v1/blocks/<block_key>/fragments/<index>`).
     - On `serviceradar-nvr`, worker requests carrying the `analysis_read` purpose run in a dedicated **analysis read pool** (default `2` slots, `10 s` timeout), strictly separate from the `8`-slot interactive viewer playback pool (`D5`) and the `4`-slot archive/inventory pool (`1.1`), guaranteeing that GPU indexing can never starve live operators scrubbing timeline video or delay archive uploads.

In `serviceradar-media-worker`, the Rust `longshore_s3` client (or NVR HTTPS client) fetches `init.mp4` once and fetches ONLY the sampled fragment byte ranges, computing SHA-256 over `init.mp4` (`== init_sha256`) and over every fetched fragment (`== fragment.sha256` from the frozen descriptor) before passing a single byte to the MP4 demuxer or video decoder. Any SHA-256 mismatch aborts the job with `integrity_mismatch` and never emits embeddings.

---

## 3. Two-Stage Vision Pipeline & Query Text Embedding

### 3.1 Why Whole-Frame CLIP Fails on Surveillance Scenes

Vision-language encoders (`CLIP`, `SigLIP`, `MobileCLIP`) resize input images to a fixed square grid (typically `224x224` or `384x384`). On a 1080p (`1920x1080`) or 4K (`3840x2160`) security camera (such as `Gate C2 / Camera 07` overlooking an entry lane and loading bay), a person 20 meters away occupies roughly `96x220` pixels (`~1%` of the frame). Downsampling the whole frame to `384x384` compresses that person to `~19x44` pixels (`~2x3` ViT patches), causing global scene pooled tokens to be dominated by static background features (parked trailers, red safety bollards, brick walls, foliage). As a result, whole-frame embeddings suffer high false-negative rates and background-color hallucinations on compositional queries like `"person in red dress"` or `"person carrying yellow package"`.

### 3.2 Two-Stage Cropped Subject + Scene Pipeline

For each verified IDR keyframe fragment, `serviceradar-media-worker` executes:

1. **Keyframe-only decode**: Demuxes `init.mp4` + the single CMAF fragment (`moof` + `mdat`), extracts the first sync (`IDR`) sample, and decodes only that frame to RGB (`H.264` / optional `HEVC`). Decoding only IDR keyframes avoids decoding the ~59 P/B frames in each 2 s GOP -- a ~60x decode reduction with deterministic per-fragment statelessness.
2. **Stage 1 -- Localized Subject Detector (`RT-DETR` / `YOLO`-family ONNX)**:
   - Runs fast object detection over the full keyframe on the GPU (`ort` TensorRT/CUDA EP).
   - Maps detections into a canonical surveillance class set: `person`, `vehicle`, `bicycle`, `animal`, `package`.
   - Filters by confidence (`>= 0.35` default), applies class-aware NMS (`IoU <= 0.50`), drops tiny noise boxes (`< 24x24` source pixels), and selects at most `K = 8` top subject boxes per keyframe ranked by `confidence * sqrt(area_fraction)`.
   - Expands each selected bounding box `[x1, y1, x2, y2]` by a `10%` context margin (clamped to `[0.0, 1.0]` normalized frame coordinates) and crops from the **original full-resolution decoded RGB frame** before resizing to the Stage 2 encoder resolution (`384x384` or `256x256`), preserving crisp fine-grained clothing, color, and carried-object detail.
   - Optionally computes lightweight deterministic dominant-color tags (`red`, `blue`, `white`, `black`, `yellow`, `green`, `gray`, `orange`, `brown`) in HSV/Lab space over the inner crop region as auxiliary structured metadata (`attributes.dominant_colors`).
3. **Stage 2 -- Batched Vision-Language Image Tower (`SigLIP` / `MobileCLIP` ONNX)**:
   - Assembles a single tensor batch of `[full_scene_frame] ++ subject_crops` (batch size `1..9` per keyframe, or batched across `2..4` keyframes up to `max_batch = 16`).
   - Runs one batched GPU forward pass through the vision tower and L2-normalizes every output vector (`||v||_2 = 1.0`).
   - Emits:
     - `1` `:scene` embedding (`embedding_kind = "scene"`, `bbox = null`, `object_class = null`) capturing global context (`"forklift near open bay door"`, `"smoke in corridor"`, `"snow covered parking lot"`).
     - `0..8` `:crop` embeddings (`embedding_kind = "crop"`, `object_class`, `detector_confidence`, `bbox_norm = [x1, y1, x2, y2]`, `attributes`) capturing localized subject semantics (`"person in red dress"`, `"white cargo van"`).

### 3.3 Explicit Model Identity and Vector Dimensions

Per `media-workers.md` ("Select dimensions/index from the model rather than copying the PRD's CLIP dimension into every table"), every job, result message, database row, and query carries `(model_id, model_version, embedding_dim)` explicitly:

| Profile | Candidate ONNX family | `embedding_dim` | Typical GPU latency per keyframe (1 scene + 4 crops) | Use case |
| --- | --- | --- | --- | --- |
| Default balanced (`siglip-b16-384`) | SigLIP Base Patch16 (`384x384`) | `768` | ~6-12 ms (L4 / RTX / Grace-Blackwell class) | High attribute precision (clothing colors, fine objects, compositional phrases) |
| Compact high-throughput (`mobileclip-s2`) | MobileCLIP-S2 (`256x256`) | `512` | ~2-5 ms | High-density multi-camera fleets or entry-level GPUs |

Worker outputs are published to JetStream subject `media.results.visual_index.v1` (stream `CAMERA_MEDIA_RESULTS`, deduplicated via `Nats-Msg-Id: visual-result:<job_id>:<chunk>`). Only after receiving the JetStream pub-ack for `media.results.visual_index.v1` does `serviceradar-media-worker` `ACK` the corresponding job on `media.jobs.visual_index.v1`.

### 3.4 Reserved Interactive Text-Query Embedding Lane

When an investigator searches `"person in red dress"`, the query string must be encoded by the **exact matching text tower** `(model_id, model_version, embedding_dim)` of the active vision-language model, L2-normalized with the model's canonical prompt template (for example `"a photo of {query}"` when required by the model card).

To guarantee that a 50,000-block historical backfill on `media.jobs.visual_index.v1` never delays interactive search (`media-workers.md`: "Interactive work has reserved capacity apart from bulk jobs"):

1. `serviceradar-media-worker` keeps the lightweight ONNX text tower (`text_encoder.onnx` + `tokenizer.json`) warm in a **separate `ort::Session` with its own reserved semaphore** (`interactive_text_slots = 4`), completely independent of the video-decode / vision-tower job worker loop.
2. `serviceradar-media-worker` subscribes to NATS queue-group request/reply subject `media.rpc.visual_text_embed.v1.<model_id>.<model_version>` (restricted by workload NATS subject permissions).
3. Request payload is strictly bounded (`query` trimmed, `1..256` UTF-8 characters, `model_id`, `model_version`, `expected_dim`, `deadline_ms <= 250`).
4. `serviceradar_core` caches `(model_id, model_version, normalized_query_sha256) -> float32_vector` in an in-memory ETS LRU cache (`TTL = 60 s`, max `1,024` entries; cache keys contain zero user/RBAC state because text embeddings depend only on query text and model version).
5. If no compatible `serviceradar-media-worker` replies within `250 ms`, the search endpoint fails closed with `503 Service Unavailable` (`{"error": "search_embedder_unavailable"}`) rather than hanging a web request or comparing mismatched vector spaces.

---

## 4. CNPG `pgvector` Schema, Retention Purge & Hold Coupling

### 4.1 Ash Resources and `pgvector` HNSW Indexing

CNPG already installs `pgvector` in schema `platform` (`CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA platform;` in `platform_schema.sql:173`). Two Ash resources are registered in domain `ServiceRadar.Camera` (with explicit SQL migration DDL for `platform.vector` typed partial HNSW indexes per `openspec/AGENTS.md` "Special Cases"):

#### `ServiceRadar.Camera.VisualFrame` (`platform.camera_visual_frames`)

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` (UUIDv7) | Primary key |
| `catalog_entry_id` | `uuid` | `NOT NULL`, FK `ON DELETE CASCADE` to `platform.camera_recording_catalog(id)` |
| `camera_source_id` | `uuid` | `NOT NULL`, FK `ON DELETE CASCADE` to `platform.camera_sources(id)` |
| `stream_profile_id` | `uuid` | `NOT NULL` |
| `fragment_index` | `integer` | `NOT NULL`, `>= 0` |
| `media_offset_ns` | `bigint` | `NOT NULL`, `>= 0` |
| `timeline_ts_us` | `bigint` | `NOT NULL`, computed by Core projector from `catalog_entry.timeline_start_us + ((media_offset_ns - catalog_entry.media_start_ns) / 1000)` so worker clocks never define timeline truth |
| `time_basis` | `text` | `NOT NULL`, `received` or `camera_reported` copied from `RecordingCatalogEntry` |
| `frame_width`, `frame_height` | `integer` | `NOT NULL`, `> 0` |
| `detector_model_id` | `text` | `NOT NULL` |
| `inserted_at` | `timestamptz` | `NOT NULL` |

- Unique identity: `(catalog_entry_id, fragment_index)`.
- B-tree index: `(camera_source_id, timeline_ts_us DESC, catalog_entry_id)`.

#### `ServiceRadar.Camera.VisualEmbedding` (`platform.camera_visual_embeddings`)

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` (UUIDv7) | Primary key |
| `visual_frame_id` | `uuid` | `NOT NULL`, FK `ON DELETE CASCADE` to `platform.camera_visual_frames(id)` |
| `catalog_entry_id` | `uuid` | `NOT NULL`, denormalized FK `ON DELETE CASCADE` to `platform.camera_recording_catalog(id)` for fast single-table purge and catalog state joins |
| `camera_source_id` | `uuid` | `NOT NULL`, denormalized for pre-k-NN camera scope filtering |
| `timeline_ts_us` | `bigint` | `NOT NULL`, denormalized for time-window filtering |
| `embedding_kind` | `text` | `NOT NULL`, `CHECK (embedding_kind IN ('scene', 'crop'))` |
| `crop_index` | `integer` | `NOT NULL`, `0` for `scene`, `1..8` for `crop` |
| `object_class` | `text` | Nullable (`NULL` iff `scene`; `person`, `vehicle`, `bicycle`, `animal`, `package` for `crop`) |
| `detector_confidence` | `real` | Nullable (`NULL` iff `scene`; `0.0..1.0` for `crop`) |
| `bbox_x1`, `bbox_y1`, `bbox_x2`, `bbox_y2` | `real` | Nullable (`NULL` iff `scene`; normalized `0.0 <= x1 < x2 <= 1.0` and `0.0 <= y1 < y2 <= 1.0` for `crop`) |
| `attributes` | `jsonb` | `NOT NULL`, default `'{}'::jsonb`, bounded `<= 1024` bytes (for example `{"dominant_colors": ["red"]}`) |
| `model_id` | `text` | `NOT NULL` |
| `model_version` | `text` | `NOT NULL` |
| `embedding_dim` | `integer` | `NOT NULL`, `CHECK (embedding_dim IN (512, 768, 1024) AND platform.vector_dims(embedding) = embedding_dim)` |
| `embedding` | `platform.vector` | `NOT NULL`, L2-normalized `float32` vector |
| `inserted_at` | `timestamptz` | `NOT NULL` |

- Unique identity: `(visual_frame_id, model_id, model_version, embedding_kind, crop_index)` for idempotent upsert on JetStream redelivery.
- Partial expression HNSW cosine indexes per supported dimension so multiple model dimensions coexist cleanly without schema forks:
  - `CREATE INDEX camera_visual_embeddings_hnsw_768_idx ON platform.camera_visual_embeddings USING hnsw ((embedding::platform.vector(768)) platform.vector_cosine_ops) WITH (m = 16, ef_construction = 64) WHERE embedding_dim = 768;`
  - `CREATE INDEX camera_visual_embeddings_hnsw_512_idx ON platform.camera_visual_embeddings USING hnsw ((embedding::platform.vector(512)) platform.vector_cosine_ops) WITH (m = 16, ef_construction = 64) WHERE embedding_dim = 512;`
- Supporting composite B-tree index: `(camera_source_id, model_id, model_version, timeline_ts_us DESC)` for narrow time-window / small-camera-set planner paths.

### 4.2 Idempotent JetStream Result Projector

`ServiceRadar.Camera.VisualIndexResultProjector` (a supervised `JetStreamConsumer` in `serviceradar_core` consuming `media.results.visual_index.v1`) owns all writes to `camera_visual_frames`, `camera_visual_embeddings`, and `camera_visual_index_jobs`:

1. Loads `RecordingCatalogEntry` for `catalog_entry_id`:
   - Verifies `descriptor_sha256` matches the frozen catalog entry.
   - Verifies the catalog entry is still playable and non-quarantined (`RecordingCatalogEntry.playable?(entry) == true`). If the block was deleted/reclaimed or quarantined while the worker was mid-flight, the projector drops the embeddings, marks any job row `skipped_deleted`, and ACKs the JetStream message so deleted/quarantined footage never lands in `pgvector`.
2. Computes authoritative `timeline_ts_us` and `time_basis` from the `RecordingCatalogEntry` row (never trusting worker wall clocks).
3. Upserts `camera_visual_frames` (`ON CONFLICT (catalog_entry_id, fragment_index) DO UPDATE`) and `camera_visual_embeddings` (`ON CONFLICT (visual_frame_id, model_id, model_version, embedding_kind, crop_index) DO UPDATE`) and transitions `camera_visual_index_jobs` to `completed` (`stale` attempts for an already-completed `(catalog_entry_id, model_id, model_version)` are reconciled idempotently without duplicating rows).

### 4.3 Retention Purge, Quarantine Exclusion, and `RecordingHold` Coupling

A critical lifecycle invariant from `add-nvr-retention-and-timeline-playback` (`C6` and Open Question 5) is that **terminal `platform.camera_recording_catalog` rows remain in CNPG as tombstones for 90 days** (`local_state = 'reclaimed'` and `archive_state IN ('deleted', 'not_required')`) so late reconciler/restore checks never resurrect deleted blocks. Consequently, `ON DELETE CASCADE` on `catalog_entry_id` cleans up when tombstones are eventually purged after 90 days, **but `ON DELETE CASCADE` alone would leave embeddings searchable for 90 days after footage deletion if not paired with an immediate state-transition purge!**

To guarantee zero resurrection and immediate purge:

1. **Database-level immediate purge trigger (`trg_camera_recording_catalog_purge_visual_index`)**:
   An `AFTER UPDATE OF local_state, archive_state ON platform.camera_recording_catalog` trigger immediately executes:
   - `DELETE FROM platform.camera_visual_frames WHERE catalog_entry_id = NEW.id;` (which cascades to `platform.camera_visual_embeddings`), AND
   - `UPDATE platform.camera_visual_index_jobs SET state = 'skipped_deleted', updated_at = now() WHERE catalog_entry_id = NEW.id AND state IN ('pending', 'published');`
   whenever EITHER:
   - `NEW.local_state = 'quarantined'` (covering `quarantine_in_place` in R4 step 1), OR
   - `NEW.local_state = 'reclaimed' AND NEW.archive_state IN ('deleted', 'not_required')` (all copies have reached terminal deletion/reclaim).
2. **Defense-in-depth playable join at query time**:
   Every semantic search query joins `platform.camera_recording_catalog c ON c.id = e.catalog_entry_id` and enforces:
   `c.recording_block_id IS NOT NULL AND c.local_state <> 'quarantined' AND (c.local_state = 'present' OR c.archive_state = 'verified')`.
   Thus even if a block's only copy becomes `:missing` (`local_state = 'missing'` and `archive_state = 'not_required'`), it is excluded from search results immediately.
3. **`RecordingHold` preservation (`platform.camera_recording_holds`)**:
   Under `PD5` (`RecordingHold`), an accepted hold pins `:archive` when `archive_state == :verified` and pins `:local` otherwise. Because at least one verified copy stays `present` or `verified` for the entire lifetime of the hold, the `RecordingCatalogEntry` never enters the terminal purge condition above, and its visual frames and embeddings remain intact and searchable for the investigation until the hold is explicitly released and retention deletes the final copy.
4. **Model-upgrade re-indexing**:
   When upgrading from `(model_id_v1, ver_1)` to `(model_id_v2, ver_2)`, a bounded Oban backfill worker scans `platform.camera_recording_catalog` strictly where `recording_block_id IS NOT NULL AND local_state <> 'quarantined' AND (local_state = 'present' OR archive_state = 'verified')`, enqueuing low-priority backfill jobs without touching reclaimed, deleted, missing, or quarantined blocks. Once the active search model switches to `v2`, old `v1` rows in `camera_visual_embeddings` are deleted in bounded batches (`DELETE ... WHERE ctid IN (SELECT ctid ... LIMIT 5000)`).

---

## 5. Authorization, Access Audit & Timeline Overlay UX

### 5.1 Pre-k-NN RBAC and Camera `Source` Scope Enforcement

Semantic search exposes visual content derived from recorded camera footage and MUST enforce the exact same authorization boundary as timeline playback (`CameraArchiveAccess`):

1. **Permission gate**: Caller must be authenticated and satisfy `RBAC.authorize_current(scope, ["devices.view", "devices.cameras.recordings.view"])`. A user with live-stream-only access (`devices.cameras.view` without `devices.cameras.recordings.view`) receives `403 Forbidden` before any text-embedding RPC or database vector query runs.
2. **Pre-filtered `Source` scope**: Before calling `pgvector`, `ServiceRadar.Camera.SemanticSearch` resolves the caller's authorized camera UUIDs via `ServiceRadar.Camera.Source |> Ash.read(scope: scope)`:
   - If the caller supplied `camera_source_ids` in the search filter, any UUID not in the caller's authorized `Source` set is rejected (`403 Forbidden` when explicitly targeting an unauthorized camera on `/cameras/:camera_source_id/recordings` or `/api/cameras/search?camera_source_id=...`).
   - On fleet-wide search (`/cameras`), the query restricts `e.camera_source_id = ANY($authorized_camera_ids)`. If `$authorized_camera_ids` is empty, search returns `[]` immediately.
3. **Filtered `pgvector` HNSW execution with iterative scan**:
   Standard HNSW graph traversal without iterative scanning can return fewer than `K` results when a selective `WHERE` filter (`camera_source_id`, `timeline_ts_us`, `object_class`) prunes most candidate nodes. Every search transaction sets:
   - `SET LOCAL hnsw.ef_search = 80;`
   - `SET LOCAL hnsw.iterative_scan = 'relaxed_order';`
   - `SET LOCAL hnsw.max_scan_tuples = 20000;`
   and computes `1.0 - ((e.embedding::platform.vector(768)) <=> $query_vec::platform.vector(768)) AS similarity` filtered by `e.model_id = $model_id AND e.model_version = $model_version AND e.embedding_dim = 768`, `e.camera_source_id = ANY($authorized_camera_ids)`, `e.timeline_ts_us BETWEEN $from_us AND $to_us` (max window `31 days`, default `24 hours`), optional `e.object_class = $object_class`, and `similarity >= $min_score`.
4. **Temporal hit coalescing**:
   Because an event such as a person walking across `Gate C2 / Camera 07` spans `3..6` consecutive 2 s keyframes, raw frame hits on the same `(camera_source_id, stream_profile_id, object_class)` within a `6 s` (`6_000_000 us`) gap are coalesced into a single clip hit carrying `peak_timeline_ts_us`, `hit_start_us`, `hit_end_us`, `peak_similarity`, the peak keyframe's `bbox_norm`, and up to `5` per-keyframe box samples across the coalesced span for smooth timeline overlay playback.

### 5.2 Append-Only `RecordingAccessAudit` (`event_kind: :semantic_search`)

`ServiceRadar.Camera.RecordingAccessAudit` (`platform.camera_recording_access_audits`) is extended cleanly without weakening its append-only `BEFORE UPDATE OR DELETE` trigger (`camera_recording_access_audits_append_only_trigger`):

- Add `:semantic_search` to `@event_kinds` (`[:playlist_window, :hold_placed, :hold_released, :semantic_search]`).
- Allow `camera_source_id` to be `NULL` **only** when `event_kind = 'semantic_search'` across multiple cameras (single-camera timeline searches still populate `camera_source_id`), enforced in SQL by tightening `camera_recording_access_audits_valid`:
  `(event_kind = 'semantic_search' OR camera_source_id IS NOT NULL)`.
- Record `actor_id`, `window_start_us`, `window_end_us`, `details` (`<= 8192` bytes, verified free of forbidden credential keys by `ValidateAccessAudit`), capturing `query_text` (bounded `<= 256` chars), `query_sha256`, `model_id`, `model_version`, `authorized_camera_count`, `filtered_camera_count`, `object_class_filter`, and `result_count`.

### 5.3 Search API, LiveView Surfaces, and Non-Destructive Player Bounding-Box Overlay

- **HTTP API (`ServiceRadarWebNGWeb.Api.CameraSemanticSearchController`)**:
  - `GET /api/cameras/search?q=...&from=...&to=...&camera_source_id=...&object_class=...&limit=...`
  - Returns ranked clip hits, each including `catalog_entry_id`, `camera_source_id`, `stream_profile_id`, capture-time camera display label (resolved per `media-workers.md` "Labels and branding", for example `"Gate C2 / Camera 07"`, labelling missing historical revision explicitly), `time_basis` (`"received"` or `"camera_reported"`), `time_uncertainty`, `copy_state` (`"local_and_archive"`, `"local; provisional"`, `"archive_only"`), `peak_timeline_ts_us`, `hit_start_us`, `hit_end_us`, `similarity`, `embedding_kind` (`"crop"` or `"scene"`), `object_class`, `bbox_norm` (`[x1, y1, x2, y2]` or `null`), and canonical `timeline_url` (`/cameras/<camera_source_id>/recordings?mode=timeline&from=<window_from_us>&to=<window_to_us>&seek=<peak_timeline_ts_us>&highlight_frame=<visual_frame_id>`).
- **LiveView Surfaces (`CameraLive.Index` and `CameraLive.Recordings`)**:
  - Obeys the LiveView Iron Law: zero database or NATS calls in disconnected `mount/3`; search executes only on authenticated LiveView events (`phx-submit="semantic_search"`), using LiveView streams when rendering large result sets and daisyUI components (`input`, `select`, `badge`, `card`, `alert`).
  - `/cameras` (`CameraLive.Index`) adds an expandable Semantic Clip Search drawer/tab across all authorized cameras when visual indexing is enabled on the deployment.
  - `/cameras/:camera_source_id/recordings` (`CameraLive.Recordings`, `mode=timeline`) adds an inline semantic search bar above the coverage timeline, plotting matched hit pins directly onto the coverage bar alongside holds and gaps.
- **Non-Destructive Bounding-Box Overlay (`CameraTimelinePlayer` JS Hook)**:
  - When timeline playback seeks to or plays across a semantic search hit interval, `CameraTimelinePlayer` (`phx-hook="CameraTimelinePlayer"` in `recordings_components.ex`) renders a lightweight client-side SVG / `<canvas>` overlay positioned over the `<video>` element's active content box (computed from `videoElement.videoWidth` and `videoElement.videoHeight` so `object-contain` letterboxing never shifts coordinates).
  - Normalized `[x1, y1, x2, y2]` coordinates are mapped to pixel coordinates on `timeupdate` / `seeked` for the keyframe nearest `currentTime` (within `+/- 1.5 s`), displaying an escaped label badge (`person 0.84 | received 14:03:12`) with an operator toggle (`Show AI boxes` on/off).
  - Original CMAF `init.mp4` and `media.m4s` bytes are never modified or re-encoded.

---

## 6. SaaS / Entitlement Hook (Optional)

Per `cloud-control-plane.md` (`C2` and `C3`) and `StorageEntitlement` (`platform.storage_entitlements`), semantic visual indexing separates self-hosted operation from hosted SaaS plan enforcement:

1. **Self-hosted deployments**: Have no `StorageEntitlement` row (`hosted_install? == false`). Operators enable `mediaWorker.enabled: true` on their own GPU node pool (`gpu-worker-pool`) and toggle `visual_index_mode: :keyframes` on any `CameraRecordingPolicy` without SaaS limits.
2. **Hosted SaaS deployments**: When `hostedRuntime.contractVersion` is set, `StorageEntitlement` (`consumers.recordings.limits`) can carry optional additive fields in a backward-compatible schema extension (`max_visual_index_cameras` integer or `nil`, `visual_index_enabled` boolean default `false` on hosted plans without a GPU add-on):
   - `CameraRecordingPolicy` (`ValidatePolicy.check_entitlement_bounds/3`) checks `max_visual_index_cameras` on `visual_index_mode == :keyframes` using the exact same `"limited by your plan"` pattern already shipped for `max_recording_cameras`.
   - During hosted suspension (`F8`), new `camera_visual_index_jobs` admission pauses alongside archive uploads while retention purges continue running.
   - `GET /v1/storage/usage` can report daily `indexed_keyframes` and `visual_search_queries` counters for hosted add-on metering (`serviceradar-control` #183 / #184) without blocking self-hosted delivery.

---

## Risks / Trade-offs

- **False positives and false negatives on open-vocabulary queries.** Vision-language cosine scores vary by prompt phrasing and lighting (night IR vs daytime color). Mitigation: Stage 1 crop extraction dramatically improves small-subject recall; UI surfaces similarity scores, explicit `received` time basis, and instant timeline video verification rather than treating hits as automated enforcement actions.
- **`pgvector` HNSW index memory and storage growth.** At 1 keyframe per 2 s (`43,200` keyframes/camera/day) and an average of `1` scene + `1.5` subject crops (`~108,000` 768-d `float32` vectors/camera/day, `~330 MB/camera/day` raw + HNSW graph overhead), unbridled 24/7 indexing across dozens of cameras grows CNPG storage quickly. Mitigation: visual indexing is strictly opt-in per policy (`visual_index_mode: :off` default), supports configurable `visual_index_min_interval_ms` (for example `4000 ms` or `5000 ms` on low-activity cameras) and optional static-scene deduplication (skipping Stage 2 `:scene` re-embedding when perceptual hash / pixel delta vs previous keyframe is below threshold and Stage 1 finds `0` foreground subjects), and purges immediately on local/object retention deletion.
- **GPU contention between historical backfill and live new blocks.** If a camera enables indexing or upgrades models, thousands of historical blocks could delay newly sealed live blocks. Mitigation: use two JetStream subjects or priority pull consumers (`media.jobs.visual_index.live.v1` polled before `media.jobs.visual_index.backfill.v1`), while interactive text queries use the completely separate `media.rpc.visual_text_embed.v1` lane.
- **S3 GET request volume during archive-backed indexing.** Fetching 64 separate 2 s fragments via ranged GETs could issue up to 65 GETs per block if uncoalesced. Mitigation: when adjacent sampled fragments are contiguous or separated by small gaps in `media.m4s`, `serviceradar-media-worker` coalesces adjacent byte ranges up to `4 MiB` per `longshore_s3` ranged `GET` and still verifies each individual fragment's frozen SHA-256 slice in memory before decode.

---

## Migration Plan

All changes are additive and backward-compatible:

1. **Database migrations (via Ash codegen + `mix serviceradar.db.migrate`)**:
   - Add `visual_index_mode`, `visual_index_min_interval_ms`, and `visual_index_max_frames_per_block` to `platform.camera_recording_policies` (default `:off`).
   - Create `platform.camera_visual_index_jobs`, `platform.camera_visual_frames`, and `platform.camera_visual_embeddings` (with `pgvector` partial HNSW indexes for `512` and `768` dimensions).
   - Add `AFTER UPDATE` purge trigger on `platform.camera_recording_catalog` for `quarantined` and terminal deleted/reclaimed states.
   - Extend `platform.camera_recording_access_audits` check constraint to permit `event_kind = 'semantic_search'` with nullable `camera_source_id` on multi-camera queries while keeping append-only trigger protection intact.
2. **Default runtime posture**:
   - `helm/serviceradar/values.yaml` ships with `mediaWorker.enabled: false`.
   - Existing continuous NVR policies keep `visual_index_mode = :off`, producing zero outbox rows, zero JetStream messages, and zero CNPG vector writes.
3. **Rollback**:
   - Setting `mediaWorker.enabled: false` or `visual_index_mode = :off` immediately halts indexing with zero impact on NVR recording, retention, holds, or HLS timeline playback.

---

## Open Questions

Each open question records the default this design adopts unless product review chooses otherwise:

1. **Default Stage 1 + Stage 2 ONNX model pair.** Pin `YOLOv8s` (Apache/AGPL licensing check required -- prefer Apache-2.0 `RT-DETR-r18` / `DFINE-s` to keep licensing clean!) + Apache-2.0 `SigLIP-base-patch16-384` (`768`-d)? **Default**: Apache-2.0-licensed detector (`RT-DETR-r18` / `DFINE-s` ONNX) + Apache-2.0 `SigLIP-base-patch16-384` (`768`-d), avoiding AGPL model/code dependencies; verify licenses and SHA-256 digests in Stage 0 before committing Bazel pins.
2. **Static-scene keyframe suppression.** When Stage 1 detects `0` foreground subjects and the frame's downsampled L1 delta from the previous indexed keyframe in the same block is `< 2%`, skip redundant `:scene` embeddings after the block's first keyframe? **Default**: Yes, configurable (`skip_unchanged_empty_scenes: true`), cutting idle night/corridor vector volume by 70-90% without losing subject recall.
3. **Thumbnail persistence vs on-demand timeline frame preview.** Store separate JPEG crop thumbnails in object storage, or render hit previews from the authorized timeline fragment / client-side `<video>` seek? **Default**: Client-side `<video>` seek + timeline deep-link in the initial release (zero extra S3 objects or derivative retention surface); optional encrypted/scoped crop thumbnails can be added later if grid previews require them.
4. **`pgvector` `halfvec` (`float16`) vs `vector` (`float32`) HNSW storage.** `pgvector` `>= 0.7` supports `halfvec` to halve index RAM with negligible recall delta on L2-normalized embeddings. **Default**: Verify the shipped CNPG image's `pgvector` version in Stage 0; use `vector` (`float32`) as the portable baseline and adopt `halfvec` if CNPG `pgvector >= 0.7` is confirmed across all supported PostgreSQL/Timescale images.
