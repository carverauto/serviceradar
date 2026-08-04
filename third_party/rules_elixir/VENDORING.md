# Vendored rules_elixir

Upstream: rabbitmq's `rules_elixir` at version **1.1.0**
Wired in via `local_path_override` in the root `MODULE.bazel`.

## Why this is vendored rather than patched

Same reasoning as `//third_party/rules_erlang/VENDORING.md`: upstream is unmaintained, so the
seven local fixes below were never going to land, and `.patch` files are a worse mechanism than
source for changes you are going to own permanently.

`rules_elixir` is the smaller of the two — roughly 1,300 lines of Starlark across 16 `.bzl`
files — which makes it the natural first candidate if this is ever restructured into a
properly maintained ruleset.

## Local modifications

Each was previously a file under `//third_party/patches/rules_elixir/`. Rationale preserved
verbatim from the `MODULE.bazel` comments that accompanied them.

| File | Fix | Why |
| --- | --- | --- |
| `repositories/elixir_config.bzl` | skip system Elixir | Use the hermetic toolchain instead of probing the host. Paired with `--repo_env=RULES_ELIXIR_SKIP_SYSTEM=1` in `//.bazelrc`. |
| `private/elixir_build.bzl` | portable tar extract | Same GNU-tar assumption as rules_erlang: `--transform` does not exist in the bsdtar macOS ships. See that tree's VENDORING.md. |
| `elixir_app.bzl` | allow empty LICENSE glob | `elixir_app` hard-failed on any package without a `LICENSE` file. |
| `elixir_app.bzl`, `private/elixir_bytecode.bzl` | compile-time data | `elixir_bytecode` could not declare compile-time file inputs, so packages doing `File.read!("README.md")` or `@external_resource` failed in the sandbox. |
| `private/ex_unit_test.bzl` | ExUnit test headers | `ex_unit_test` staged its deps without their `include/` directories, so a test using `Record.extract(from_lib: ...)` died before running a case. Compilation rules stage headers; there is no reason tests should not. |
| `private/ex_unit_test.bzl` | ExUnit workspace layout | `ex_unit_test` flattened `srcs`/`data` by stripping the package prefix, which breaks any test resolving a repo-relative path off `__DIR__` — several read `addons/*/config.schema.json`. |
| `private/ex_unit_test.bzl` | stage into `TEST_TMPDIR` | `ex_unit_test` copied every `srcs`/`data` file into `TEST_UNDECLARED_OUTPUTS_DIR` and ran there. Bazel treats that directory as artifacts the test produced, so it stats and `file --mime-type`s every entry to build the manifest, then uploads them — meaning each Elixir target shipped a few thousand of its own INPUTS to the CAS per run. It also produced ~2,150 `test-setup.sh: line 331: file: command not found` lines per test on the RBE executor, which carries no `file(1)`, burying the real output in 2,197-line logs. Nothing was collected from there on purpose: the script's only write is `test.log`, which it `rm`s after the pass/fail grep. Note `rules_erlang` keeps using `TEST_UNDECLARED_OUTPUTS_DIR` and is right to — its ct logs and coverdata really are outputs. |

## Diffing against upstream

```bash
# Adjust the URL to wherever 1.1.0 is fetched from; see the archive_override history in git
# log for MODULE.bazel if the source moves.
diff -ru /tmp/rules_elixir-1.1.0 third_party/rules_elixir \
  -x VENDORING.md -x 'bazel-*' -x MODULE.bazel.lock
```

The diff should show exactly the seven changes above and nothing else.

## House rules for editing this tree

- Record every change in the table above, for the same reason as rules_erlang: the upstream
  diff is the only thing that keeps this auditable.
- `test/` and `examples/` are excluded from the main build via the root `//.bazelignore`
  rather than deleted, so this stays a faithful copy.
