## 1. Analysis
- [x] 1.1 Record the current Bazel image inventory, macro structure, and aggregate push behavior in the implementation notes.
- [x] 1.2 Confirm the canonical public targets and the manifest shape that will drive both build and push flows.
- [x] 1.3 Capture `rules_apko` as a deferred follow-up rather than part of this change.

## 2. Bazel Orchestration
- [x] 2.1 Define a single Bazel-managed publishable image inventory with canonical build and push labels.
- [x] 2.2 Add an aggregate image build target that includes single-arch images and current multi-arch image indexes.
- [x] 2.3 Add root-level aliases or wrappers for `bazel build //:images` and `bazel run //:push`.

## 3. Tooling And Docs
- [x] 3.1 Update `Makefile` to use the canonical Bazel aggregate targets instead of shell-expanded `bazel query` commands.
- [x] 3.2 Update GHCR/release/build documentation and CI references to the canonical targets.
- [x] 3.3 Correct the documentation that currently describes `push_all` as sequential.

## 4. Validation
- [x] 4.1 Run `openspec validate add-parallel-bazel-image-build-orchestration --strict`.
- [x] 4.2 Verify the aggregate build target covers every publishable image, including current multi-arch index outputs.
