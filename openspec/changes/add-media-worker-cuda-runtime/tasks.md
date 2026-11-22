# Tasks

## 1. Worker

- [x] 1.1 `MEDIA_WORKER_DTYPE` (`auto|f32|f16`) in config and CLI; candle backend
      loads weights and casts inputs in the resolved dtype; outputs stay f32.
- [x] 1.2 Report the resolved precision (`inference_dtype`) without changing the
      model identity.
- [x] 1.3 Refuse a checkpoint whose tower widths differ from `embedding_dim`; the
      warm-up checks real output against the configured width.
- [x] 1.4 Run model load and warm-up off the async runtime; report `warmup_ms`.
- [x] 1.5 Log whether the CUDA JIT cache is writable; never fail on it.
- [x] 1.6 `auto` device follows the execution provider; `cuda` + `cpu_explicit`
      is refused.
- [x] 1.7 Bounded parallel SigLIP preprocessing with identical output.
- [x] 1.8 Tests: f16/f32 cosine bound on CPU, preprocessing identity, width
      refusal, warm-up before readiness, cache-path rules.

## 2. Build and publish

- [x] 2.1 `scripts/build-media-worker-cuda.sh` (toolchain fetch, crate-mirror
      vendoring, `--features cuda --locked` build, library collection, manifest).
- [x] 2.2 `scripts/ci/media-worker-cuda-image.py` (bundle verification,
      reproducible layer, crane assembly, registry checks).
- [x] 2.3 `SERVICERADAR_NATIVE_IMAGE` signing mode and `NATIVE_BUILD_IMAGES`.
- [x] 2.4 `publish-media-worker-cuda.yml` and contract tests.
- [ ] 2.5 First run on `serviceradar-arm64-build` after the gitops runner lands;
      record the library sha256s it reports.
- [ ] 2.6 Deploy check on a GPU node: `/readyz` shows `inference_device=cuda:0`,
      `inference_dtype=f16`, `warmup_ms`; a second start with the cache volume is
      fast.

## 3. Docs

- [x] 3.1 Worker README (GPU build, precision, warm-up, JIT cache).
- [x] 3.2 `docs/media-worker-cuda-image.md` (workflow, image, chart reference).
