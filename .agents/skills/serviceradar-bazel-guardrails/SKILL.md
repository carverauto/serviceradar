---
name: serviceradar-bazel-guardrails
description: Use before creating a worktree, script, or ad hoc orchestration, handling generated Bazel artifacts, changing native add-ons, or adding serviceradar_core tests.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar Bazel Guardrails

- **After `git worktree add` (or any extra checkout), symlink the gitignored
  Bazel rc files before any `bazel` command.** `.bazelrc` try-imports
  `%workspace%/.bazelrc.remote` and `.bazelrc.local`. Both are gitignored:
  they hold the BuildBuddy API key and the remote cache/executor overrides.
  `git worktree add` only checks out tracked files, so a new worktree has
  neither. Without them `--config=remote` / `--config=ci` cannot authenticate:
  Bazel prints `PERMISSION_DENIED: Missing API key` and never reaches RBE
  (local crawl or abort). `bb view` still works from the primary clone — that
  is not proof the worktree is wired for remote execution. From the checkout
  that already has the files:

  ```
  ln -sfn "$PRIMARY/.bazelrc.remote" "$WT/.bazelrc.remote"
  test -e "$PRIMARY/.bazelrc.local" && ln -sfn "$PRIMARY/.bazelrc.local" "$WT/.bazelrc.local"
  test -f "$WT/.bazelrc.remote"
  ```

  Same rule for `/tmp/...` trees, `jj workspace add`, and extra clones. Never
  commit those files.

- **Never read generated Bazel output.** No `cp` out of `bazel-out`, no `bazel info
  bazel-bin` plus a path, no `bazel cquery --output=files` followed by reading the file. The
  output tree is a cache, not an interface: it can be wiped at any time, and its path encodes
  the configuration that produced it, so an artifact found under `bazel-out/rbe_platform-opt/`
  is whatever happened to be built with that platform and compilation mode — the same command
  with a different `-c` or `--config` silently reads something else, or nothing.

  This tree hides the path deliberately: `//.bazelrc` sets
  `--experimental_convenience_symlinks=clean`, so there is no `bazel-out` symlink at the
  workspace root. A copy that appears to do nothing there is that guard working. Do not route
  around it by resolving an absolute path by hand.

  Express the need as a target instead: a `filegroup` consumed as a declared input, or
  `write_source_files` from `aspect_bazel_lib` to copy an artifact back into the tree. When a
  generated file must be committed — protoc output embedded with `include_bytes!` so `cargo`
  works without Bazel, generated bindings — the pattern is a committed copy, a `diff_test`
  that says when it is stale, and a write-back target that makes it current. See
  `//config/manager_config/rust:update_embedded_instances`, which copies from runfiles. If a
  write-back target is missing, add one rather than doing the copy by hand.

- **No shell scripts. Everything is a Bazel target.** Do not add a script under
  `scripts/`, and do not extend an existing one. Build, test, provisioning, teardown,
  packaging and publishing are Bazel targets invoked with `bazel build` / `bazel test` /
  `bazel run`. A script is a build system with no dependency graph, no cache, no sandbox
  and no remote execution — every one of them is a hole in the graph that has to be
  re-run, re-debugged and re-documented by hand.

  **The only permitted exception is a hard corner case that genuinely cannot be a Bazel
  action**, and it must be justified in a comment at the top of the file. Today that means
  credential handling that must not become an action input: Docker/registry authentication
  and cosign/OpenBao signing setup, plus materializing rotating SRQL fixture credentials in
  the Bazel client's environment before database test actions start. "It was easier" is not
  a corner case.

  Corollaries:
  - Work an existing script does belongs in a target. `//rust/integration-db` already
    replaced `scripts/{reset,drop,sweep-stale-core}-test-db.sh` — those files are dead and
    should be deleted, not maintained.
  - A test needing a file gets it as a **declared input** (`data`/`srcs`), never from a
    script writing it to a runner temp dir and exporting a path. That pattern is what
    forces `no-remote-exec` and breaks RBE.
  - Ordering between targets is the caller's sequence of `bazel` invocations, not a script
    that wraps them.

Two registration gates fail **only** under `make test`/BazelCI — never under `mix test`,
`go test`, `cargo test` or a PR check — so a missing entry looks green all the way to
trunk unless the no-mistakes pipeline catches it first:

- **Adding or changing a native add-on** (`addons/<name>/` + a Go/Rust binary) must be
  registered in four places, and any change to its source, config or `BUILD.bazel`
  requires bumping `addons/<name>/addon.yaml` `version`.
- **Adding an `elixir/serviceradar_core` test file** requires a row in
  `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`. The no-mistakes
  `test-registration` gate (`.no-mistakes.yaml`) now runs this contract before push, so a
  missing row is caught there instead of only in BazelCI.

Both procedures, with their local verification commands, are in
[docs/agent-runbooks.md](docs/agent-runbooks.md).
