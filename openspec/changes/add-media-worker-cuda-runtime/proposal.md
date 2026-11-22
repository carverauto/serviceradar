# Change: CUDA runtime for the media worker and a separate CUDA image

## Why

`serviceradar-media-worker` runs SigLIP on the CPU in every shipped image: the
`cuda` Cargo feature exists, but nothing builds it. On the CPU the vision tower
manages about 1.6 images/s on 8 cores, so live visual indexing cannot keep up
with even a few cameras. A spike on the target hardware (arm64 DGX Spark, GB10,
compute capability 12.1, driver 580, CUDA 13.0) built the worker's pinned
candle 0.11.1 / cudarc 0.19.10 with `--features cuda` unpatched and measured:

- f32 on CUDA: about 52 images/s, max abs difference 2.3e-7 against the CPU;
- f16 on CUDA: 120-130 images/s, max abs difference 6.4e-4, minimum cosine
  0.9999983 against CPU f32; text query p50 2.2 ms (CPU: 76 ms);
- the first CUDA call in a fresh process JIT-compiles PTX for 8.8 s, 0.3 s with
  a warm `CUDA_CACHE_PATH`.

A CUDA binary will not start without `libcuda.so.1`, so it cannot share the CPU
multi-arch image, and Bazel RBE (amd64-only, no CUDA toolkit) cannot build it.

## What Changes

- **Precision setting.** `MEDIA_WORKER_DTYPE=auto|f32|f16` (`--dtype`), default
  `auto`: f16 on CUDA, f32 on the CPU. Inputs are cast to the model dtype on the
  device; embeddings are still returned as L2-normalised f32 in the same space.
  The reported `(model_id, model_version, embedding_dim)` does not change with
  precision; the resolved precision is reported separately (`inference_dtype`).
- **Embedding-width admission.** At load, the candle backend refuses a
  checkpoint whose image or text tower does not emit the configured
  `embedding_dim`, and the warm-up checks real output against that width.
- **Warm-up before readiness.** The existing synthetic image + text warm-up
  (which on CUDA absorbs the JIT compile) now runs off the async runtime so
  `/healthz` keeps answering; `/readyz` reports `warmup_ms`. The worker logs
  whether `CUDA_CACHE_PATH` is writable and continues when it is not.
- **Device rules.** `MEDIA_WORKER_DEVICE=auto` follows the execution provider:
  CUDA (or a hard failure) for `cuda`, the CPU for `cpu_explicit`.
  Candle refuses `tensorrt` and rejects the CUDA device with `cpu_explicit`.
- **Parallel preprocessing.** Frame preprocessing for one batch is split across
  at most `cores / index_concurrency` scoped threads with identical output.
- **CUDA image.** `serviceradar-media-worker-cuda` (linux/arm64): the pinned
  ubuntu:24.04 base the CPU image uses, the binary, the CUDA runtime libraries it
  links (cuBLAS, cuBLASLt, cuRAND, NVRTC, cudart) from the pinned NVIDIA CUDA
  13.0.3 devel image, the pinned Mozilla CA bundle and the `serviceradar` user.
  `libcuda.so.1` comes from the host via the NVIDIA container runtime.
- **Build and publish workflow.** `publish-media-worker-cuda.yml` builds on the
  credential-less arm64 runner inside the digest-pinned CUDA devel image from the
  checked-in crate mirror, then a separate job on the signing runner verifies the
  bundle, assembles the image with crane, signs it through
  `scripts/sign-oci-publish.sh` (new `SERVICERADAR_NATIVE_IMAGE` single-image
  mode, admitted only for images in `NATIVE_BUILD_IMAGES`) and promotes it as
  `sha-<commit>`. Publishing is limited to the refs the signing role admits.

## Impact

- Affected specs: `vms-media-workers`.
- Affected code: `rust/media-worker` (backend, candle backend, capability,
  config, main), `scripts/build-media-worker-cuda.sh`,
  `scripts/ci/media-worker-cuda-image.py`, `scripts/sign-oci-publish.sh`,
  `docker/images/image_inventory.bzl`, `.github/workflows/publish-media-worker-cuda.yml`.
- The Helm chart selects the image separately (`mediaWorker.image`); this change
  does not edit the chart.
- Depends on the `serviceradar-arm64-build` ARC scale set (gitops).
