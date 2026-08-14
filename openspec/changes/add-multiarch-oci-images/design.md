## Context

Six of eighteen publishable images already publish a multi-arch index, and the mechanism
is already the right one: `declare_multiarch_image_index` wraps `oci_image_index`, which
transitions a single platform-aware image target across `//build/platforms:linux_x86_64`
and `linux_aarch64`. There is no separate arm64 build graph to maintain, and there never
was one to remove.

The hermetic-LLVM migration is what makes the rest tractable. It deleted the hand-rolled
`aarch64_linux_gnu_cc_toolchain` that hardcoded `/usr/bin/aarch64-linux-gnu-*`, and the
existing arm64 indexes still build — cross-compilation now runs through the hermetic
toolchain, where libc is a target-platform property rather than a host installation.
Verified on the migrated branch before it landed:
`bazel build //docker/images:trapd_image_multiarch //docker/images:faker_image_multiarch`.

That is the load-bearing fact for this change: arm64 cross-compilation works today for
both Rust and Go, and `faker` proves the Go half specifically.

Full survey in `openspec/notes/multiarch-oci-plan.md`; the migration it depends on is
written up in `openspec/notes/hermetic-llvm-rust-migration.md`.

## Goals / Non-Goals

**Goals**

- Twelve of eighteen images publishing `linux/amd64` + `linux/arm64`.
- An eligibility rule in the spec, so the remaining six are a recorded decision.
- A verification step that can actually fail — see the first decision below.

**Non-Goals**

- arm64 for the CNPG images. Deferred deliberately, not overlooked: if the database runs
  on amd64 nodes this can be deferred indefinitely at no cost. Multi-arch is per-image.
- arm64 for the Elixir images. Genuine research, tracked separately.
- Native arm64 RBE executors. Considered below and rejected for this change.

## Decisions

**Verification asserts machine type, not manifest shape.** The plan's step 3 named the
failure mode precisely: an index that *claims* two platforms while both entries hold amd64
binaries. Such an index passes `docker manifest inspect`, passes every existing scenario in
the spec, and fails on an arm64 node. So the check extracts the binary and reads its ELF
machine type. Task 4.3 runs the same check against an already-shipping index as a control —
a verification step that has never been observed to fail is not yet known to work.

**Six images land together, not one at a time.** Each target platform is a new cache
generation, because the cc toolchain is part of every action key; arm64 actions share no
cache with amd64. The hermetic migration measured what a cold CAS costs here — 69% of build
capacity spent moving bytes, and a 50-minute build that ran in 4.1s warm. Landing six
separate changes pays that entry cost six times for one arm64 toolchain.

**Eligibility is stated as a payload property.** "Every artifact comes from a Bazel
toolchain that resolves for the target platform" is checkable by reading the image
definition. "This image is eligible" is a label someone has to maintain. The distinction
matters for the CNPG images, where the blocker is not the compiler at all but a pinned
`http_file`.

**Alternatives considered for the Elixir images:** cross-compiling OTP (`--host`/`--build`
plus `erl_xcomp` files) needs a host bootstrap compiler and `rules_erlang` plumbing — a
research task, not a configuration change. Native arm64 RBE executors turn that into a
provisioning task, which is what most BEAM shops do, at the cost of a second executor image
and a second cold cache. Neither unblocks `core_elx`, whose Membrane archives are amd64-only
regardless of compiler or executor. Both belong in their own change.

## Risks / Trade-offs

- **A mislabelled arm64 entry ships.** This is the risk the change is organised around;
  mitigated by task 4.2 and the control in 4.3.
- **cgo is re-enabled for a Go service later**, silently making an eligible image
  ineligible. The repo-wide `pure` setting makes this a visible per-target override rather
  than a default, but nothing enforces it. Accepted for now.
- **Cold-cache cost lands on whoever builds next.** Bounded, one-time, and measured.
- **The six untouched images keep publishing amd64-only.** Intended; the spec now says so
  explicitly rather than leaving it as an unexplained gap.

## Migration Plan

Additive. The `push_image` key redirects the aggregate publish path to the index target;
repositories and tag sets are unchanged, and the amd64 artifact inside each index is the
same artifact published today. Rollback is removing the `push_image` key, which returns
that image to pushing its amd64 target — no registry-side cleanup required, since the
previously published tags are untouched.

## Open Questions

- Is arm64 a release requirement, or an Apple Silicon developer convenience? If the latter,
  native arm64 executors are less attractive than they look, since a laptop can run amd64
  images under emulation.
- Do the database images need arm64 at all? Worth closing out explicitly rather than
  leaving open.
- Should arm64 archives be raised with `membraneframework-precompiled`? It gates `core_elx`,
  is outside our control, and has a long lead time — so it is worth asking early even though
  it is out of scope here.
