# Change: Event-Triggered Multi-Frame VLM Action Captioning and Hybrid Search

## Why

Single-frame contrastive embeddings (`SigLIP`) excel at static visual attributes (object class, clothing color, scene appearance) but cannot reliably distinguish temporal actions or multi-step activities such as `"child doing pushups"`, `"delivery driver leaving a box"`, or `"dog sitting on the porch at night"`. Adding event-triggered multi-frame Vision-Language Model (VLM) action captioning with PostgreSQL full-text and semantic hybrid search unlocks natural-language activity retrieval over recorded Smart clips without running continuous 24/7 VLM inference on empty footage or blocking sub-2s YOLOX+SigLIP indexing latency.

## What Changes

- **Event-Triggered Async Caption Pipeline (JetStream-first):** Enqueue decoupled `media.jobs.visual_caption.v1` jobs only for sealed, non-quarantined `RecordingCatalogEntry` spans where Stage 1 (`YOLOX`) detected Smart categories (`person`, `animal`, `vehicle`, or `package`) — never raw motion or empty 24/7 video. Publish normalized caption results back over `media.results.visual_caption.v1` for idempotent Core projection, and support bounded historical backfill of existing playable Smart clips.
- **In-Cluster GPU VLM Runtime and External OpenAI-Compatible Endpoint:** Add an opt-in Helm-managed in-cluster `Qwen2.5-VL-7B-Instruct` (`Q4_K_M` GGUF via `llama-server` serving `/v1/chat/completions`) deployable across GPU node pools (`nvidia.com/gpu`) with zero external internet egress, plus a configurable external OpenAI-compatible VLM endpoint whose optional API key is stored exclusively in `platform.network_credential_secrets` via the unified CNPG credential model and invoked through `ServiceRadar.HTTP.EgressClient` with SSRF protections. Longer-term pure-Rust embedded Candle VLM inference is tracked separately in [Issue #7010](https://github.com/carverauto/serviceradar/issues/7010).
- **Multi-Frame Keyframe Sampling:** Sample 4-8 uniformly distributed JPEG keyframes across each Smart event span using existing scoped fragment read grants and SHA-256 digest verification so the VLM observes temporal progression across the clip.
- **Caption Storage and Ash Resource:** Add `platform.camera_visual_clip_captions` backed by Ash resource `ServiceRadar.Camera.VisualClipCaption` storing `caption_text`, `action_tags` (`text[]`), generated `caption_tsv` (`tsvector` + GIN index), `caption_embedding` (`vector(768)` or `vector(1152)` matching the active text embedder + HNSW cosine index), `vlm_model_id`, `prompt_version`, and `generated_at`, strictly coupled to `RecordingCatalogEntry` retention, quarantine, and hold lifecycles.
- **Hybrid Reciprocal Rank Fusion (RRF) Search and UI Surfacing:** Extend `ServiceRadar.Camera.SemanticSearch` to fuse (1) PostgreSQL `websearch_to_tsquery` full-text rank and `caption_embedding` cosine rank over `camera_visual_clip_captions` with (2) existing `camera_visual_embeddings` `SigLIP` crop/scene cosine rank via RRF, preserving all RBAC (`devices.view` + `devices.cameras.recordings.view`), camera source pre-filtering, and `RecordingAccessAudit` invariants. Return `caption_text` and `action_tags` on search hits and surface them on clip cards and inside the Clip Playback Modal.
- **Phased Visual Embedder Upgrade (`siglip-b16-384` `768`-d -> `siglip2-so400m-p14-384` `1152`-d):** Add a phased, model-versioned upgrade track enabling `siglip2-so400m-p14-384` (`1152`-d) embeddings with dedicated `vector(1152)` HNSW cosine indexing and bounded `VisualIndexBackfill` alongside existing `768`-d rows without breaking active search during cutover.

## Impact

- Affected specs:
  - `camera-semantic-search` (added requirements for event-triggered VLM captioning, hybrid RRF search, caption retention/quarantine/hold coupling, and UI caption surfacing)
  - `vms-media-workers` (added requirements for in-cluster GPU VLM runtime, external OpenAI-compatible VLM endpoint integration, and decoupled multi-frame caption job execution)
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/camera/` (`VisualClipCaption`, `VisualCaptionJob`, `VisualCaptionDispatcher`, `VisualCaptionResultProjector`, `VisualCaptionBackfill`, `SemanticSearch`, `RecordingEventClips`, retention/quarantine purge paths)
  - `elixir/serviceradar_core/priv/repo/migrations/` (Ash-generated migration for `platform.camera_visual_clip_captions` and `platform.camera_visual_caption_jobs`)
  - `rust/media-worker/` (async `media.jobs.visual_caption.v1` consumer, 4-8 frame uniform sampler, OpenAI-compatible `/v1/chat/completions` VLM client, caption embedding generation)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/` (`camera_semantic_search.ex`, `camera_semantic_search_controller.ex`, `live/camera_live/recordings.ex`, `live/camera_live/recordings_components.ex`, `live/settings/recording_live/`)
  - `helm/serviceradar/` (opt-in `vlmServer` Deployment/Service/NetworkPolicy/PVC mounts, NATS JetStream stream/user permissions for `media.jobs.visual_caption.v1` and `media.results.visual_caption.v1`)
