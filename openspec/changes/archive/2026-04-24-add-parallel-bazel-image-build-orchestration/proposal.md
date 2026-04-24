# Change: Add parallel Bazel image build orchestration

## Why
Issue #1733 started as an `apko` investigation, but the comment thread points to a more immediate and lower-risk first step: make the existing Bazel image graph easier to build and publish in parallel before changing base-image tooling.

ServiceRadar already has Bazel-native image macros and a parallel `//docker/images:push_all` target, but the build-only path is still shell-driven. `make build` expands a `bazel query 'kind(oci_image, //docker/images:*)'`, which is not a canonical Bazel target, duplicates image inventory outside Bazel, and omits multi-arch `oci_image_index` targets that are part of the publish flow.

## What Changes
- Add canonical Bazel aggregate targets for image build and publish workflows.
- Define the publishable image inventory once and use it for both build and push orchestration.
- Add root-level aliases so maintainers can use `bazel build //:images` and `bazel run //:push`.
- Update Makefile, CI, and docs to use the canonical targets and document current parallel push behavior correctly.
- Explicitly defer `rules_apko` adoption and base-image migration to a follow-on proposal.

## Impact
- Affected specs: `container-image-builds`
- Affected code:
  - `BUILD.bazel`
  - `docker/images/BUILD.bazel`
  - `docker/images/push_targets.bzl`
  - new or refactored Bazel image inventory helpers under `docker/images/`
  - `Makefile`
  - GHCR/release/build documentation and CI references
