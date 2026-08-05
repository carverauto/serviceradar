# Vendored rules_erlang

Upstream: <https://github.com/rabbitmq/rules_erlang> at tag **3.16.0**
Wired in via `local_path_override` in the root `MODULE.bazel`.

## Why this is vendored rather than patched

Upstream is **archived**. 3.16.0 is the last release, published roughly two years ago, and the
repository states it is no longer maintained — RabbitMQ moved back to erlang.mk. The six local
fixes below were therefore never going to land upstream, which made carrying them as `.patch`
files a permanent tax rather than a temporary bridge:

- patches apply by context, so they break silently on any tree change;
- they cannot express a design change, only a local edit.

Vendoring changes nothing about what the rules *do*. It is a maintenance-mechanism change:
the fixes are now ordinary source edits that can be read, tested and evolved.

## Local modifications

Each of these was previously a file under `//third_party/patches/rules_erlang/`. The rationale
is preserved verbatim from the `MODULE.bazel` comments that accompanied them.

| File | Fix | Why |
| --- | --- | --- |
| `repositories/erlang_config.bzl` | skip system Erlang | Use the hermetic toolchain instead of probing the host. Paired with `--repo_env=RULES_ERLANG_SKIP_SYSTEM=1` in `//.bazelrc`. |
| `bzlmod/BUILD.bazel` | add bzlmod BUILD | Upstream predates full bzlmod support; this supplies the missing package. |
| `private/erlang_build.bzl` | portable tar extract | `erlang_build` extracted the OTP tarball with GNU tar's `--transform`, which the bsdtar macOS ships does not implement. Every Elixir/Erlang target failed on macOS at `tar: Option --transform is not supported` — before compiling a line — so no one could build or iterate on `//elixir/...` locally. |
| `erlang_app.bzl` | allow empty globs | `erlang_app` globs `include/`, `priv/`, `LICENSE*` and `.appup`, any of which a given Hex package may legitimately lack. Empty globs are fatal since Bazel 7. |
| `private/util.bzl` | `erl_libs` priv dir | `erl_libs_contents` accepts a tree artifact for `ebin` but not for `priv`. A rule that compiles a whole package in one action cannot enumerate `priv` in advance, so without this it must drop `priv` entirely. See `//build:mix_app.bzl`. |
| `private/erlang_bytecode.bzl` | `include_lib` self-reference | An app that `-include_lib`s its own public header (grpcbox does) cannot resolve it, because `code:lib_dir/1` needs an `ebin` this action has not produced yet. |

## Diffing against upstream

```bash
curl -sL https://github.com/rabbitmq/rules_erlang/archive/refs/tags/3.16.0.tar.gz \
  | tar xz -C /tmp
diff -ru /tmp/rules_erlang-3.16.0 third_party/rules_erlang \
  -x VENDORING.md -x 'bazel-*'
```

That diff should show exactly the six changes above and nothing else. If it shows more,
someone edited the vendored tree without recording it here — fix that first.

## House rules for editing this tree

- Record every change in the table above. The diff against 3.16.0 is the only thing keeping
  this tree auditable, and it is worthless once undocumented edits accumulate.
- `test/` and `examples/` are excluded from the main build via the root `//.bazelignore`, not
  by deletion, so the tree stays a faithful copy.
- This is Phase 0 of a deliberate plan: vendor now, restructure into a modern ruleset later,
  and only then consider publishing. Do not start renaming files or reshaping the public API
  here without that decision being made — an unrecorded reshuffle destroys the upstream diff.
