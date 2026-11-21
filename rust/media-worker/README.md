# serviceradar-media-worker

Standalone worker that indexes sealed camera recording blocks for semantic search. It pulls
jobs from `media.jobs.visual_index.v1`, fetches `init.mp4` and the sampled keyframe
fragments through a read grant, verifies every byte range against the frozen descriptor
SHA-256, decodes one IDR keyframe per sampled fragment, runs SigLIP (and an optional
YOLOv8 detector) with the pure-Rust `candle` backend, and publishes
`media.results.visual_index.v1` before acknowledging the job. It also answers search-query
text embeddings over NATS.

Spec: `openspec/specs/vms-media-workers/spec.md`,
`openspec/changes/update-media-worker-real-keyframe-decode/`, and
`openspec/changes/add-media-worker-cuda-runtime/`.

## Keyframe decoding

`src/keyframe_decoder.rs` defines the `KeyframeDecoder` trait. The production
implementation, `DefaultKeyframeDecoder`, decodes H.264 in pure Rust with
`rusty_h264-decoder` (see `src/h264.rs`). Each keyframe gets a fresh decoder.

Supported:

- H.264 Constrained Baseline, Main and High profile with equal Cb and Cr quantization offsets;
- 8-bit 4:2:0, frame (progressive) coding;
- CAVLC and CABAC, 8x8 transform, scaling matrices, single-slice IDR pictures;
- SPS cropping;
- parameter sets from `avcC` for `avc1`; `avc3` also accepts in-band replacements.

The worker uses VUI colour metadata to convert decoded pixels to RGB. See the
[colour conversion rules](../../openspec/changes/update-media-worker-real-keyframe-decode/design.md#colour)
for supported matrices and defaults.

Not supported, reported as `unsupported_codec`: HEVC, other H.264 profiles (High 10,
4:2:2, 4:4:4 and so on), interlaced/MBAFF coding, FMO, SI slices, lossless macroblocks,
unequal Cb and Cr quantization offsets, multi-slice pictures, auxiliary and
extension coded slices, and unsupported VUI matrices. An SP slice in an IDR picture is
malformed and produces `malformed_bitstream`.

The per-keyframe outcome applies to granted, verified fragments. If any sampled fragment
exceeds 4 MiB, the read-grant service rejects the whole request before the worker can
fetch the fragments. The worker handles that rejection as a job-level failure.

For each verified sample it cannot decode, the worker adds an entry to
`undecodable_keyframes` with the fragment sequence (`fragment_sequence`), the sample-entry
codec (`codec`, or `unknown` if unidentified), and a `reason`. The reasons are
`unsupported_codec`, `malformed_bitstream`, `limit_exceeded`, and `invalid_container`.
The counter at `/metrics` is `serviceradar_media_worker_keyframes_undecodable_total`,
labelled by `reason`.

Only decoded samples produce frames, detections, or embeddings. A refused sample still
advances the tracker at its timestamp, so a gap longer than the track buffer ends the
track. The worker publishes the result even if every sample was refused. If all samples
decode, it omits `undecodable_keyframes`. If the verified track init cannot be parsed,
every sampled sequence gets `invalid_container`.

The worker checks both the container dimensions and the SPS coded dimensions before
decoding. Each may be at most 4096 pixels wide and 4096 pixels high. It also caps the
access unit at 4 MiB, each parameter set at 4096 bytes, and each sample at 4096 NAL
units. These limits bound the synchronous decoder call, which has no wall-clock timeout.

Truncated CABAC data can produce a picture with incorrect trailing pixels. Pictures with
I_PCM macroblocks can also have approximate edge pixels when deblocking is enabled.
See the [decoder design](../../openspec/changes/update-media-worker-real-keyframe-decode/design.md#known-gaps)
for the CAVLC truncation behavior and the reasons for the single-slice restriction.

## Images

| Image | Platforms | Device |
| --- | --- | --- |
| `serviceradar-media-worker` | amd64, arm64 | CPU (built by Bazel; `cuda` feature off) |
| `serviceradar-media-worker-cuda` | arm64 | NVIDIA GPU, compute capability 12.1 |

The CUDA image, its build and its runtime requirements are described in
[docs/media-worker-cuda-image.md](../../docs/media-worker-cuda-image.md).

Candle is the default backend and requires a checkpoint. Mount its directory read-only and set `MEDIA_WORKER_MODEL_DIR` to
its mount path. Supply `config.json`, `tokenizer.json`, and
`model.safetensors` (or `siglip.safetensors`) in that directory.

For tests, explicitly select `MEDIA_WORKER_BACKEND=stub` with
`SERVICERADAR_MEDIA_WORKER_EXECUTION_PROVIDER=cpu_explicit`. The stub emits synthetic vectors.

## Device and execution provider

| Setting | Values |
| --- | --- |
| `SERVICERADAR_MEDIA_WORKER_EXECUTION_PROVIDER` | `cuda` (default), `cpu_explicit` |
| `MEDIA_WORKER_DEVICE` / `--device` | `auto` (default), `cuda`, `cpu` |

Candle refuses startup with the `tensorrt` provider, including on hosts with
TensorRT installed. For its supported providers, device selection follows this table.

| device | `cuda` provider | `cpu_explicit` |
| --- | --- | --- |
| `auto` | CUDA, or exit with an error | CPU |
| `cuda` | CUDA, or exit with an error | refused |
| `cpu` | refused | CPU |

A binary built without the `cuda` feature (the CPU image) cannot open a CUDA
device, so it runs only with `cpu_explicit`.

## Precision

`MEDIA_WORKER_DTYPE` / `--dtype`: `auto` (default), `f32` or `f16`. `auto` is
`f16` on CUDA and `f32` on the CPU. The SigLIP weights are loaded in that dtype
and the pixel inputs are cast to it on the device. Embeddings are always returned
as L2-normalised `f32`. The detector always runs in `f32`. `f16` on the CPU works
but is slower than `f32`; it exists for testing.

Precision does not change the model identity the worker reports
(`embedder_model_id`, `embedder_model_version`, `embedding_dim`). Search matches
vectors by cosine similarity, and on the SigLIP base model f16 and f32
embeddings of the same input agree to a cosine of at least 0.9999983 (max abs
difference 6.4e-4), measured on the GB10. That error is orders of magnitude
below the score gap between different images, so a deployment can mix f16 and
f32 workers: each serves and matches the other's embeddings. Folding the
precision into the model version would instead split one index into two that
cannot see each other. The resolved precision is reported separately as
`inference_dtype` in `/readyz`. `bf16` is not offered: it drifts further (cosine
0.99993) for no speed gain over `f16` on this hardware.

Measured on the GB10 (SigLIP base patch16-384, 768-d):

| Path | Images/s (model only) | Text query p50 | GPU memory |
| --- | --- | --- | --- |
| CPU f32, 8 cores | 1.6 | 76 ms | - |
| CUDA f32 | ~52 | 5.6 ms | 5.5 GB |
| CUDA f16 | ~120-130 | 2.2 ms | 2.9 GB |

## Embedding width

At load the worker refuses a checkpoint whose image or text tower does not emit
`SERVICERADAR_MEDIA_WORKER_EMBEDDING_DIM` values (768 for `siglip-b16-384`), read
from the checkpoint's `config.json` and enforced again by the weight shapes and
the warm-up output. A wrong checkpoint would otherwise index vectors no query can
match.

## Startup, warm-up and readiness

1. The HTTP listener starts: `/healthz` answers 200 from here on, `/readyz` 503.
2. On a blocking thread (so the probes keep answering): load the model, verify
   pinned model digests and the GPU environment, then run one synthetic image
   and one text inference. On CUDA the first inference JIT-compiles the kernels,
   about 9 s with an empty cache and 0.3 s with a warm one.
3. `/readyz` turns 200 with the capability manifest (`inference_device`,
   `inference_dtype`, `warmup_ms`, ...). Only then does the worker claim
   indexing jobs and answer text-embedding requests.

Any failure in step 2 exits the process with a non-zero status.

## CUDA JIT cache

The CUDA driver caches compiled kernels in `CUDA_CACHE_PATH` (default
`$HOME/.nv/ComputeCache`; the CUDA image sets
`/var/cache/serviceradar-media-worker/cuda`). The cache is about 350 MB for this
model. Mount a writable volume there; with a read-only root filesystem and no
volume, the worker logs `CUDA JIT cache is not writable` and pays the compile on
every start, but it still starts. `CUDA_CACHE_DISABLE=1` turns caching off.

## Preprocessing

Each batch's frames are resized and normalised in parallel on up to
`available cores / SERVICERADAR_MEDIA_WORKER_INDEX_CONCURRENCY` threads, so the
concurrent index jobs together stay within the cores. The output is identical to
the single-threaded path.

## Tests and building

`src/keyframe_decoder_tests.rs` encodes programmatic patterns with `rusty_h264-encoder` at
test time and decodes them through the real container parser.
`testdata/high_cabac_8x8_cropped_full_range_idr.h264` is the one stored bitstream: an x264
encode of a synthetic pattern documented in that test file, checked bit-exact against
FFmpeg's decode. Worker tests that need exact pixels use the generator's `SRIDR1` raster
keyframes with the test-only `SyntheticRasterKeyframeDecoder`, injected through
`VisualIndexProcessor::with_keyframe_decoder`.

```bash
# CPU (what Bazel builds and tests)
bazel test --config=remote //rust/media-worker:all
cargo test -p serviceradar-media-worker
```

The `cuda` feature is off by default. `cargo check --features cuda` needs the
CUDA toolkit: candle's kernel build runs `nvcc`, so it cannot even type-check on
a host without one. The CUDA-specific code is a `cfg(feature = "cuda")` block that
calls only candle APIs present in both configurations. Build the CUDA binary with
`scripts/build-media-worker-cuda.sh` inside the pinned CUDA devel image (see the
CUDA image doc).
