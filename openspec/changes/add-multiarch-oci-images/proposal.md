# Change: Publish multi-arch OCI indexes for the Go and Rust service images

## Why

ServiceRadar publishes eighteen container images; only six carry a `linux/arm64`
entry. The remaining twelve are amd64-only, so an arm64 node cannot run an agent, a
collector sidecar, or the CLI tooling without emulation.

Six of those twelve are amd64-only for no reason other than that nobody declared the
index. They contain Go and Rust binaries whose cross-compilation is already proven by an
image shipping arm64 today, and the hermetic-LLVM migration (`2a9c1eb04b`, now on
`staging`) removed the last host dependency in that path by deleting the hand-rolled
`aarch64_linux_gnu_cc_toolchain` that hardcoded `/usr/bin/aarch64-linux-gnu-*`. Adding
them is one macro call each.

The other six are amd64-only for real reasons — third-party Debian packages and the BEAM
build — and those reasons are currently recorded nowhere. A maintainer cannot today tell
"not yet declared" apart from "blocked upstream" by reading the build files.

## What Changes

- Declare `oci_image_index` targets for six images: `agent`, `trivy_sidecar`,
  `k8s_inventory`, `datasvc`, `config_updater`, `tools`. Each transitions the existing
  platform-aware image target across `//build/platforms:linux_x86_64` and
  `linux_aarch64`; no second build graph is introduced.
- Point those six at their index target in `PUBLISHABLE_IMAGES` via `push_image`, so the
  aggregate publish path pushes the index rather than the amd64 image.
- Define multi-arch **eligibility** in the spec, so an amd64-only image is a recorded
  decision rather than an omission.
- Require **per-architecture verification** of a published index. An index that lists two
  platforms while both entries hold amd64 binaries satisfies every existing scenario in
  the spec and is the failure this change must not ship.

Not in scope, and left amd64-only with the reason recorded:

- `cnpg`, `cnpg_analytics`, `cert_generator` — pinned third-party amd64 Debian packages.
  Blocked on arm64 siblings for each pinned `http_file`, plus a `select()`; the CNPG
  images also run extension ABI checks that may carry arch assumptions.
- `core_elx`, `agent_gateway`, `web_ng` — OTP is compiled from source for the host, and an
  Elixir release embeds ERTS, so an arm64 image needs an arm64 OTP. `core_elx` is
  additionally blocked on ten amd64-only Membrane precompiled archives, which is outside
  this repository.

## Impact

- Affected specs: `container-image-builds`
- Affected code: `docker/images/BUILD.bazel`, `docker/images/image_inventory.bzl`
- Affected infra: each new target platform is a new cache generation — the cc toolchain is
  part of every action key, so arm64 actions share no cache with amd64. Expect one cold
  pass. Landing all six together pays that once instead of six times.
- No change to repositories, tag sets, or the amd64 artifacts themselves.
