# Multi-arch OCI images — feasibility and transition plan

**For review. Not yet agreed.**

| | |
|---|---|
| Date | 2026-08-14 |
| Basis | `feat/hermetic-llvm` @ `3e3b8d1340` |
| Goal | linux/amd64 + linux/arm64 manifests for the publishable image set |

---

## Where we already are

Better than expected. Six of the eighteen publishable images already publish a multi-arch index, and
the mechanism is the right one: `oci_image_index` transitions a single platform-aware image target
across `//build/platforms:linux_x86_64` and `linux_aarch64`. There is no separate arm64 build graph to
maintain.

**The hermetic-LLVM migration did not break this.** It deleted the hand-rolled
`aarch64_linux_gnu_cc_toolchain` that hardcoded `/usr/bin/aarch64-linux-gnu-*`, and the arm64 indexes
still build — cross-compilation now runs through the hermetic toolchain, where libc is a target-platform
property. Verified: `bazel build //docker/images:trapd_image_multiarch //docker/images:faker_image_multiarch`
is green on the migrated branch.

That is the load-bearing fact for this plan: **arm64 cross-compilation works today for Rust and Go.**

## The image set, classified

| Image | Multi-arch | Contents | Assessment |
|---|---|---|---|
| log_collector | **yes** | rust | shipping |
| trapd | **yes** | rust | shipping |
| flow_collector | **yes** | rust | shipping |
| bmp_collector (arancini) | **yes** | rust | shipping |
| rperf_client | **yes** | rust | shipping |
| faker | **yes** | go | shipping — **proves Go cross works** |
| trivy_sidecar | no | go | trivial |
| k8s_inventory | no | go | trivial |
| datasvc | no | go | trivial |
| config_updater | no | go | trivial |
| tools | no | go | trivial |
| agent | no | go + rust | trivial (both proven) |
| cert_generator | no | 3rd-party base | depends on base |
| cnpg | no | 3rd-party base | pinned amd64 deb |
| cnpg_analytics | no | 3rd-party base | pinned amd64 deb |
| core_elx | no | elixir | **hard — see below** |
| agent_gateway | no | elixir | hard |
| web_ng | no | elixir | hard |

Six trivial, three base-image dependent, three hard.

---

## Tier 1 — the six Go/Rust images (low risk)

Every language toolchain involved is already proven multi-arch by an image shipping today. The change
per image is one macro call:

```python
declare_multiarch_image_index(
    name = "datasvc_image_multiarch",
    image = ":datasvc_image_amd64",
)
```

plus a `push_image` key in `image_inventory.bzl`.

**The one thing to verify per image, not assume:** cgo. A Go binary that links C goes through the cc
toolchain, and the hermetic aarch64 path has not been exercised by anything except the Rust images and
`faker`. Check each for `cgo` before declaring it trivial — if any of the five uses cgo, it belongs in
Tier 2, not Tier 1.

Also worth confirming: `trivy_sidecar` and `tools` may embed third-party amd64 binaries rather than
building them. An image that *ships* a downloaded amd64 tool cannot be made multi-arch by transitioning
the platform.

**Deliverable:** 12 of 18 images multi-arch.

---

## Tier 2 — the three base-image dependents (medium)

`cnpg` and `cnpg_analytics` pin `@debian_gcc_15_base_amd64_deb`, and the build asserts a Debian bookworm
base. Each pinned `http_file` needs an arm64 sibling and a `select()` on the target platform.

This is mechanical but not free: the CNPG images do real work in the image build (extension ABI checks,
`pg_config` rewriting) and those scripts may embed arch assumptions. Treat as its own change with its own
verification, and confirm upstream CNPG/PostgreSQL publish arm64 for the pinned versions before starting.

**Recommendation:** decide whether you actually need arm64 CNPG. If the database runs on amd64 nodes,
this tier can be deferred indefinitely at no cost. Multi-arch is per-image, not all-or-nothing.

---

## Tier 3 — the three Elixir images (hard; two distinct blockers)

### Blocker A: the BEAM is built from source, for the host

`MODULE.bazel` uses `internal_erlang_from_github_release`, so OTP is compiled from source (this is the
428s `Compiling otp from source` action). An Elixir *release* embeds ERTS, so an arm64 image needs an
arm64 OTP and an arm64 ERTS.

OTP does support cross-compilation upstream (`--host`/`--build` plus `erl_xcomp` files), but it needs a
host bootstrap compiler and `rules_erlang` would have to wire it. This is a genuine research task, not
a configuration change.

### Blocker B: the Membrane precompiled dependencies are amd64-only

All ten pinned archives are amd64:

```
fdk-aac_linux_x86.tar.gz   lame_linux_x86.tar.gz    mad_linux_x86.tar.gz
opus_linux_x86.tar.gz      portaudio_linux_x86.tar.gz  sdl2_linux_x86.tar.gz
libvpx_linux_x86.tar.gz    srt_linux_x86.tar.gz     srtp_linux_x86.tar.gz
ffmpeg_linux64.tar.xz
```

This blocks `core_elx` specifically — the image carrying the Membrane stack — and it is not something we
can fix in this repo. Either `membraneframework-precompiled` publishes arm64 builds, or those libraries
get built from source for arm64, or `core_elx` stays amd64.

Note this blocker is independent of the compiler: it would exist under gcc too.

### The alternative that sidesteps both: native arm64 executors

Rather than cross-compiling the BEAM, build the Elixir images **on arm64 RBE executors**. BuildBuddy
supports arm64 pools. This turns an unsolved cross-compilation problem into a provisioning task, and it
is the approach most BEAM shops take.

Costs: a second executor image to build and maintain (the one we just spent a day trimming), a second
cold cache, and `exec_properties` plumbing per target. It does not solve Blocker B — the Membrane
precompiled archives are still amd64-only, so `core_elx` remains blocked either way.

**Recommendation:** `agent_gateway` and `web_ng` (no Membrane) via native arm64 executors;
`core_elx` deferred pending upstream arm64 archives.

---

## Proposed sequencing

1. **Land `feat/hermetic-llvm` first.** Everything here depends on the hermetic aarch64 path, and that
   branch is where it lives.
2. **Audit for cgo and embedded amd64 binaries** across the six Tier-1 images. One grep pass; determines
   whether Tier 1 really is six images or fewer.
3. **Tier 1** — one PR, six macro calls plus inventory entries. Verify each published manifest actually
   lists both platforms (`crane manifest` / `docker manifest inspect`), and that an arm64 binary is
   genuinely arm64 rather than a mislabelled amd64 one. A manifest that *claims* two platforms while
   both entries are amd64 is the failure mode to test for.
4. **Decide on Tier 2** — need arm64 Postgres at all? If no, close it out explicitly rather than leaving
   it open.
5. **Spike native arm64 executors** for `agent_gateway` / `web_ng`, timeboxed. Cross-compiling OTP is the
   fallback, not the first attempt.
6. **Raise arm64 archives with membraneframework-precompiled** — that is the gating dependency for
   `core_elx` and is worth asking about early, since it has a long lead time and is outside our control.

## Cost note

Each new target platform is a new cache generation: the cc toolchain is part of every action key, and
arm64 actions will not share cache with amd64. Expect a cold pass per platform per image family, on top
of the transfer cost measured during the migration (69% of build capacity spent moving bytes on a cold
CAS). Sequence Tier 1 as a single landing rather than six, to pay that once.

## Open questions for review

- Do we need arm64 for the database images at all, or is arm64 only about the agent/collector fleet?
- Is arm64 a *release* requirement or a developer-laptop (Apple Silicon) convenience? If the latter,
  native arm64 executors are less attractive than they look, since the laptop can run amd64 images under
  emulation for development.
- Is `core_elx` on arm64 actually required, given it is blocked on a third party?
