---
name: serviceradar-build-test
description: Use before building, testing, linting, formatting, producing images, or validating ServiceRadar changes locally or before a PR/release.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar Build and Test Commands

## Build & Test Commands

- **Every unit test, the way CI runs them: `make test`** — an alias for
  `bazel test -c opt --config=remote //... --test_tag_filters=-integration_test,-acceptance_test`.
  `--config=remote`, not `--config=ci`: the CI profile points its caches at `/bazel-cache`, the
  node volume only the BuildBuddy executors mount, so it cannot run on a workstation.
  **Run this before opening a PR and before cutting any release.** It is the only command
  that covers the whole repo, because the Elixir unit shards exist ONLY as bazel targets
  (`//elixir/serviceradar_core:unit_tests_*`, `//elixir/web-ng:unit_tests_*`) and are
  invisible to `go test`, `cargo test` and `mix test`. Two broken Elixir suites reached a
  release tag that way.
- Per-language tests + Go coverage profiles: `make test-toolchains` (go test / cargo test /
  vitest / `mix precommit`). Useful for a fast local loop; **not** a substitute for
  `make test`, and `make check-coverage` depends on it for the `cover.*.profile` files.
- Lint: `make lint`.
- Focused Go packages: `go test ./go/pkg/...`.
- SRQL (Rust) integration tests: `cd rust/srql && cargo test`.
- Bazel images: `bazel run //docker/images:<target>_push`. A worktree without
  `.bazelrc.remote` is not on RBE — copy the gitignored rc files first (Hard Rules).
- First-party Wasm plugins: `make build_wasm_plugins`, `make push_wasm_plugins`, `make verify_wasm_plugins`. Bazel fetches the pinned TinyGo toolchain automatically; local `oras` is still required for publish/inspect workflows. `make push_all` is the container-image path; `make push_all_release` adds the Wasm publish/sign/verify path for release-style runs.

Prefer Bazel targets when modifying code that already has BUILD files. Always run gofmt/cargo fmt where applicable (Go formatting handled by `gofmt`, Rust by `cargo fmt`).
