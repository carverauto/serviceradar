# CUDA media worker image

`serviceradar-media-worker-cuda` is the GPU build of `serviceradar-media-worker`.
It is a separate image from the CPU multi-arch `serviceradar-media-worker`
because a binary built with `--features cuda` cannot start without the host
driver's `libcuda.so.1`.

Reference for the Helm chart (`mediaWorker.image`):

```
registry.carverauto.dev/serviceradar/serviceradar-media-worker-cuda:sha-<full 40-character commit sha>
```

- Platform: `linux/arm64` only, built for compute capability 12.1 (GB10, DGX Spark).
- Tags: only `sha-<commit>`; no `latest`, no release tags. A commit is published once.
- Signed with the release key (classic `.sig` tag), like every other image.

## What the image contains

One layer on the same pinned `ubuntu:24.04` base the CPU image uses
(`ubuntu_noble` in `MODULE.bazel`):

| Path | Contents |
| --- | --- |
| `/usr/local/bin/serviceradar-media-worker` | the CUDA build of the worker (entrypoint) |
| `/usr/local/lib/serviceradar-cuda/` | cuBLAS, cuBLASLt, cuRAND, NVRTC (+ builtins), cudart from the pinned CUDA 13.0.3 devel image (`LD_LIBRARY_PATH`) |
| `/etc/ssl/certs/ca-certificates.crt` | the Mozilla CA bundle pinned as `mozilla_ca_bundle` in `MODULE.bazel` |
| `/etc/passwd`, `/etc/group` | `root` and `serviceradar` (10001), as in the Bazel images |
| `/var/cache/serviceradar-media-worker/cuda` | `CUDA_CACHE_PATH`, owned by 10001 |

It runs as `10001:10001`, exposes `8096/tcp`, and sets
`NVIDIA_DRIVER_CAPABILITIES=compute,utility`, `CUDA_CACHE_PATH` and
`CUDA_CACHE_MAXSIZE=1073741824`. It does not set `NVIDIA_VISIBLE_DEVICES`: the
device plugin decides which GPU a pod gets, and a pod without a GPU allocation
gets none.

It does not contain `libcuda.so.1` or any other driver library. The NVIDIA
container runtime injects them from the host, so the host driver must support
CUDA 13.0 (driver 580 or newer).

## Deployment requirements

- Mount the SigLIP checkpoint read-only, for example at
  `/var/lib/serviceradar-media-worker/models/siglip`, and set `MEDIA_WORKER_MODEL_DIR`
  to that directory. It must contain `config.json`, `tokenizer.json`, and
  `model.safetensors` (or `siglip.safetensors`).
- A GPU allocation (`nvidia.com/gpu`) and the NVIDIA runtime class on the node.
  The chart adds the GPU request whenever `mediaWorker.executionProvider` is not
  `cpu_explicit`.
- A writable volume at `/var/cache/serviceradar-media-worker/cuda` (or wherever
  `CUDA_CACHE_PATH` points). The chart's root filesystem is read-only and its
  `/tmp` emptyDir is limited to 256Mi, which the ~350 MB kernel cache would
  exceed. Use an emptyDir of at least 1Gi (survives container restarts) or a
  PVC (survives pod restarts). Without it the worker logs a warning and every
  start spends about 9 s compiling kernels before it reports ready.
- `/healthz` answers during the warm-up; `/readyz` stays 503 until it finishes.
  No startup probe is needed for the warm-up itself.

## How it is built and published

`.github/workflows/publish-media-worker-cuda.yml` runs only on manual dispatch.
A credential-less preflight job checks the ref before GitHub assigns the signing runner.
Bazel cannot build this
binary (RBE is amd64-only and has no CUDA toolkit).

1. **toolchain** (GitHub-hosted, no secrets) downloads the pinned Rust
   components (`scripts/build-media-worker-cuda.sh fetch-toolchain`). The CUDA
   devel image has no curl or git, and the arm64 runner job cannot install any.
2. **build** (`serviceradar-arm64-build`, no secrets, no registry or signing
   access) runs inside `docker.io/nvidia/cuda@sha256:b7ae301d...` (13.0.3 devel,
   Ubuntu 24.04) as a non-root user. `scripts/build-media-worker-cuda.sh build`
   installs the toolchain into `$HOME`, unpacks `third_party/crate_mirror` into a
   Cargo directory source (each archive checked against `Cargo.lock`, so no crate
   is fetched from crates.io), builds with
   `--release --locked --features cuda` and `CUDA_COMPUTE_CAP=121`, and collects
   every CUDA library `ldd` resolves plus the fixed list above. An unresolved
   library other than `libcuda.so.1` fails the build. It uploads the binary,
   `lib/`, `manifest.json` (binary and library sha256s, rustc/cargo/nvcc/cc
   versions, builder image) and `SHA256SUMS`, and reports the `SHA256SUMS`
   digest as a job output.
3. **publish** (`serviceradar-signing`, environment `release`) runs only on
   `refs/heads/staging` and `refs/heads/test/demo-test-<N>`, the refs the
   `github-signing-runner` OpenBao role admits. It verifies the bundle against
   the build job's digest before touching a credential, refuses a commit whose
   protected tag already exists, assembles the image with crane
   (`scripts/ci/media-worker-cuda-image.py push`) into `serviceradar-builds`,
   checks the registry copy (arm64, user 10001, top layer equals the assembled
   layer), signs it with `scripts/sign-oci-publish.sh`
   (`SERVICERADAR_NATIVE_IMAGE`, admitted only for `NATIVE_BUILD_IMAGES`),
   verifies the signature against the signing ledger, promotes that digest to
   `serviceradar`, and verifies the protected signature against the same ledger.

Dispatching from any other branch builds the bundle and stops; it is the way to
try a change on the hardware without publishing.

For a manual build, set `GITHUB_SHA` to the checkout's full commit SHA in the
arm64 devel container. Fetch the toolchain on a host with curl and mount it in
the container.

```bash
./scripts/build-media-worker-cuda.sh fetch-toolchain /path/to/toolchain   # on a host with curl
./scripts/build-media-worker-cuda.sh build /path/to/toolchain /path/to/out
```

The build targets compute capability 12.1 and requires a fresh or empty output
directory for each command.

## Not yet exercised

The runner, the build job and the publish job have not run: the
`serviceradar-arm64-build` scale set is being added in gitops. Before relying on
the first publish, check in its logs that checkout fell back to the REST API, the
toolchain installed as the non-root user, the build found a C compiler, `ldd`
listed only the expected CUDA libraries, and crane could read the base image with
the build robot. Then record the library sha256s from `manifest.json` here.
