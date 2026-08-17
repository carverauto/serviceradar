# rules_elixir / rules_erlang Consolidation Specification

> What to lift out of this repository into the rulesets, what to delete, and what must still be
> built. Derived from a mechanical audit of the ServiceRadar tree on 2026-08-17: 96 findings,
> 37 of them blockers. Every claim carries a `file:line`.
>
> Audience: the maintainer of `rules_elixir` and `rules_erlang`, who also owns this repository —
> the only downstream user. Nothing needs preserving for compatibility.

## TL;DR

ServiceRadar has already written a rules_elixir. It is in the wrong place and split in two:

```
build/*.bzl                     4034 lines   de facto rules (mix, releases, tests, digests)
third_party/hex/                ~250 BUILD   de facto hex dependency model + generator + drift test
```

Meanwhile `rules_elixir` supplies a toolchain and a few rules that the repository largely bypasses.
**One layering break explains almost every finding:** Elixir work is done by shelling out to `mix`
inside a single coarse action instead of being modelled as Bazel targets over `rules_erlang`'s
existing app model.

The consolidation is therefore not "write a dependency model". It is:

1. **Promote** `//third_party/hex` — a *working*, checksummed, lockfile-driven model already proven
   against the hardest graph available (269 packages, ~60 Membrane, bundlex/unifex/elixir_make,
   Rustler).
2. **Promote** the small number of files that encode real invariants.
3. **Delete** the workaround pile, which exists only because the model was missing.
4. **Fill** three genuine gaps: an `elixir_library` worth the name, generated-source support, and
   `elixir_proto_library`.

---

## 0. Baseline: what the rulesets actually have (measured at HEAD)

### rules_erlang — `13977b3`, v3.21.0, bzlmod-only

**Complete and reusable:** the compile/test/package model — `erlang_bytecode` → `ErlangAppInfo` →
`app_file` / `ez` / `escript`, plus `ct`, `eunit`, `xref`, `dialyze`. Three ways to supply OTP,
three ways to turn a package into a repo.

**The hex resolver is dead code.** `hex_tree` / `_resolve_hex_pm` is the only path that closes over
a dependency graph, and it cannot run. Three defects:

1. `hex_tree` builds a `HexPackage` without `build_file`; `_hex_package_repo:194` reads it
   unconditionally → *value has no field*.
2. `without_requirement` (`erlang_package.bzl:164`) rebuilds the provider omitting `pkg`, which
   `_hex_package_repo:193` reads — so any package passing through the resolver becomes unfetchable.
3. `extensions.bzl:295` calls `hex_package(ctx, name, release["version"], "", "")` positionally
   against `def hex_package(_ctx, module, name, pkg, version, ...)` — every argument lands in the
   wrong slot.

Zero references outside its own definition; never exercised by any test. It is also non-hermetic by
construction: `bzlmod/hex_pm.bzl:10,21` shells out to `ctx.which("curl")` during module-extension
evaluation. **This is the decisive argument for promoting `//third_party/hex`: the ruleset's
resolver has never worked, and ServiceRadar's generator demonstrably does.**

**Same bug class as `mix_release.bzl`.** `erlang_build` / `erlang_prebuilt` fetch OTP with `curl`
inside a *build action* (`use_default_shell_env = True`, no declared network requirement), and every
consuming action re-extracts the release tar to the absolute path `/tmp/bazel/erlang/<name>`
**outside the sandbox**, guarded by `if mkdir ...; then tar; fi`. CI runs local builds only on
ubuntu/macos/windows — **there is no remote-execution job**.

**RBE is expressible but unproven.** Hermetic toolchains gate on
`exec_compatible_with = ["@erlang_config//:erlang_internal"]`, and HEAD adds a per-installation
passthrough, so one OTP per execution platform can be registered. But the `constraint_setting`
defaults to `erlang_external`, so no stock platform matches — the consumer must wrap the executor
platform. The only example (`test/BUILD.bazel`) parents an undeclared `@rbe` and is dead.

### rules_elixir — `8e13ada`, ~1100 lines, seven public entry points

**Better than expected, and correctly layered.** Elixir compiles by invoking `elixirc` **directly**
from the execroot — not via mix — one action per app (`private/elixir_bytecode.bzl`). `mix` appears
only in `mix_archive_build`. It is fully wired into rules_erlang: `elixir_app` emits `ErlangAppInfo`,
consumes `ErlangAppInfo` deps, and stages them through `erl_libs_contents`. **An Elixir app is
already interchangeable with an Erlang app downstream** — the ruleset's own `escript_archive` test
proves it.

**One blocker at the provider boundary:** `elixir_app` hardcodes `priv = []` and `hdrs = []`. Any app
with a `priv` tree loses it. That single line blocks *both* NIFs (which land in `priv/native/`) and
proto (generated output staged into the app), and it is the highest-leverage fix in either ruleset.

### `escript_archive` and protoc-gen-elixir

`escript_archive` **can** build a runnable single-file escript from a hex package today —
`//tools/xref_runner:xrefr` is the worked example. Two hard limits for `protoc-gen-elixir`:

1. **rules_erlang contains zero Elixir compilation.** `escript_archive` consumes `.beam` produced by
   `erlc` from `.erl`; protoc-gen-elixir's sources are `.ex`. The escript must therefore be built on
   the rules_elixir side, from `elixir_bytecode` output.
2. There is no attribute for the archive's entry module, so
   `{emu_args, "-escript main Elixir.Protobuf.Protoc.CLI"}` must be smuggled through the `headers`
   string list. That deserves a real attribute.

---

## 1. Inventory and triage

### 1.1 `//third_party/hex` — the largest PROMOTE

| Artifact | What it is |
|---|---|
| ~250 `<pkg>.BUILD` files | per-package build definitions for the entire graph |
| `extensions.bzl` | the module extension exposing them |
| `hex_gen.bzl`, `hex_packages.bzl`, `gen_hex_bazel.exs` | generator: `mix.lock` → repos |
| `//third_party/hex:gen`, `:gen_test` | regenerate, and a **drift test that fails when it wasn't** |

`MODULE.bazel:128-133` documents the workflow. This is exactly the dependency model rules_elixir
needs, and it already handles the cases that sink naive designs. It should become the ruleset's
model — generator included, because the generator is what keeps it honest.

Note the current split-brain: `MODULE.bazel:887-892` *also* uses `@rules_elixir//bzlmod:extensions.bzl`
for `@hex`. Two dependency models in one build is the layering break in miniature.

### 1.2 `build/*.bzl`

**These are three generations stacked**, and reading them in order shows the trajectory:

- **Gen 1** — `mix_release.bzl` + `mix_release_patches.py`: one 578s unhermetic "run mix in a
  sandbox" action with a `/cache` hostPath side channel.
- **Gen 2** — `mix_deps.bzl`, `mix_precommit.bzl`: split the coarse action so the dependency half is
  lockfile-keyed and remotely cacheable.
- **Gen 3** — `mix_app.bzl`, `elixir_release.bzl`, `phoenix_digest.bzl`: **per-package Bazel targets
  producing `ErlangAppInfo`, with release assembly reading a provider closure and performing zero
  compilation.**

> **Gen 3 is already a working Bazel-native Elixir ruleset living in a project's `build/` directory.**
> `mix_app` is the missing `mix_library` — the Mix semantics `elixir_app` cannot provide (package-root
> cwd, `mix.exs`, `Mix.Project`, `elixirc_paths`, `:compilers`, `priv`). `elixir_release` is the
> missing `mix_release` — assembly from `deps`, not from a re-fetched workspace.

The consolidation is therefore mostly **promote gen 3, delete gen 1**.

| File | Lines | Verdict | Why |
|---|---|---|---|
| `mix_app.bzl` | 1318 | **PROMOTE** as `mix_library` | gen 3; the Mix semantics `elixir_app` cannot give |
| `mix_release.bzl` | 831 | **DELETE** | gen 1; 18 blockers, one cause |
| `elixir_release.bzl` | 468 | **PROMOTE** as `mix_release` | gen 3; provider-closure assembly, zero compilation |
| `mix_release_patches.py` | 323 | **DELETE** | gen 1; every patch is a dep-modelling failure |
| `mix_deps.bzl` | 296 | **PROMOTE the insight** | gen 2; lockfile-keyed cacheable dependency unit |
| `mix_precommit.bzl` | 280 | STAYS LOCAL | lint policy |
| `elixir_tests.bzl` | 262 | **PROMOTE** | `ex_unit_test` has no sharding |
| `phoenix_digest.bzl` | 134 | **PROMOTE** | gen 3; generic to Phoenix apps |
| `integration_shards.bzl` | 106 | **PROMOTE** with the above | |
| `elixir_test_config_loader.exs` | 84 | STAYS LOCAL | |
| `hex_compile_env.bzl` | 38 | **PROMOTE — highest value per line** | see §3.1 |
| `integration_tests.bzl` | 27 | STAYS LOCAL | |

---

## 2. Specification A — dependency management

### A1. Fetching is a repository-rule concern, never an action

**Evidence.** `mix deps.get --only prod` runs inside the build action (`mix_release.bzl:663`), and
the script *deliberately* declines `HEX_OFFLINE=1` so missing packages are fetched at build time
(`:599-603`). `mix local.hex --force` (`:652`) and `mix local.rebar --force` (`:660`) download from
the internet inside the action.

**Requirement.** Packages resolve from `mix.lock` into checksummed repositories. Compilation runs
with `--no-deps-check` against those repos. **No action opens a socket.** Hex and rebar3 are pinned,
checksummed toolchain artifacts installed into a hermetic `MIX_HOME`.

**Acceptance.** A full build succeeds with the network disabled and an empty repository cache after
one warm fetch.

### A2. One cacheable action per application

**Evidence.** A single ~578s all-or-nothing action, so a mutable side channel at
`/cache/mix_bazel_$TARGET_HASH` (`mix_release.bzl:498-506`) was added to buy back incrementality,
keyed by a hand-written `CACHE_VERSION = "mix_release_v3"` (`:477-497`). `mix_deps.bzl:17-20` names
this as the anti-pattern it exists to replace.

**Requirement.** Each application compiles as its own action, keyed by Bazel on declared inputs.
No rule computes its own cache key; no rule uses a hostPath.

**Acceptance.** Touching one first-party app rebuilds only that app and its reverse deps. No rule
references a path outside `bazel-out`.

### A3. Output must be relocatable

**Evidence.** Seven absolute symlinks under `/tmp`, each preceded by `rm -rf` of the same global
path (`mix_release.bzl:634-648`), because Elixir records absolute source paths in
`_build/**/.mix/compile.*` manifests while the work dir is a fresh `mktemp -d` each run.

**Requirement.** Compiled output carries no absolute paths.

**Acceptance.** Two concurrent builds on one machine cannot interfere. *(Today they can: they
`rm -rf` and re-point each other's symlinks, and the winner's build reads the loser's tree.)*

### A4. Toolchain resolution, with exec-platform support

**Evidence.** `PATH` places `/opt/homebrew/bin` **ahead of** the toolchain (`mix_release.bzl:535`)
despite `use_default_shell_env = False` (`:783`), so a host `elixir`/`erl` shadows the hermetic one.
`bun` is probed on the host and silently falls back to a system binary (`:508-548`).

**Requirement.** Every tool is a declared input resolved through toolchain resolution. Failed
resolution fails the build; no degradation to host binaries. `elixir_config` needs
`exec_compatible_with` plumbed into the generated `toolchain()`, as rules_erlang already does —
without it `MODULE.bazel:154-176` cannot be mirrored for Elixir, and remote execution from macOS to
a Linux executor is impossible.

**Acceptance.** Removing Elixir from the host `PATH` changes nothing. A macOS host drives a Linux
RBE build.

### A5. Native code as a first-class dependency

**This already works here, and the mechanism should be promoted verbatim.** Rustler NIFs are built
**exclusively by Bazel** as `rust_shared_library` targets — cargo-via-mix is dead on the Bazel path.
Four cdylibs exist (`zen_nif`, `anomaly_disposition_nif`, `srql_nif`, `god_view_nif`), each a Cargo
workspace member with a hand-written `BUILD.bazel`. They reach the BEAM through `mix_app`'s
`native_libs` attribute (`build/mix_app.bzl:871-887`), which copies each `.so` to
`priv/native/<crate>.so` **inside the staged Mix project before `mix compile` runs**, so it is
captured into the app's declared `priv` TreeArtifact (`:1113-1116`) and flows downstream on
`ErlangAppInfo.priv`. Rustler's own compilation is disabled by injecting `skip_compilation?: true`
into the sandbox copy of `config/config.exs`.

**Requirement.** Promote `native_libs` as a first-class attribute. Note the three non-obvious
settings each NIF `BUILD.bazel` repeats verbatim — `cc_runtime_linkage = "static"`,
`rustc_env = {"RUSTLER_PRIMARY_NIF_INIT": "1"}`, and a macOS-only `-Wl,-undefined,dynamic_lookup`.
**The rule must own these by construction rather than leaving them to each call site**, because
relocation is inherent to how a NIF reaches the runtime, not an opt-in the caller must remember.

**Depends on** the `elixir_app` `priv = []` fix (§0): without it the NIF is dropped at the provider
boundary.

For `bundlex`/`unifex`/`elixir_make`/`cc_precompiler`: per-dependency source patches applied **at
fetch time** as declared inputs, a stable cross-compilation contract
(`CC/CXX/CFLAGS/CXXFLAGS/LDFLAGS` + target triple), and pinned checksummed binaries injectable by
the exact filename the third-party downloader expects — so no action depends on GitHub reachability.

### A6. Dependency resolution is generated and drift-guarded

**Requirement.** Promote `//third_party/hex`'s generator wholesale: `mix.lock` → package repos, plus
a test that fails when the checked-in output is stale.

---

## 3. Invariants that look like junk and are not

These are workarounds that encode **correctness requirements**. A clean-room rewrite will drop them
and produce a ruleset that builds perfectly and ships broken artifacts.

### 3.1 The `compile_env` boot invariant — the one most likely to be lost

`Application.compile_env/3` bakes a value into a module attribute at compile time *and records what
it saw*. At boot, `Config.Provider` compares every recorded value against the release's `sys.config`
and **refuses to start** on disagreement.

Mix satisfies this for free: one `mix compile` evaluates the root config once and every dependency
compiles under it. **Per-package sandboxed compilation breaks it structurally** — each package sees
only its own defaults, then the assembled release supplies the real config and the node will not
boot. `build/hex_compile_env.bzl` works around this with a hand-maintained list of keys appended to
every package's compile action.

**Requirement.** The dependency model must propagate root compile-time configuration into every
package compile action, as a modelled attribute rather than a hand-maintained list.

**Acceptance.** A release whose root config sets a key that a dependency reads with `compile_env`
starts successfully. *This is the failure mode with the worst shape in the whole system: everything
builds, and the node refuses to start in production.*

### 3.2 Compile order for overridden path dependencies

`connection`, `elixir_uuid` and `opentelemetry_oban` are local overrides (`override: true`) that hex
packages compile **against** — `gnat` does `use Connection`, so `:connection` must compile first or
the tree does not build.

**Requirement.** Real compile-order edges, and the ability for a local target to substitute for a
hex package by name.

### 3.3 Module conflict filtering

`private/erlang_app_filter_module_conflicts.bzl` already exists in rules_elixir. Whatever it solves
must survive the rewrite — do not assume it is incidental.

---

## 4. Bugs that must not be reproduced

1. **Silent cache-key omission.** `BOOTSTRAP_HASH` iterates `f.short_path` and reads
   `$EXECROOT/$relpath`, skipping anything absent (`mix_release.bzl:111-113`, `:478-491`). A
   `short_path` for an external-repo file starts `../`; a generated file omits
   `bazel-out/<config>/bin/`. Neither resolves, so the key silently omits inputs. Bazel's own action
   key cannot do this — which is the argument for not hand-rolling one.
2. **Concurrent-build corruption** via the absolute `/tmp` symlinks (§A3).
3. **Lockfile bypass on retry.** `bun install --frozen-lockfile` retries *without* the flag on
   failure (`mix_release.bzl:707-724`), so the shipped bundle can contain versions no lockfile
   records. A lockfile violation must be a hard error.

---

## 5. Specification B — proto

### B1. Prerequisites that are really `elixir_library` gaps

Blocking, and not proto-specific:

- **A real `elixir_library(name, srcs, deps)`**, instantiable more than once per package. Codegen
  needs two libraries in one package as a matter of course (generated `.pb.ex` plus hand-written
  wrappers).
- **`srcs` must accept a directory / TreeArtifact of generated sources**, expanded at execution time
  (`ctx.actions.args().add_all(..., expand_directories = True)`). *Called out by the audit as the
  single blocking gap for any codegen at all.*
- The Mix-driven compile path must return `ErlangAppInfo` with **both `beam` and `priv`** populated.
  Today the only mix-aware rule is a dead end in the graph: nothing can be built on top of it.

### B2. `elixir_proto_library`

- Takes `deps = [proto_library]` and reads `ProtoInfo` (`direct_sources`, `transitive_sources`,
  `transitive_proto_path`).
- Builds `protoc-gen-elixir` from the `protobuf` hex package via rules_elixir (escript, or an
  `elixir_binary` shim) and passes `--plugin=protoc-gen-elixir=$(execpath ...)`; `protoc` comes from
  `@bazel_tools//tools/proto:protoc`.
- **Emits `.pb.ex` only for the target's direct srcs**, while compiling transitive deps for
  descriptor resolution. Emitting for deps too would define the same modules twice.
- Module names default to package-derived with **no prefix**; any prefix attribute defaults to empty.
- The include root is pinnable (`strip_import_prefix`-equivalent) so emitted relative paths match.
- Produces a **file tree**, not a flat list, so it can be staged into an app's source tree.
- gRPC is a per-target toggle mapping to `--elixir_out=plugins=grpc:`, emitting both the
  `<Pkg>.<Service>.Service` behaviour and the client stub.
- It must **not** own or overwrite hand-written modules that live alongside generated output.

**One reconciliation required first:** at least one checked-in `.pb.ex` in this repo
(`flow_attribution_event.pb.ex`) is not produced by any proto. Either migrate its consumers or
delete it before the rule owns that directory.

---

## 6. Sequence

1. **Promote `//third_party/hex`** into rules_elixir, generator and drift test included. Largest win,
   lowest risk — it already works.
2. **`elixir_library` with generated-source support** (§B1). Unblocks everything downstream.
3. **Per-app compilation + compile-env propagation** (§A2, §3.1). Deletes `mix_app.bzl`,
   `hex_compile_env.bzl`, and the `/cache` side channel.
4. **Provider-based release rule** (§A1). Deletes `mix_release.bzl` and `mix_release_patches.py`.
5. **NIF and native-dep support** (§A5).
6. **`elixir_proto_library`** (§B2). Deletes the Makefile codegen targets and the checked-in `.pb.ex`.
7. **Promote test sharding and Phoenix digest** (`elixir_tests.bzl`, `integration_shards.bzl`,
   `phoenix_digest.bzl`).

Steps 1-2 are prerequisites for everything else. Step 6 is where the ServiceRadar configuration work
that prompted this resumes.

## 7. Status of this document

Complete. Two audit batches, both landed and folded in:

- **Batch 1** (96 findings, 37 blockers) — `mix_release.bzl`, the rules_elixir API surface, native
  deps, proto consumers, measured against this repository.
- **Batch 2** — the actual `bzlverse` working copies at HEAD: rules_erlang `13977b3` (v3.21.0) and
  rules_elixir `8e13ada`. §0 is written from it.

Everything here is measured, not inferred. The one deliberate omission: no acceptance test has been
*executed*: these are specifications for work not yet done. Where a §Acceptance clause is stated, it
is a test to write, not a test that passed.

### The four highest-leverage items, in order

1. **`elixir_app` hardcodes `priv = []` and `hdrs = []`** — one line, blocks both NIFs and proto.
2. **Promote `//third_party/hex`** — rules_erlang's own resolver is dead code that has never run.
3. **Promote gen 3** (`mix_app` → `mix_library`, `elixir_release` → `mix_release`) — a working
   Bazel-native ruleset already exists in `build/`.
4. **Fix the `/tmp/bazel/erlang/<name>` extraction and in-action `curl`** in rules_erlang — the same
   bug class this consolidation exists to remove from `mix_release.bzl`, sitting in the ruleset
   underneath it.
