# Multi-arch OCI images — feasibility and transition plan

**Superseded on Tier 1. Kept for the record; corrections marked inline.**

| | |
|---|---|
| Date | 2026-08-14 |
| Basis | `feat/hermetic-llvm` @ `3e3b8d1340` |
| Goal | linux/amd64 + linux/arm64 manifests for the publishable image set |
| Status | **14 of 16 in-scope images verified multi-arch.** See `../../changes/add-multiarch-oci-images` |

---

## Working rules that came out of Tier 1

- **Eligibility is a property of every layer an image packages**, not of its service binary.
  Cross-compilation of first-party code was never the constraint — cgo is off repo-wide, so
  every Go binary was already static. What pinned these images to amd64 was the base image and
  the rootfs layers around the binary.
- **A manifest-shape check is not a verification.** An index advertising two platforms while
  both entries hold amd64 binaries passes `docker manifest inspect` and any "does it have two
  entries" assertion. `//docker/images:multiarch_index_test` asserts the ELF machine type of the
  packaged binaries instead.
- **A base-less (scratch) image must select its `architecture`.** rules_oci requires the
  attribute literally when there is no base to inherit it from, and the `oci_image_index`
  transition does not populate it.

## Current state — what is multi-arch now

Fourteen of sixteen in-scope. Every row marked multi-arch was verified by reading the ELF machine type of
the binaries in each advertised platform entry, enforced on every build by
`//docker/images:multiarch_index_test`. Three were additionally executed on an arm64 host.

| # | Image | Multi-arch | Base image | Payload | Verified |
|---|---|---|---|---|---|
| 1 | log_collector | **yes** | ubuntu noble 24.04 (select) | rust | ELF |
| 2 | trapd | **yes** | ubuntu noble 24.04 (select) | rust | ELF |
| 3 | flow_collector | **yes** | ubuntu noble 24.04 (select) | rust | ELF |
| 4 | bmp_collector (arancini) | **yes** | ubuntu noble 24.04 (select) | rust | ELF |
| 5 | rperf_client | **yes** | ubuntu noble 24.04 (select) | rust | ELF |
| 6 | faker | **yes** | alpine 3.20 (select) | go | ELF |
| 7 | agent | **yes** | alpine 3.20 (select) | go + rust (static-musl netprobe) | ELF + **ran on arm64** |
| 8 | datasvc | **yes** | alpine 3.20 (select) | go | ELF |
| 9 | config_updater | **yes** | alpine 3.20 (select) | go | ELF |
| 10 | tools | **yes** | alpine 3.24 (select) | go + 24 aarch64 APKs | ELF + **ran on arm64** |
| 11 | trivy_sidecar | **yes** | none — scratch | go | ELF + **ran on arm64** |
| 12 | k8s_inventory | **yes** | none — scratch | go | ELF |
| 13 | cert_generator | **yes** | alpine 3.24 (select) | shell + 3 APKs | ELF |
| 14 | core_elx | no | ubuntu noble 24.04 (**pinned amd64**) | elixir release | — |
| 15 | agent_gateway | **yes** | ubuntu noble 24.04 (select) | elixir release (arm64 ERTS) + 2 debs (select) | ELF |
| 16 | web_ng | no | ubuntu noble 24.04 (**pinned amd64**) | elixir release | — |

"(select)" means the base resolves through `_platform_select` on the target platform;
"**pinned amd64**" means the base label names the amd64 repository directly. Note that
`ubuntu_noble` and `alpine_3_24` both already have arm64 variants declared and exported in
`../../../MODULE.bazel` — for rows 13-16 the base is pinned by the call site, not unavailable.

`cnpg` and `cnpg_analytics` are out of scope by decision, not by blocker: the database runs on
amd64 nodes and multi-arch is per-image, so they are excluded from the accounting above. Fourteen
of sixteen in-scope images are multi-arch.

### The two that remain

**Blocker A is solved.** OTP is no longer built from source for the host: it is a prebuilt pinned
per architecture, and an Elixir release now embeds an arm64 ERTS through `include_erts` given a
path into a second OTP root -- which redirects the OTP application tree with it, so kernel,
stdlib, crypto and ssl and their NIFs all come from the arm64 tree. `agent_gateway` proves the
whole path end to end.

A second blocker, not anticipated by this note, sat in front of it: the `:boundary` compiler
walks every module of every checked dependency and calls `__info__(:attributes)`, forcing each to
load and firing Rustler's `@on_load`. Cross-compiling means dlopen()ing an aarch64 `.so` on the
amd64 builder, which glibc reports as ENOENT -- it sets that errno by hand on an `e_machine`
mismatch -- so the compile died naming neither NIFs nor architecture. Guarding `:boundary` to
dev/test removes it from every release build.

| Image | What is left | Fixable here |
|---|---|---|
| web_ng | `adbc` drives CMake and derives its triple from the BUILD VM, so it ignores `CC`; `mdex_native` | yes, with a CMake toolchain file |
| core_elx | ten `*_linux_x86` Membrane archives with no arm64 upstream; `ex_dtls`/`ex_libsrt` pinned to the executor's gcc by `_SYSTEM_CC_APPS` | **no** |

**Blocker B stands unchanged**, and it is the one that decides the ceiling. `core_elx` cannot be
made multi-arch from inside this repository; it needs arm64 builds from
`membraneframework-precompiled`. The honest target is therefore 15 of 16, with `core_elx` a
declared holdout on the same footing as the CNPG decision.

Runtime evidence, on an Apple Silicon host with no `--platform` flag so Docker selected the entry
itself: `tools` reports `uname -m` = `aarch64` with bash identifying as
`aarch64-alpine-linux-musl` and `psql`/`nats`/`serviceradar-cli` all running; `agent` executes the
static-musl netprobe (`netprobe 0.2.28`) with no `/lib64/ld-linux-x86-64.so.2` present;
`trivy_sidecar`, on scratch with no libc and no shell, reaches its own config validation.

Implementation detail behind the table:

The keystone was not a base image at all: the agent packaged an **untransitioned, therefore
glibc-dynamic, netprobe**, which is the only reason the image carried the sgerrand
`alpine-pkg-glibc` APK — an x86_64-only artifact with no aarch64 build in any release. Static
musl netprobe already existed for both architectures with a CI linkage assertion; the image
simply was not using it. Until that was swapped, an arm64 agent was impossible regardless of
how the base was selected.

Second surprise: the `alpine_netutils` bundle was **dead weight on four of the five images that
carried it**. Nothing in `agent`, `trivy_sidecar`, `k8s_inventory`, `datasvc` or
`config_updater` invokes `ping`, `nmap`, `nc` or `telnet` — the set came from `Dockerfile.agent`
and was flattened onto every service by the macro. Two of its binaries could not execute in any
of those images anyway (`nmap` missing four shared-library deps, `telnet` missing
`libncursesw`). Deleting the bundle was less work than twinning it for arm64.

Upstream availability was never the obstacle it was feared to be: **all 24 pinned Alpine APKs
exist for aarch64 at byte-identical version-revision strings**, and the already-pinned
`alpine_3_24` digest was already a multi-arch index containing an arm64/v8 child, so enabling it
needed two lines and no re-pin.

---

## Original plan, as written (historical)

### Where we already are

Better than expected. Six of the eighteen publishable images already publish a multi-arch index,
and the mechanism is the right one: `oci_image_index` transitions a single platform-aware image
target across `//build/platforms:linux_x86_64` and `linux_aarch64`. There is no separate arm64
build graph to maintain.

**The hermetic-LLVM migration did not break this.** It deleted the hand-rolled
`aarch64_linux_gnu_cc_toolchain` that hardcoded `/usr/bin/aarch64-linux-gnu-*`, and the arm64
indexes still build — cross-compilation now runs through the hermetic toolchain, where libc is a
target-platform property.

That is the load-bearing fact for this plan: **arm64 cross-compilation works today for Rust and
Go.** It held up. It was just not sufficient on its own.

### The image set, as classified at the time

| Image | Multi-arch | Contents | Assessment then | Outcome |
|---|---|---|---|---|
| log_collector | **yes** | rust | shipping | unchanged |
| trapd | **yes** | rust | shipping | unchanged |
| flow_collector | **yes** | rust | shipping | unchanged |
| bmp_collector (arancini) | **yes** | rust | shipping | unchanged |
| rperf_client | **yes** | rust | shipping | unchanged |
| faker | **yes** | go | shipping | unchanged |
| trivy_sidecar | no | go | trivial | now scratch |
| k8s_inventory | no | go | trivial | now scratch |
| datasvc | no | go | trivial | now  amd64 base + rootfs |
| config_updater | no | go | trivial | now  amd64 base + rootfs |
| tools | no | go | trivial | now  amd64 base + 13 amd64 tars |
| agent | no | go + rust | trivial (both proven) | now  glibc netprobe, hard blocker |
| cert_generator | no | 3rd-party base | depends on base | still amd64-only |
| cnpg | no | 3rd-party base | pinned amd64 deb | still amd64-only, deliberately |
| cnpg_analytics | no | 3rd-party base | pinned amd64 deb | still amd64-only, deliberately |
| core_elx | no | elixir | hard | still amd64-only |
| agent_gateway | no | elixir | hard | still amd64-only |
| web_ng | no | elixir | hard | still amd64-only |

Six "trivial", three base-image dependent, three hard. The six trivial ones each needed real
work; the classification of the remaining six has not yet been re-checked with the same rigour.

### Tier 2 — the base-image dependents (medium)

`cnpg` and `cnpg_analytics` pin `@debian_gcc_15_base_amd64_deb`, and the build asserts a Debian
bookworm base. Each pinned `http_file` needs an arm64 sibling and a `select()` on the target
platform. Mechanical but not free: the CNPG images do real work in the image build (extension
ABI checks, `pg_config` rewriting) and those scripts may embed arch assumptions.

**Decision taken:** deferred indefinitely. The database runs on amd64 nodes and multi-arch is
per-image, so this costs nothing to leave alone.

### Tier 3 — the three Elixir images (hard; two distinct blockers)

**Blocker A: the BEAM is built from source, for the host.** `../../../MODULE.bazel` uses
`internal_erlang_from_github_release`, so OTP is compiled from source. An Elixir *release* embeds
ERTS, so an arm64 image needs an arm64 OTP and an arm64 ERTS. OTP supports cross-compilation
upstream (`--host`/`--build` plus `erl_xcomp` files), but it needs a host bootstrap compiler and
`rules_erlang` would have to wire it.

**Blocker B: the Membrane precompiled dependencies are amd64-only.** All ten pinned archives are
amd64 (`fdk-aac`, `lame`, `mad`, `opus`, `portaudio`, `sdl2`, `libvpx`, `srt`, `srtp`, `ffmpeg`).
This blocks `core_elx` specifically and is not fixable in this repo. Note this blocker is
independent of the compiler: it would exist under gcc too.

**The alternative that sidesteps Blocker A:** build the Elixir images on arm64 RBE executors
rather than cross-compiling the BEAM. Turns an unsolved cross-compilation problem into a
provisioning task, at the cost of a second executor image and a second cold cache. It does not
solve Blocker B.

### Cost note

Each new target platform is a new cache generation: the cc toolchain is part of every action key,
and arm64 actions do not share cache with amd64. **Measured:** the first twelve-index build took
155s against a partly warm cache — materially cheaper than the cold-CAS penalty this note
anticipated, because much of the arm64 graph was already warm from the hermetic migration.

### Open questions from review

- Do we need arm64 for the database images at all? → **Answered: no.**
- Is arm64 a *release* requirement or a developer-laptop (Apple Silicon) convenience? → still open.
- Is `core_elx` on arm64 actually required, given it is blocked on a third party? → still open.
