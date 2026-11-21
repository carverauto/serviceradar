## ADDED Requirements

### Requirement: Separate CUDA media worker image
The system SHALL publish the CUDA build of `serviceradar-media-worker` as a separate `linux/arm64` image, `serviceradar-media-worker-cuda`, tagged `sha-<full commit sha>`, because a CUDA binary cannot start without the host driver's `libcuda.so.1`. The image SHALL contain the worker binary, the CUDA runtime libraries the binary loads, a CA bundle and a non-root user, and SHALL NOT contain `libcuda.so.1` or any other driver library. The binary SHALL be built without registry or signing credentials, and the image SHALL be signed through the same release-key signing path as every other published image, only from the refs that signing path admits.

#### Scenario: CUDA image runs on a GPU node
- **WHEN** a pod runs `serviceradar-media-worker-cuda` with an NVIDIA GPU allocation and the NVIDIA container runtime
- **THEN** the runtime SHALL inject `libcuda.so.1` from the host and the worker SHALL resolve every other CUDA library from the image

#### Scenario: Build job cannot publish
- **WHEN** the CUDA build job runs
- **THEN** it SHALL have no registry credential, signing credential or OIDC token, and SHALL hand the publish job only a bundle whose `SHA256SUMS` digest it reported as a job output

#### Scenario: Tampered bundle is not published
- **WHEN** any file in the bundle the publish job downloads differs from the build job's reported digest
- **THEN** the publish job SHALL stop before it touches any credential

#### Scenario: Unadmitted ref
- **WHEN** the workflow runs on a ref other than `staging` or `test/demo-test-<N>`
- **THEN** it SHALL build but SHALL NOT push, sign or promote an image

### Requirement: Precision-independent embedding identity
The worker SHALL let the operator choose the SigLIP compute precision (`MEDIA_WORKER_DTYPE`: `auto`, `f32` or `f16`; `auto` is `f16` on CUDA and `f32` on the CPU), SHALL return L2-normalised `f32` embeddings in the same vector space at every precision, and SHALL report the same `(model_id, model_version, embedding_dim)` at every precision, so that workers of different precision in one deployment serve and match each other's embeddings. The resolved precision SHALL be reported separately in the capability manifest.

#### Scenario: Mixed-precision workers share an index
- **WHEN** one worker indexes keyframes at `f32` and another embeds a search query at `f16` for the same model version
- **THEN** both SHALL advertise the same `(model_id, model_version, embedding_dim)` and the query SHALL be matched against the index without re-embedding

#### Scenario: Unsupported precision value
- **WHEN** `MEDIA_WORKER_DTYPE` is set to a value other than `auto`, `f32` or `f16`
- **THEN** the worker SHALL refuse to start with a configuration error

### Requirement: Embedding width admission
The worker SHALL refuse to start when the loaded checkpoint's image or text tower emits an embedding width other than the configured `embedding_dim`, determined from the loaded model configuration and the warm-up output rather than from file names.

#### Scenario: Checkpoint of the wrong width
- **WHEN** the configured `embedding_dim` is 768 and the checkpoint's towers emit 1024-dimensional embeddings
- **THEN** the worker SHALL exit with an error naming both widths and SHALL NOT report ready

### Requirement: GPU warm-up before readiness
The worker SHALL run a warm-up image and text inference on the selected device before it reports ready, claims indexing jobs or answers text-embedding requests, so the first job does not pay CUDA kernel JIT compilation; it SHALL keep answering liveness probes while warming up, SHALL report the warm-up duration, and SHALL log, without failing, when the CUDA JIT cache location is not writable.

#### Scenario: Cold start on a GPU
- **WHEN** the worker starts on CUDA with an empty JIT cache
- **THEN** `/healthz` SHALL answer while `/readyz` returns 503 until the warm-up completes, and `/readyz` SHALL then report `warmup_ms`

#### Scenario: Read-only JIT cache
- **WHEN** `CUDA_CACHE_PATH` names a location the worker cannot write
- **THEN** the worker SHALL log a warning and continue starting

#### Scenario: CUDA requested but unavailable
- **WHEN** the execution provider is `cuda` and CUDA device initialisation fails
- **THEN** the worker SHALL exit with an error and SHALL NOT fall back to the CPU

#### Scenario: TensorRT requested for Candle
- **WHEN** the execution provider is `tensorrt` and the backend is Candle
- **THEN** the worker SHALL refuse startup before warm-up, even when TensorRT is installed

## MODIFIED Requirements

### Requirement: Standalone GPU media worker capability admission
The system SHALL execute recorded-block visual decoding and neural inference in a standalone multi-architecture (`linux/amd64` and `linux/arm64`) `serviceradar-media-worker` OS process outside the BEAM ERTS cluster, and SHALL admit jobs only after verifying the configured hardware execution provider, model artifact SHA-256 digests, and GPU sharing class at startup without silent CPU fallback.

#### Scenario: Verified GPU execution provider startup admission
- **WHEN** `serviceradar-media-worker` starts with `execution_backend` set to `cuda` on an `amd64` or `arm64` GPU node
- **THEN** the worker SHALL verify the pinned detector and vision-language model SHA-256 digests, execute a synthetic forward-pass self-test on the configured execution provider, and report the observed architecture, driver/CUDA version, GPU sharing class (`physical`, `mig`, or `time_sliced`), and loaded `(model_id, model_version, embedding_dim)` before pulling jobs from `media.jobs.visual_index.v1`

#### Scenario: Missing GPU runtime or unsupported execution provider fails closed
- **WHEN** `serviceradar-media-worker` is configured for `cuda` acceleration and the NVIDIA device plugin, CUDA runtime, or device memory check fails initialization, or is configured for an unsupported execution provider such as `tensorrt`
- **THEN** the worker SHALL fail readiness explicitly and refuse to pull visual indexing jobs
- **AND** the worker SHALL NOT fall back to unbounded CPU inference unless `execution_backend` is explicitly configured as `cpu_explicit` with bounded single-worker concurrency

#### Scenario: Media worker crash or exhaustion isolates recording and live playback
- **WHEN** all `serviceradar-media-worker` replicas crash, restart, or saturate their GPU concurrency semaphore
- **THEN** continuous NVR capture, archive uploads, live camera relay sessions, and recorded HLS timeline playback SHALL continue operating normally in the BEAM cluster without interruption
