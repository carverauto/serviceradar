# Change: Refactor Bazel-native container image builds

## Why
`//docker/images:BUILD.bazel` currently behaves like a hand-written Dockerfile interpreter inside Bazel. Generic service images are assembled through repeated `genrule` and `pkg_tar` blocks, manual APK/DEB extraction, and service-specific rootfs tar creation. That pattern is expensive to maintain, weakens Bazel's cache/reuse story, and makes multi-arch image publishing harder than it needs to be.

Issue #2999 and the discussion on #1733 point to a better direction: treat Bazel build outputs as the source of truth, copy those artifacts into thin OCI base images, and let shared image macros plus multi-arch indexes handle the rest.

## What Changes
- Add shared Bazel container macros for generic ServiceRadar service images so Go, Rust, and Elixir release artifacts can be wrapped directly into OCI images.
- Replace wrapper-style image build targets with Bazel-native `release_tar` plus `oci_image` and `oci_push` flows.
- Introduce declarative runtime base image profiles for generic services, using Bazel-managed base definitions instead of hand-extracted package tarballs in `docker/images/BUILD.bazel`.
- Make the Bazel image path remote-execution-safe by using real Linux RBE platform and toolchain wiring, fully qualified OCI image references, and direct CI script invocation where Bazel wrapper targets add no value.
- Publish multi-arch OCI indexes for eligible service images from a single canonical Bazel target while preserving existing tag semantics.
- Migrate generic service images in `//docker/images` away from bespoke per-service filesystem assembly onto the shared macros and base profiles.
- Keep the CNPG image on a dedicated path for now, but isolate and document it as an exception because it compiles and overlays database extensions rather than packaging a single runtime artifact.

## Impact
- Affected specs: `container-image-builds` (new)
- Affected code:
  - `docker/images/BUILD.bazel`
  - new `docker/images/*.bzl` image macro and base-profile files
  - `MODULE.bazel` / Bazel module deps for declarative base-image rules
  - `.bazelrc`, Linux platform defs, and toolchain registration for remote-safe OCI builds
  - `docker/images/push_targets.bzl`
  - selected service BUILD targets that feed image packaging
  - CI workflows that still invoke wrapper-style Bazel helper targets
  - release/build documentation
