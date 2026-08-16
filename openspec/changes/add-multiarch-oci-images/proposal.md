# Change: Publish multi-arch OCI indexes for the Go and Rust service images

## Why

ServiceRadar publishes eighteen container images; only six carried a `linux/arm64` entry.
The remaining twelve were amd64-only, so an arm64 node could not run an agent, a collector
sidecar, or the CLI tooling without emulation.

Six of those twelve contain only Go and Rust binaries, whose cross-compilation is already
proven by images shipping arm64 today, and the hermetic-LLVM migration (`2a9c1eb04b`, now on
`staging`) removed the last host dependency in that path.

**Declaring the index targets was necessary but not sufficient, and the gap was invisible.**
Adding `oci_image_index` to those six produced indexes that built cleanly, advertised two
platforms, and were wrong: the images underneath pinned an amd64 base and an amd64 rootfs, so
the "arm64" entry was our correctly cross-compiled aarch64 binaries sitting on an x86-64
Alpine userland — and both index entries were labelled `linux/amd64`. Nothing in the build
graph objected. That is the state this change fixes, and the reason it also adds a test.

## What Changes

- Declare `oci_image_index` targets for six images: `agent`, `trivy_sidecar`,
  `k8s_inventory`, `datasvc`, `config_updater`, `tools`, and point each at that index in
  `PUBLISHABLE_IMAGES` via `push_image`.
- **Package a static-musl netprobe in the agent image.** `//rust/netprobe:netprobe` was
  packaged untransitioned, making it a glibc-dynamic build, which is why the image carried
  the sgerrand `alpine-pkg-glibc` APK and a hand-made `/lib64/ld-linux-x86-64.so.2` symlink.
  That APK is x86_64-only by design with no aarch64 build in any release, so it made an arm64
  agent impossible. The image now selects between the existing
  `//rust/netprobe:netprobe_linux_{x86_64,aarch64}_musl` filegroups, which
  `//rust/netprobe:static_linkage_test` already asserts are static on both architectures.
- **Move four images off the `alpine_netutils` runtime onto the platform-aware `alpine`
  path.** `alpine_netutils_service_image_amd64` bypassed the `_platform_select` its sibling
  helpers use, hardcoding both the base and the rootfs tars. Nothing in `agent`,
  `trivy_sidecar`, `k8s_inventory`, `datasvc` or `config_updater` invokes `ping`, `nmap`,
  `nc` or `telnet`; the bundle was inherited from `Dockerfile.agent` and flattened onto every
  service by the macro. Two of its binaries could not execute in any of these images anyway
  (`nmap` is missing four shared-library dependencies, `telnet` is missing `libncursesw`), so
  dropping the bundle is less work than twinning it and removes two broken binaries.
- **Add a `scratch` runtime** for services that ship one static binary, exec nothing, and are
  probed over the network: `trivy_sidecar` and `k8s_inventory`. `oci_image` with no base
  requires literal `os`/`architecture` attributes, and the index transition does not populate
  them, so `architecture` goes through the same `_platform_select` as every base.
- **Make `tools` multi-arch**: enable the `linux/arm64/v8` variant of the already-pinned
  `alpine_3_24` digest, add aarch64 siblings for all 24 pinned Alpine APKs and for `natscli`,
  and parameterize the apk rootfs macros by architecture. `tools` is the one image where the
  netutils bundle earns its place — it is an interactive bash/psql/nats debugging shell.
- **Add `//docker/images:multiarch_index_test`**, which asserts per advertised platform that
  the packaged binaries report the matching ELF machine type.
- Define multi-arch **eligibility** in the spec in terms of every layer an image packages,
  not just the first-party binary, so an amd64-only image is a recorded decision.

Not in scope, and left amd64-only with the reason recorded:

- `cnpg`, `cnpg_analytics` — pinned third-party amd64 Debian packages. Confirmed with the
  maintainer as deliberately out of scope; the database runs on amd64 nodes.
- `cert_generator` — third-party base.
- `core_elx`, `agent_gateway`, `web_ng` — OTP is compiled from source for the host and an
  Elixir release embeds ERTS, so an arm64 image needs an arm64 OTP. `core_elx` is
  additionally blocked on ten amd64-only Membrane precompiled archives, outside this repo.

## Impact

- Affected specs: `container-image-builds`
- Affected code: `docker/images/BUILD.bazel`, `docker/images/service_images.bzl`,
  `docker/images/apk.bzl`, `docker/images/image_inventory.bzl`, `MODULE.bazel`
- Behaviour change on amd64: the four images leaving `alpine_netutils` lose `ping`, `nmap`,
  `netcat`, `telnet`, `libpcap`, `libcap2`, `libbsd`, `libmd` and `glibc`. The Alpine base
  still provides `ping` and `nc` as busybox applets. `tools` keeps its full amd64 payload
  including glibc, so the interactive debugging image is unchanged on amd64.
- Each new target platform is a new cache generation — the cc toolchain is part of every
  action key, so arm64 actions share no cache with amd64. Landing all six together pays that
  once. Measured: 155s for the first twelve-index build against a partly warm cache.
- No change to repositories or tag sets.

## Note on the superseded plan

`../../notes/archive/multiarch-oci-plan.md` classified these six as "trivial — one macro call
each". That was wrong, and this change records why: the audit behind it checked cgo and
vendored third-party binaries, which are properties of *our* artifacts, and did not check the
base image and rootfs layers, which is where every one of the six was actually pinned.
