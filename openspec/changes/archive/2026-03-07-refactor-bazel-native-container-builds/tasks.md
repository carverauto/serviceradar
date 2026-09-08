## 1. Define the new image build foundation
- [x] 1.1 Add the Bazel modules and repository setup needed for declarative base-image definitions.
- [x] 1.2 Create shared container macros for binary-backed images, release-tar-backed images, and multi-arch image indexes.
- [x] 1.3 Define a small set of reusable runtime base profiles for generic service classes (minimal runtime, network/tools runtime, release runtime).
- [x] 1.4 Ensure Elixir release rules follow the proven ordering: `mix compile`, then asset deployment, then `mix release`.

## 2. Migrate generic service images off ad hoc rootfs assembly
- [x] 2.1 Remove wrapper-style image build targets where Bazel already owns the release or binary artifact.
- [x] 2.2 Migrate Go service images that currently rely on repeated `pkg_tar` plus `oci_image` blocks to the shared macros.
- [x] 2.3 Migrate Rust service images that follow the same pattern to the shared macros.
- [x] 2.4 Migrate Elixir release images to the shared release-image macro while preserving runtime env, entrypoints, and embedded build metadata.

## 3. Separate generic image flows from exceptional builds
- [x] 3.1 Move generic image definitions out of the monolithic `docker/images/BUILD.bazel` layout into clearer macro-driven declarations.
- [x] 3.2 Isolate the CNPG image build path and document why it remains custom for now.
- [x] 3.3 Remove now-unused per-package extraction rules and per-service rootfs tar rules from generic image flows.

## 4. Make remote execution and CI behavior correct
- [x] 4.1 Ensure OCI base image references are fully qualified (`docker.io/...`, `ghcr.io/...`, etc.).
- [x] 4.2 Add or correct Linux RBE platform definitions so OCI actions do not resolve host-specific tools.
- [x] 4.3 Register the explicit CC toolchain targets needed for remote OCI and release builds.
- [x] 4.4 Remove fake Bazel helper-wrapper targets from CI paths and invoke helper scripts directly where appropriate.

## 5. Preserve publishing and deployment behavior
- [x] 5.1 Update push targets so migrated images continue to publish `latest`, `sha-<commit>`, and `v<VERSION>` tags.
- [x] 5.2 Add multi-arch publishing for eligible images without changing repository names or deployment references.
  Current status: shared multi-arch index macros are in place; `faker`, `log_collector`, `trapd`, `flow_collector`, `bmp_collector`, `rperf_client`, and `zen` are wired to multi-arch indexes, and their Bazel multi-arch targets build successfully. `log_collector_image_amd64_push` was run directly and published `latest`, `sha-<commit>`, and an extra `--tag` as OCI indexes on GHCR without changing repository names. The remaining stale GHCR tags were refreshed by rerunning the individual multi-arch push targets for `trapd`, `flow_collector`, `bmp_collector`, `rperf_client`, `faker`, and `zen`.
- [x] 5.3 Verify Helm and Docker Compose consumers continue to reference the same image repositories and tags.

## 6. Validate and document the migration
- [x] 6.1 Validate the release tar targets first for the migrated services.
- [x] 6.2 Validate the OCI image targets second for the migrated services.
- [x] 6.3 Validate the push targets third after the image targets are clean.
  Current status: `//docker/images:push_all` is the `make push_all` path, and that flow was reported successful. In addition, `//docker/images:log_collector_image_amd64_push`, `//docker/images:trapd_image_amd64_push`, `//docker/images:flow_collector_image_amd64_push`, `//docker/images:bmp_collector_image_amd64_push`, `//docker/images:rperf_client_image_amd64_push`, `//docker/images:faker_image_amd64_push`, and `//docker/images:zen_image_amd64_push` were run directly, and GHCR inspection confirmed that their `latest` tags publish as OCI indexes.
- [x] 6.4 Verify the published image metadata and entrypoints still match current runtime expectations.
  Current status: published amd64 `latest` configs on GHCR were inspected for `web_ng`, `core_elx`, `agent_gateway`, `agent`, `log_collector`, `flow_collector`, `bmp_collector`, `rperf_client`, `faker`, `zen`, and `tools`. Their published `Entrypoint`, `Cmd`, `WorkingDir`, and key env values match the Bazel image declarations. `./scripts/verify-ghcr-publish.sh latest` now passes end to end against GHCR.
- [x] 6.5 Update release/build documentation to describe the new container build model, the RBE/toolchain requirements, and the CNPG exception.
- [x] 6.6 Run `openspec validate refactor-bazel-native-container-builds --strict`.
