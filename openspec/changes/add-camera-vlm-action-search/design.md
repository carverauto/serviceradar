## Context

ServiceRadar's camera visual search pipeline (`openspec/specs/camera-semantic-search/spec.md` and `openspec/specs/vms-media-workers/spec.md`) currently runs a two-stage pipeline inside `serviceradar-media-worker`:
1. Stage 1 (`yolox-s`) detects foreground subjects (`person`, `vehicle`, `bicycle`, `animal`, `package`) on sampled H.264 IDR keyframes.
2. Stage 2 (`siglip-b16-384`) embeds the full scene and admitted subject crops into 768-dimensional vectors stored in `platform.camera_visual_embeddings`.

`ServiceRadar.Camera.SemanticSearch` embeds a user's natural-language query via the reserved interactive NATS RPC lane (`media.rpc.visual_text_embed.v1`) and runs pre-filtered `pgvector` HNSW cosine k-NN over `platform.camera_visual_embeddings`. While effective for appearance and object queries (`"person in red jacket"`), single-frame `SigLIP` cannot reliably capture temporal actions (`"child doing pushups"`, `"delivery driver leaving a box"`).

Operators need action-level semantic search that:
- runs on-premises across GPU node fleets with zero external internet egress, or optionally targets an operator-configured external OpenAI-compatible VLM endpoint;
- keeps YOLOX+SigLIP visual indexing latency sub-2s and isolated from VLM inference latency;
- bounds GPU cost by captioning only Smart event clips (`person`, `animal`, `vehicle`, `package`);
- enforces the exact same RBAC, camera scope, quarantine, retention, hold, and unified CNPG credential boundaries as the existing recording and visual search plane.

## Goals / Non-Goals

- **Goals:**
  - Trigger asynchronous multi-frame VLM action captioning only for Smart event spans (`person`, `animal`, `vehicle`, `package`) on opt-in recording policies.
  - Decouple captioning from `media.jobs.visual_index.v1` using dedicated JetStream subjects (`media.jobs.visual_caption.v1` and `media.results.visual_caption.v1`) so YOLOX+SigLIP indexing and thumbnails stay fast and historical Smart clips can be backfilled.
  - Support both an in-cluster GPU `Qwen2.5-VL-7B-Instruct` (`Q4_K_M` GGUF via `llama-server`) service and a configurable external OpenAI-compatible `/v1/chat/completions` endpoint with optional API key stored in `platform.network_credential_secrets`.
  - Persist structured captions (`caption_text`, `action_tags`, `caption_tsv`, `caption_embedding`) in `platform.camera_visual_clip_captions` via Ash resource `ServiceRadar.Camera.VisualClipCaption`.
  - Combine caption full-text (`websearch_to_tsquery`), caption semantic vector (`caption_embedding`), and visual frame/crop vector (`camera_visual_embeddings`) rankings using Reciprocal Rank Fusion (RRF) inside `ServiceRadar.Camera.SemanticSearch`.
  - Surface `caption_text` and `action_tags` on search results, clip cards, and the Clip Playback Modal.
- **Non-Goals:**
  - Continuous 24/7 VLM captioning of empty video or raw motion-only blocks.
  - Real-time live-stream VLM captioning on the Membrane relay path.
  - Storing customer external VLM API keys in Kubernetes Secrets, Helm values, or process environment variables.
  - Allowing `serviceradar-media-worker` or the VLM server to write directly to CNPG (all results MUST traverse NATS JetStream).

## Decisions

### 1. Decoupled Async JetStream Caption Pipeline (`media.jobs.visual_caption.v1`)
- **Decision:** After `VisualIndexResultProjector` commits frames and detections for a `RecordingCatalogEntry`, if the camera's `CameraRecordingPolicy` has VLM action captioning enabled and the block contains at least one admitted Smart detection (`person`, `animal`, `vehicle`, `package`), Core creates an idempotent CNPG outbox row (`platform.camera_visual_caption_jobs`, keyed by `(catalog_entry_id, span_start_us, span_end_us, vlm_model_id, prompt_version)`) and dispatches a metadata-only job envelope to `media.jobs.visual_caption.v1`.
- **Execution:** A dedicated caption consumer lane in `serviceradar-media-worker` (or a Core-orchestrated caption worker when targeting an external endpoint via `ServiceRadar.HTTP.EgressClient`) obtains an execution-time scoped fragment read grant from `VisualWorkerReadGrants`, verifies fragment SHA-256 digests, uniformly samples 4-8 JPEG keyframes across `[start_us, end_us]`, calls the configured OpenAI-compatible `/v1/chat/completions` VLM endpoint with a structured JSON prompt requesting `caption_text` (1-2 sentences) and `action_tags` (`<= 12` concise lowercase tags), embeds `caption_text` using the active 768-d text embedder (`SigLIP` text tower or configured text embedder), and publishes the normalized result envelope to `media.results.visual_caption.v1`.
- **Alternatives considered:**
  - *Inline VLM call inside `media.jobs.visual_index.v1`*: Rejected because 1.5-2s VLM inference per clip would inflate YOLOX+SigLIP latency, delay clip thumbnails, and make historical Smart-clip backfills coupled to full visual re-indexing.
  - *Direct DB writes from worker*: Rejected per ServiceRadar's JetStream-first architecture invariant.

### 2. Dual VLM Runtime Model (In-Cluster GPU + External OpenAI-Compatible Endpoint)
- **Decision:** Support two mutually selectable VLM provider modes configured in recording/visual settings:
  1. **In-cluster `Qwen2.5-VL-7B-Instruct` (`Q4_K_M` GGUF via `llama-server`):** Deployed via opt-in Helm template (`vlmServer.enabled: true`) exposing an internal ClusterIP OpenAI-compatible `/v1/chat/completions` endpoint across GPU nodes (`nvidia.com/gpu`, horizontally scalable replicas with `maxSurge: 0, maxUnavailable: 1`, sharing the read-only RWX models PVC or a dedicated VLM PVC). Enforces strict `NetworkPolicy`: ingress allowed only from `serviceradar-media-worker` and `serviceradar-web-ng` / `serviceradar-core-elx`, and zero external internet egress.
  2. **External OpenAI-compatible VLM endpoint:** Operator configures endpoint URL (`https://...`), `vlm_model_id`, optional timeout/concurrency bounds, and an optional credential reference pointing to `platform.network_credential_secrets` (unified CNPG credential model). Outbound HTTP calls route through `ServiceRadar.HTTP.EgressClient` with SSRF/private-network protections and TLS verification.
- **Alternatives considered:**
  - *Embedding a C++/GGUF VLM directly inside `serviceradar-media-worker`*: Rejected for this change because it couples `serviceradar-media-worker`'s Rust/Candle binary to `llama.cpp`, complicates GPU VRAM isolation between `YOLOX`+`SigLIP` and a 7B VLM, and prevents horizontal scaling of VLM replicas independently of media workers. Longer-term exploration of a pure-Rust Candle VLM backend is tracked separately in [Issue #7010](https://github.com/carverauto/serviceradar/issues/7010).
  - *Kubernetes Secret for external VLM API key*: Rejected because ServiceRadar requires all third-party/external integration credentials to live in `platform.network_credential_secrets`.

### 3. CNPG Schema and Ash Resource (`ServiceRadar.Camera.VisualClipCaption`)
- **Decision:** Add `platform.camera_visual_clip_captions` managed via Ash codegen (`ServiceRadar.Camera.VisualClipCaption`) with:
  - `id` (UUID PK)
  - `camera_source_id` (UUID, FK/indexed), `stream_profile_id` (UUID), `catalog_entry_id` (UUID, indexed), `visual_frame_id` (UUID, anchor frame reference)
  - `start_us` (`bigint`), `end_us` (`bigint`), `time_basis` (`:received | :camera_reported`)
  - `caption_text` (`text`, non-empty, bounded length)
  - `action_tags` (`text[]`, normalized lowercase tags, GIN indexed)
  - `caption_tsv` (`tsvector` generated always from `caption_text || ' ' || array_to_string(action_tags, ' ')` with GIN index)
  - `caption_embedding` (`vector` L2-normalized with partial expression HNSW cosine indexes for `vector(768)` and `vector(1152)` keyed by `embedding_dim`, matching the active text embedder)
  - `vlm_model_id` (`text`), `prompt_version` (`text`), `embedder_model_id` (`text`), `embedder_model_version` (`text`), `embedding_dim` (`integer`), `generated_at` (`utc_datetime_usec`)
  - Unique identity constraint on `(catalog_entry_id, start_us, end_us, vlm_model_id, prompt_version)` for idempotent JetStream redelivery upserts.
- **Retention & Quarantine Coupling:** Extend `RecordingCatalogEntry` terminal deletion and `quarantine_in_place` cleanup paths to immediately delete associated `platform.camera_visual_clip_captions` and cancel pending `platform.camera_visual_caption_jobs` rows while preserving captions for entries pinned by an accepted `RecordingHold`.

### 4. Phased Visual Embedder Upgrade (`siglip-b16-384` `768`-d -> `siglip2-so400m-p14-384` `1152`-d)
- **Decision:** Support a phased, zero-downtime upgrade path from `siglip-b16-384` (`768`-d) to `siglip2-so400m-p14-384` (`1152`-d) in `platform.camera_visual_embeddings`, `platform.camera_visual_clip_captions`, `ServiceRadar.Camera.SemanticSearch`, `VisualIndexDispatcher`, `VisualIndexResultProjector`, `serviceradar-media-worker`, and Helm configuration:
  - Add a partial expression HNSW cosine index (`(embedding::vector(1152)) vector_cosine_ops WHERE embedding_dim = 1152`) on `platform.camera_visual_embeddings` (and `caption_embedding::vector(1152)` on `platform.camera_visual_clip_captions`) so `1152`-d and existing `768`-d rows coexist cleanly without destructive table rewrites.
  - Keep strict `(model_id, model_version, embedding_dim)` isolation on `media.jobs.visual_index.v1`, `media.rpc.visual_text_embed.v1`, and `SemanticSearch` queries so `768`-d and `1152`-d spaces are never mixed in a single cosine distance comparison.
  - Use bounded `VisualIndexBackfill` to re-index playable, non-quarantined `RecordingCatalogEntry` blocks into `siglip2-so400m-p14-384` (`1152`-d) before switching the active search model identity.

### 5. Hybrid Search via Reciprocal Rank Fusion (RRF)
- **Decision:** Extend `ServiceRadar.Camera.SemanticSearch` to execute three pre-filtered candidate legs strictly scoped to `camera_source_id = ANY($authorized_camera_ids)`, the bounded `[from_us, to_us]` window, and playable non-quarantined `RecordingCatalogEntry` rows:
  1. **Caption Full-Text Leg:** `caption_tsv @@ websearch_to_tsquery('english', $query)` ranked by `ts_rank_cd`.
  2. **Caption Semantic Vector Leg:** `caption_embedding <=> $query_vec` over `platform.camera_visual_clip_captions` (using the same interactive text-embedder RPC vector already computed for the query).
  3. **Visual Frame/Crop Vector Leg:** Existing `platform.camera_visual_embeddings` `SigLIP` crop/scene cosine k-NN.
- Fuse candidate clip intervals with Reciprocal Rank Fusion:
  `rrf_score(clip) = sum_leg(weight_leg / (k + rank_leg))` (default `k = 60`), preserving existing temporal coalescing, capture-time camera labels, `time_basis`, and normalized `[x1, y1, x2, y2]` anchor bounding boxes while attaching `caption_text`, `action_tags`, and `match_sources` (`[:caption_fts, :caption_vector, :visual_vector]`).
- **Degraded Embedder Fallback Behavior:** If a query hits `camera_visual_clip_captions` via full-text search while the interactive text embedder is unavailable, preserve existing fail-closed semantics when strict vector mode is required OR return explicit degraded metadata only when hybrid FTS fallback is explicitly opted in (default: maintain existing `search_embedder_unavailable` fail-closed contract unless configured otherwise, documented clearly in spec scenarios). Wait — keeping `SemanticSearch` fail-closed when the text embedder is unavailable matches the existing `vms-media-workers` spec (`Compatible text-embedding worker unavailable or timed out`). Let's ensure full-text + vector hybrid fusion runs whenever the query embedding succeeds, and explicitly document the fail-closed contract when the embedder is unavailable.

## Risks / Trade-offs

- **GPU VRAM contention between `serviceradar-media-worker` and `vlm-server`:**
  - *Mitigation:* Deploy `vlm-server` as a separate Kubernetes Deployment with explicit `nvidia.com/gpu` resource requests/limits and `Recreate` / `maxSurge: 0, maxUnavailable: 1` strategy, allowing operators to place VLM replicas on dedicated GPUs or time-sliced pools without destabilizing `YOLOX`+`SigLIP` workers.
- **Hallucinated or verbose VLM captions degrading search precision:**
  - *Mitigation:* Enforce a versioned, concise structured JSON system prompt (`prompt_version`) requiring 1-2 factual sentences grounded strictly in visible actions, bound output tokens (`max_tokens <= 160`), validate/sanitize JSON before projection, and include `prompt_version` in the idempotency key so prompt upgrades can be backfilled cleanly.
- **External VLM endpoint latency or SSRF abuse:**
  - *Mitigation:* Decoupled async JetStream jobs prevent slow external endpoints from affecting NVR capture, live playback, or YOLOX indexing. Outbound calls use `ServiceRadar.HTTP.EgressClient` with explicit host/IP SSRF validation, TLS enforcement, bounded per-request timeouts, and circuit-breaking / terminal retry caps (`MaxDeliver`).
- **JetStream storage growth from base64 JPEGs:**
  - *Mitigation:* `media.jobs.visual_caption.v1` envelopes carry metadata only (no media bytes); `media.results.visual_caption.v1` envelopes carry text captions, tags, and one compact 768-d embedding (no image bytes), keeping message sizes well under 16 KiB.

## Migration Plan

1. Ship CNPG migrations (`platform.camera_visual_clip_captions`, `platform.camera_visual_caption_jobs`, `CameraRecordingPolicy` opt-in column defaulting to disabled) and Ash resources.
2. Deploy opt-in Helm `vlmServer` templates and NATS JetStream stream/permission definitions (disabled by default; zero impact on existing clusters).
3. Ship `serviceradar-media-worker` caption consumer and Core `VisualCaptionDispatcher` / `VisualCaptionResultProjector` / `VisualCaptionBackfill`.
4. Enable hybrid RRF search in `ServiceRadar.Camera.SemanticSearch` (backward-compatible: when `camera_visual_clip_captions` is empty, RRF degenerates cleanly to the existing visual embedding ranking) and surface captions on clip cards and the Clip Playback Modal.
5. Rollback: disabling captioning on `CameraRecordingPolicy` stops new jobs immediately; `SemanticSearch` continues serving visual-only hits seamlessly.
