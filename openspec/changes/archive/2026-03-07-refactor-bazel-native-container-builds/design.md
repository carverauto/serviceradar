## Context
ServiceRadar already uses Bazel to compile most binaries and Elixir releases, but the final container packaging path is still largely hand-assembled inside `docker/images/BUILD.bazel`. The file mixes three different concerns:

- generic service-image packaging
- runtime package/rootfs composition
- exceptional database image assembly for CNPG extensions

That has created a large amount of repeated boilerplate:

- repeated `pkg_tar` plus `oci_image` definitions for each service
- repeated `genrule` steps that unpack APK or DEB payloads into tarballs
- repeated per-service rootfs tar wrappers around already-built Bazel artifacts

The result works, but it is not the Bazel-native shape the issue is asking for. The example referenced in #1733 uses a much smaller pattern:

- build the binary in Bazel
- package it directly into an OCI layer
- place it on top of a declared base image
- publish an image index for multiple architectures

That is the model this proposal adopts for generic service images. The Threadr cleanup work confirmed a few implementation details we should carry over directly:

- Elixir release rules must run `mix compile` before asset deployment
- OCI base references must be fully qualified for reliable Bazel resolution
- remote OCI builds need real Linux platform and toolchain registration, not just a remote executor flag
- CI should invoke helper scripts directly when wrapping them as Bazel targets adds no build value

## Goals / Non-Goals
- Goals:
  - make generic service images artifact-first and macro-driven
  - replace manual package extraction in generic service images with declarative base-image definitions
  - enable first-class amd64 and arm64 publishing for eligible services
  - keep existing repository names and tag semantics stable
  - reduce the maintenance surface of `docker/images/BUILD.bazel`
- Non-Goals:
  - rewriting local `docker/compose/Dockerfile.*` developer images in the same change
  - changing service runtime configuration formats or entrypoint contracts
  - fully redesigning the CNPG extension build path in the first pass

## Decisions
- Decision: Introduce shared image macros for the common service cases.
  - Generic Go and Rust services should provide a Bazel binary target plus metadata.
  - Elixir services should provide a Bazel release tarball plus metadata.
  - The macro owns layer creation, entrypoint wiring, labels, ports, and optional multi-arch index creation.
  - Wrapper-style image scripts should be removed once the Bazel artifact and image target exist.

- Decision: Elixir release macros must enforce compile-before-assets ordering.
  - The release path should run `mix compile` before `mix assets.deploy`, then build the release artifact.
  - This avoids Phoenix colocated hook and asset build failures seen in Bazelized Elixir apps.

- Decision: Use declarative Bazel-managed base-image definitions for generic runtime packages.
  - Package-heavy generic images should stop composing runtime tools by unpacking APK/DEB archives via `genrule`.
  - Instead, a small set of base profiles should define their package contents once and be reused across services.
  - A direct binary-on-base pattern remains the default for services that only need a thin runtime image.
  - Base image pulls should use fully qualified registry references so remote builds do not depend on short-name resolution behavior.

- Decision: Treat multi-arch as a first-class output of the shared macros.
  - Eligible generic service images should build amd64 and arm64 variants and publish a single OCI index target.
  - Tagging remains unchanged so Helm, Compose, and release workflows do not need repository-level migration.

- Decision: Make Linux remote execution an explicit design constraint.
  - OCI and release targets must resolve Linux tools when run on BuildBuddy or other RBE backends.
  - Platform definitions and explicit CC toolchain registration belong in the solution, not as after-the-fact fixes.
  - Validation should run in the order: release tar, then OCI image, then push target.

- Decision: Keep CNPG as an explicit exception during the first phase.
  - CNPG is not a simple "copy one built artifact into a base image" case.
  - It overlays compiled extensions and OS packages into a database image and therefore needs a dedicated build path.
  - The important change is to isolate that exception instead of forcing all service images to inherit its complexity.

## Risks / Trade-offs
- Introducing new base-image tooling will add one more Bazel dependency surface.
  - Mitigation: keep the number of base profiles small and migrate incrementally.

- Some services may have hidden runtime dependencies currently satisfied by ad hoc package layering.
  - Mitigation: migrate by service class, validate runtime entrypoints, and keep profiles explicit.

- Full multi-arch support may expose architecture-specific binary or runtime assumptions.
  - Mitigation: start with services whose Bazel targets already build cleanly on both platforms, then expand.
  - Current repo status: `faker`, `log_collector`, `trapd`, `flow_collector`, `bmp_collector`, `rperf_client`, and `zen` now build as multi-arch OCI indexes.
  - The working arm64 path uses amd64 BuildBuddy executors with an explicit `aarch64-linux-gnu` cross C/C++ toolchain, corrected arm64 OpenSSL/pkg-config environment, and an updated RBE executor image that carries the cross toolchain and arm64 development headers.

- Leaving CNPG custom means the repo will still have two image build styles for some time.
  - Mitigation: document that split clearly and constrain the exception to CNPG-like images only.

## Migration Plan
1. Add shared macros, release ordering fixes, and declarative base profiles without changing published repositories.
2. Add the Linux RBE platform and toolchain wiring needed for remote-safe release and OCI actions.
3. Migrate the generic Go and Rust service images that are currently straightforward binary wrappers.
4. Migrate Elixir release images onto the release-image macro and preserve build metadata generation.
5. Update push targets to publish multi-arch indexes for the migrated images.
6. Isolate CNPG-specific logic so generic image code no longer depends on extension-build helpers.

## Open Questions
- Which remaining generic service images should move to multi-arch next, and which should stay amd64-only until their runtime assumptions are simplified?
- Should the repo keep Debian slim as the default Rust runtime profile, or further reduce those images once shell-based entrypoints are removed?
- Which runtime packages belong in shared base profiles versus per-service layers?
- Should the initial migration introduce one common macro with mode flags, or separate macros for binary images and release-tar images?
