## ADDED Requirements

### Requirement: In-cluster GPU VLM runtime and configurable external OpenAI-compatible VLM endpoint
The system SHALL support both an opt-in Helm-managed in-cluster GPU VLM service (`Qwen2.5-VL-7B-Instruct` `Q4_K_M` GGUF via `llama-server` exposing an OpenAI-compatible `/v1/chat/completions` vision API with zero external internet egress) and an operator-configured external OpenAI-compatible VLM endpoint whose optional API key is stored exclusively in `platform.network_credential_secrets` and accessed through `ServiceRadar.HTTP.EgressClient` with SSRF protections.

#### Scenario: In-cluster GPU VLM server deploys across GPU nodes with strict network isolation
- **WHEN** an operator enables the in-cluster VLM server in Helm (`vlmServer.enabled = true`) across one or more GPU nodes (`nvidia.com/gpu`)
- **THEN** the chart SHALL deploy `serviceradar-vlm-server` mounting read-only model weights from the configured PVC, exposing `/v1/chat/completions` only on a ClusterIP Service, and enforcing a `NetworkPolicy` that allows ingress solely from authorized media/core workloads and denies all external internet egress

#### Scenario: External OpenAI-compatible VLM endpoint uses unified CNPG credentials and EgressClient
- **WHEN** an operator configures an external OpenAI-compatible VLM endpoint URL, model name, and optional credential reference
- **THEN** the system SHALL resolve the API key exclusively from `platform.network_credential_secrets` (never from Kubernetes Secrets, Helm values, or environment variables) and execute outbound HTTP requests via `ServiceRadar.HTTP.EgressClient` with TLS verification, SSRF protections, and bounded request timeouts

### Requirement: Multi-frame keyframe extraction and decoupled VLM caption execution
The system SHALL execute `media.jobs.visual_caption.v1` jobs asynchronously outside the `media.jobs.visual_index.v1` indexing semaphore by obtaining an execution-time scoped fragment read grant from `VisualWorkerReadGrants`, verifying frozen fragment SHA-256 digests, extracting 4 to 8 uniformly sampled JPEG keyframes across the Smart event span, invoking the configured VLM `/v1/chat/completions` endpoint with a versioned structured prompt, computing the L2-normalized `caption_embedding`, and publishing the result envelope to `media.results.visual_caption.v1`.

#### Scenario: Worker samples 4 to 8 keyframes and publishes structured action caption
- **WHEN** `serviceradar-media-worker` pulls a `media.jobs.visual_caption.v1` job for a playable Smart event span `[start_us, end_us]`
- **THEN** the worker SHALL obtain a short-lived scoped read grant, verify `init.mp4` and fragment SHA-256 digests, uniformly sample 4 to 8 JPEG keyframes across the span, call the configured OpenAI-compatible `/v1/chat/completions` VLM endpoint to obtain a bounded `caption_text` and `action_tags`, compute `caption_embedding`, and publish the result to `media.results.visual_caption.v1` without blocking `media.jobs.visual_index.v1` or `media.rpc.visual_text_embed.v1`

#### Scenario: Deleted or quarantined span aborts caption job cleanly
- **WHEN** a worker requests a read grant for a `media.jobs.visual_caption.v1` job whose `RecordingCatalogEntry` has been deleted or transitioned to `local_state = :quarantined`
- **THEN** `VisualWorkerReadGrants` SHALL refuse media access with a terminal gone status and the worker SHALL acknowledge the JetStream job as skipped without invoking the VLM endpoint or retrying
