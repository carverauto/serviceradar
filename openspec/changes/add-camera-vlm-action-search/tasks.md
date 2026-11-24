## 1. Schema, Ash Resources & Credential Integration
- [ ] 1.1 Add Ash resource `ServiceRadar.Camera.VisualClipCaption` (`platform.camera_visual_clip_captions`) with `camera_source_id`, `stream_profile_id`, `catalog_entry_id`, `visual_frame_id`, `start_us`, `end_us`, `time_basis`, `caption_text`, `action_tags` (`text[]`), generated `caption_tsv` (`tsvector` + GIN index), `caption_embedding` (`vector(768)` + HNSW cosine index), `vlm_model_id`, `prompt_version`, `embedder_model_id`, `embedder_model_version`, and `generated_at`, plus idempotent upsert action keyed by `(catalog_entry_id, start_us, end_us, vlm_model_id, prompt_version)`.
- [ ] 1.2 Add Ash resource `ServiceRadar.Camera.VisualCaptionJob` (`platform.camera_visual_caption_jobs`) and opt-in VLM captioning configuration on `CameraRecordingPolicy` (default off) and recording settings (provider mode: `:in_cluster` or `:external`, endpoint URL, `vlm_model_id`, `prompt_version`, optional `network_credential_secrets` reference).
- [ ] 1.3 Generate and verify Ash CNPG migrations (`mix ash.codegen`) including GIN indexes on `caption_tsv` and `action_tags`, HNSW cosine index on `caption_embedding`, and composite `(state, deadline_at)` index on `platform.camera_visual_caption_jobs`.
- [ ] 1.4 Wire external VLM endpoint credential resolution through `platform.network_credential_secrets` (including credential-usage inventory and guarded-deletion checks; no K8s/env secrets for customer endpoints).

## 2. Async JetStream Caption Pipeline & Backfill
- [ ] 2.1 Add JetStream stream/subject configuration and static NATS user permissions for `media.jobs.visual_caption.v1` and `media.results.visual_caption.v1` (restricted to Core and `serviceradar-media-worker`).
- [ ] 2.2 Implement `ServiceRadar.Camera.VisualCaptionDispatcher` triggered after `VisualIndexResultProjector` commits Smart detections (`person`, `animal`, `vehicle`, `package`) on caption-enabled policies, persisting durable `VisualCaptionJob` outbox rows and publishing metadata-only envelopes.
- [ ] 2.3 Implement idempotent `ServiceRadar.Camera.VisualCaptionResultProjector` consuming `media.results.visual_caption.v1` to validate schema/digest/job identity, upsert `VisualClipCaption`, complete/fail jobs, and cancel jobs for deleted or quarantined entries.
- [ ] 2.4 Implement bounded `ServiceRadar.Camera.VisualCaptionBackfill` to enqueue caption jobs for existing playable, non-quarantined Smart clips without reviving deleted or quarantined entries.
- [ ] 2.5 Couple `platform.camera_visual_clip_captions` and `platform.camera_visual_caption_jobs` to `RecordingCatalogEntry` terminal deletion, `quarantine_in_place`, and `RecordingHold` preservation.

## 3. In-Cluster VLM Runtime & Multi-Frame Worker Execution
- [ ] 3.1 Add opt-in Helm templates (`helm/serviceradar/templates/vlm-server.yaml`) for `Qwen2.5-VL-7B-Instruct` (`Q4_K_M` GGUF via `llama-server`) exposing `/v1/chat/completions`, supporting GPU node scheduling (`nvidia.com/gpu`, multi-replica `maxSurge: 0, maxUnavailable: 1`), read-only models PVC mounts, and strict zero-internet-egress `NetworkPolicy`.
- [ ] 3.2 Implement `media.jobs.visual_caption.v1` consumer in `serviceradar-media-worker` using existing `VisualWorkerReadGrants` and SHA-256 fragment verification to uniformly extract 4-8 JPEG keyframes across `[start_us, end_us]`.
- [ ] 3.3 Implement OpenAI-compatible `/v1/chat/completions` multi-image VLM client (supporting both in-cluster `vlm-server` and external endpoints via `ServiceRadar.HTTP.EgressClient` SSRF-safe egress), structured JSON parsing (`caption_text`, `action_tags`), caption text embedding, and `media.results.visual_caption.v1` result publishing.

## 4. Hybrid RRF Search & UI Caption Surfacing
- [ ] 4.1 Extend `ServiceRadar.Camera.SemanticSearch` to run pre-filtered caption full-text (`websearch_to_tsquery`) and `caption_embedding` cosine legs alongside `camera_visual_embeddings` and fuse ranked clips via Reciprocal Rank Fusion (RRF), preserving RBAC, camera scope pre-filtering, and `RecordingAccessAudit`.
- [ ] 4.2 Return `caption_text`, `action_tags`, and match provenance in `/api/cameras/search` and `RecordingEventClips` payloads.
- [ ] 4.3 Surface `caption_text` and `action_tags` on search result cards, event clip cards, and inside the Clip Playback Modal in `elixir/web-ng/lib/serviceradar_web_ng_web/live/camera_live/`.
- [ ] 4.4 Add operator settings controls in `live/settings/recording_live/` for enabling VLM action captioning, selecting in-cluster vs external VLM provider, referencing a CNPG credential, and triggering bounded Smart-clip backfill.

## 5. Phased Visual Embedder Upgrade (`siglip2-so400m-p14-384`, `1152`-d)
- [ ] 5.1 Add partial expression `vector(1152)` HNSW cosine indexes (`WHERE embedding_dim = 1152`) on `platform.camera_visual_embeddings` and `platform.camera_visual_clip_captions` so `1152`-d rows coexist cleanly alongside existing `768`-d rows.
- [ ] 5.2 Add `siglip2-so400m-p14-384` (`1152`-d) support to `serviceradar-media-worker` Candle backend, `VisualIndexDispatcher`, `VisualIndexResultProjector`, `SemanticSearch` (preserving strict `(model_id, model_version, embedding_dim)` isolation), and Helm model-identity / PVC validation.
- [ ] 5.3 Verify bounded `VisualIndexBackfill` for `siglip2-so400m-p14-384` (`1152`-d) over playable, non-quarantined blocks and document cutover alongside future pure-Rust Candle VLM exploration ([Issue #7010](https://github.com/carverauto/serviceradar/issues/7010)).

## 6. Verification & Security Tests
- [ ] 6.1 Add unit and database-backed tests covering Smart-event gating, idempotent JetStream projection, hybrid RRF ranking (`"child doing pushups"`, `"delivery driver leaving a box"`, `"dog sitting on the porch at night"`), `768`-d/`1152`-d embedder coexistence, RBAC/scope isolation, and retention/quarantine/hold cascade behavior.
- [ ] 6.2 Add Helm template and `NetworkPolicy` tests verifying zero external egress for `vlm-server`, NATS subject isolation, and refusal of insecure or incomplete VLM configuration.
- [ ] 6.3 Add `EgressClient` SSRF and unified credential tests verifying external VLM endpoints resolve API keys solely from `platform.network_credential_secrets` and block private/link-local targets when configured for public endpoints.
