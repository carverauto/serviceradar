## Context
Issue #1733 contains two different threads that should not be collapsed into one implementation:

- `apko` as a possible future base-image strategy
- Bazel-native parallel image build/push orchestration that can be improved immediately

The comment history is useful because it separates those concerns. The transferable ideas from the linked `alpha-system` examples are:

- root-level aggregate targets for publish flows
- one manifest that defines the publishable image set
- service-local Bazel image targets that package Bazel build artifacts directly
- `rules_multirun` for side-effectful push orchestration with `jobs = 0`

The `rules_apko` setup shown in the issue body is relevant later, but it is not required to fix the current orchestration gap.

## Current State Analysis
ServiceRadar's current Bazel image system is already more advanced than the issue body implies:

- `docker/images/BUILD.bazel` declares the image graph through shared macros in `docker/images/service_images.bzl` and `docker/images/release_images.bzl`, with `docker/images/cnpg_image.bzl` kept as a special-case path.
- The current graph contains 26 `oci_image` targets, 7 `oci_image_index` targets, and 18 `oci_push` targets in `//docker/images`.
- `docker/images/push_targets.bzl` already defines `//docker/images:push_all` via `rules_multirun`, and it sets `jobs = 0`, so the push orchestration is already parallel.
- The root `BUILD.bazel` does not expose image entrypoints such as `//:images` or `//:push`.
- `make build` shells out to `bazel build --config=remote $(bazel query 'kind(oci_image, //docker/images:*)')`, which means:
  - image inventory is duplicated outside Bazel
  - the build-only workflow has no stable Bazel target
  - multi-arch `oci_image_index` outputs are omitted from the aggregate build path
- `docs/GHCR_PUBLISHING.md` still describes `push_all` as sequential even though the Bazel rule is parallel.

In other words, the repo already has a good per-image build graph and a decent aggregate push target, but it lacks a canonical aggregate build target and a single source of truth shared by both flows.

## External References From Issue #1733
The linked `alpha-system` files are still useful as design references:

- Root `BUILD.bazel` shows `command(...)` plus `multirun(...)` to expose one top-level push target.
- `build/container.bzl` demonstrates a small Bazel macro that packages built artifacts into OCI images and indexes.
- Service-local `BUILD.bazel` files show the desired ownership pattern: build artifact, image target, push target in one place.
- `MODULE.bazel` demonstrates that `rules_apko` adoption is separable from the aggregate orchestration problem.

The key conclusion is that we can adopt the orchestration pattern now without committing to `apko` in the same change.

## Goals / Non-Goals
- Goals:
  - expose canonical Bazel targets for full-image build and full-image publish workflows
  - make Bazel, not Make shell expansion, the source of truth for aggregate image builds
  - ensure aggregate builds include the canonical publish artifact for each image, including multi-arch indexes
  - keep existing repositories, tags, and per-image runtime contracts unchanged
  - clearly document the current Bazel image system so follow-on work starts from an accurate baseline
- Non-Goals:
  - adopting `rules_apko` in this change
  - changing runtime bases or per-service entrypoint behavior
  - rewriting every image macro again; the March 2026 Bazel-native container refactor already established the current macro layer
  - redesigning the CNPG image build path

## Decisions
- Decision: Use Bazel-native aggregation for build workflows.
  - Build aggregation should use a Bazel target such as a `filegroup`, alias chain, or equivalent dependency-only target.
  - We should not use `multirun` for build aggregation because `bazel build` already schedules target builds in parallel.

- Decision: Keep `rules_multirun` for publish orchestration.
  - Push remains side-effectful and should continue to use one command per publish target wrapped by `multirun`.
  - The public UX should become `bazel run //:push`, backed by the existing `//docker/images:push_all` pattern.

- Decision: Define publishable image inventory once.
  - The same manifest should drive:
    - aggregate build target membership
    - aggregate push target membership
    - repository/tag metadata for `oci_push`
  - The manifest must capture the canonical publish artifact for each image, which is sometimes the leaf `oci_image` and sometimes a multi-arch `oci_image_index`.

- Decision: Root-level image aliases are part of the proposal.
  - The repo should expose `//:images` for aggregate build and `//:push` for aggregate publish.
  - `Makefile`, docs, and CI should treat those as the stable public entrypoints.

- Decision: `apko` stays deferred.
  - This proposal should call out a later follow-up for `rules_apko`, checksum handling, and base-image migration.
  - The current work should be able to land even if the runtime bases remain unchanged.

## Risks / Trade-offs
- Reusing the existing push manifest for build aggregation may expose inconsistencies in how images are currently modeled.
  - Mitigation: make the manifest explicit about build target versus push target and validate that every publishable image has both.

- Root aliases will create a new public Bazel interface that docs and CI must follow consistently.
  - Mitigation: update Makefile and docs in the same change and treat older shell-query patterns as deprecated.

- Some images publish multi-arch indexes while others publish single-arch leaf images.
  - Mitigation: the shared manifest should name the canonical build artifact for each repository instead of assuming `oci_image` everywhere.

## Migration Plan
1. Extract a single Bazel-managed image inventory from the current push target definitions.
2. Add a build aggregate target in `//docker/images` that depends on each image's canonical publish artifact.
3. Add root-level aliases for aggregate build and publish.
4. Update Makefile, CI, and docs to use the canonical targets.
5. Validate that aggregate build covers the same publishable image set as aggregate push, including current multi-arch indexes.
6. Open a separate follow-up proposal for `apko` once the orchestration layer is stable.

## Open Questions
- Should the shared manifest live in `docker/images/push_targets.bzl`, or should it move to a separate `image_inventory.bzl` that both build and push helpers import?
- Should the aggregate build target include exceptional images such as CNPG from day one, or should it initially cover only the publish set already managed by `push_all`?
- Do we want a transitional alias from `//docker/images:push_all` to `//:push` documented explicitly, or should docs switch immediately to the root target?
