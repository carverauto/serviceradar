# Elixir under Bazel

How the Elixir tree is built and tested by Bazel, and what you have to do to add a package,
a dependency, a test tier, or a NIF.

This document covers local mechanics only. CI wiring lives in `.forgejo/workflows/`.

## Contents

- [The short version](#the-short-version)
- [Layout](#layout)
- [Toolchain](#toolchain)
- [How a project is compiled: mix_app](#how-a-project-is-compiled-mix_app)
- [How dependencies work](#how-dependencies-work)
- [How tests work](#how-tests-work)
- [The database-backed tier](#the-database-backed-tier)
- [Native NIFs](#native-nifs)
- [Step by step: add a first-party Elixir app](#step-by-step-add-a-first-party-elixir-app)
- [Step by step: add a Hex dependency](#step-by-step-add-a-hex-dependency)
- [Step by step: add a test file](#step-by-step-add-a-test-file)
- [Step by step: add a database-backed test](#step-by-step-add-a-database-backed-test)
- [Step by step: add a Rustler NIF](#step-by-step-add-a-rustler-nif)
- [Running things locally](#running-things-locally)
- [Failure modes and what they actually mean](#failure-modes-and-what-they-actually-mean)

## The short version

Every Elixir project in this repo is compiled by **Mix**, inside a **single hermetic Bazel
action**, with **dependencies supplied by Bazel** rather than fetched by `mix deps.get`. The
rule that does this is `mix_app` (`//build:mix_app.bzl`), and it produces `ErlangAppInfo`,
which is what every downstream Bazel rule (`ex_unit_test`, another `mix_app`, `mix_release`)
consumes.

Nothing uses the host's `erl`, `elixir`, or `mix`. Nothing reaches the network during a
build. `HEX_OFFLINE=1` is set inside the action so a package that tries fails loudly instead
of succeeding on your laptop and failing on a network-isolated remote executor.

Three commands cover most work:

```sh
bazel build //elixir/...              # compile every app (integration targets are `manual`)
bazel test  //elixir/...              # run every database-free test tier
bazel build //elixir/serviceradar_core:erlang_app   # just one app
```

## Layout

| Path | Bazel targets | Notes |
| --- | --- | --- |
| `elixir/connection` | `erlang_app` | Vendored `Connection`; shadows the Hex package |
| `elixir/elixir_uuid` | `erlang_app` | Vendored; shadows the Hex package |
| `elixir/datasvc` | `erlang_app` | gRPC data service |
| `elixir/serviceradar_srql` | `erlang_app` | Wraps the `srql_nif` Rust NIF |
| `elixir/serviceradar_core` | `erlang_app`, `unit_tests`, `integration_tests_s0..s7`, `migrate_template`, `migrations` | The big one; ~2700 unit + ~1570 integration tests |
| `elixir/serviceradar_agent_gateway` | `erlang_app`, `unit_tests`, `release_tar` | |
| `elixir/web-ng` | `erlang_app`, `unit_tests`, `deps_cache`, `precommit`, `release_tar` | Phoenix; see `elixir/web-ng/AGENTS.md` |
| `elixir/serviceradar_core_elx` | `release_tar` | Release wrapper, no `mix_app` |
| `elixir/vendor/opentelemetry_oban` | `erlang_app` | Vendored fork |
| `elixir/vendor/boombox` | `srcs` only | Source filegroup for releases |
| `elixir/palisade` | none | No BUILD file, not wired into Bazel |

Shared Starlark lives in `//build`:

| File | Purpose |
| --- | --- |
| `mix_app.bzl` | Compile a Mix project in one action. The core rule. |
| `elixir_tests.bzl` | `ex_unit_tests` macro: generate grouped ExUnit targets |
| `elixir_test_config_loader.exs` | Applies `config/config.exs` the way `mix test` does |
| `integration_shards.bzl` | Shard count/names, shared with `//rust/integration-db` |
| `mix_deps.bzl`, `mix_precommit.bzl`, `mix_release.bzl` | web-ng dep cache, quality gate, release tarballs |

## Toolchain

Hermetic, pinned in `MODULE.bazel`:

```python
erlang_config_ext.internal_erlang_from_github_release(name = "otp_28_1", version = "28.1", ...)
elixir_config_ext.internal_elixir_from_github_release(name = "elixir_1_19_4", version = "1.19.4", ...)
register_toolchains(
    "@erlang_config//otp_28_1:toolchain_major",
    "@erlang_config//otp_28_1:toolchain_major_minor",
    "@elixir_config//elixir_1_19_4:toolchain",
)
```

`toolchain_resolution_overrides` forces the hermetic Erlang toolchains, so the upstream
`rules_erlang` "external" toolchains that would use host OTP never win. **Your local
`asdf`/`brew` Erlang is irrelevant to a Bazel build**, and changing it will not change a
result.

`rules_erlang` (3.16.0) and `rules_elixir` (1.1.0) are both patched via
`single_version_override`. The patches are in `//third_party/patches/`, each with a comment
explaining what broke without it. The ones you are most likely to feel:

- `portable_tar_extract.patch` -- upstream extracts the OTP tarball with GNU `tar
  --transform`, which macOS `bsdtar` does not implement. Without it nothing under
  `//elixir/...` builds on a Mac at all.
- `ex_unit_test_workspace_layout.patch` -- upstream flattens `srcs`/`data` by stripping the
  package prefix. Several tests resolve repo-relative paths off `__DIR__`; this keeps the
  workspace layout intact inside the test sandbox.
- `compile_time_data.patch` -- lets `elixir_bytecode` declare compile-time file inputs, so a
  package doing `File.read!("README.md")` or `@external_resource` works in a sandbox.
- `erl_libs_priv_dir.patch` -- `erl_libs_contents` accepted a tree artifact for `ebin` but
  not for `priv`. A rule that compiles a whole package in one action cannot enumerate `priv`
  in advance, so `mix_app` could not ship `priv` at all without this.

Bumping either ruleset means re-checking every patch applies.

## How a project is compiled: mix_app

`elixir_app` (upstream) invokes `elixirc` directly from the execroot. That is fine for a plain
library and wrong for a Mix project, because Mix guarantees things `elixirc` does not:

- the working directory is the package root, so compile-time `File.read!` and
  `@external_resource` resolve;
- `mix.exs` runs, so `elixirc_paths`, `:compilers` and per-package compiler options take
  effect;
- `Mix.Project` is available. Ash calls it at compile time and dies with
  `GenServer.call(Mix.ProjectStack, ...)` without it.

So `mix_app` runs `mix compile --no-deps-check` inside one action:

1. Sources are copied into a sandbox invocation directory **under their own package path**,
   mirroring the workspace layout. This is what makes
   `Path.expand("../../../../../addons/x/config.schema.json", __DIR__)` resolve the same way
   it does under plain `mix`.
2. Bazel-built deps are staged into an `ERL_LIBS` tree and symlinked into
   `_build/$MIX_ENV/lib`, which satisfies `--no-deps-check` with no network.
3. `HOME` is set inside the sandbox, so `~/.mix` and `~/.hex` writes stay hermetic.
4. `extra_config` lines are appended to the **sandbox copy** of `config/config.exs`.
5. Rust NIFs listed in `native_libs` are staged into `priv/native/<crate>.so`.
6. Output is the compiled `ebin` plus `priv`, exposed as `ErlangAppInfo`.

### Attributes worth knowing

| Attribute | When you need it |
| --- | --- |
| `app_name` | Always. Must match the OTP application name, not the Bazel target name. |
| `srcs` | Always, normally `[":srcs"]`. Add external labels for files read at **compile time**. |
| `deps` | Always. `@hex_*//:erlang_app` for Hex, `//elixir/x:erlang_app` for first-party, plus `@rules_elixir//elixir`. |
| `mix_env` | `"test"` when `mix.exs` has `elixirc_paths(:test) => ["lib", "test/support"]` and the ExUnit targets need those support modules. Default `"prod"`. |
| `extra_config` | Build-system concerns that must not leak into checked-in config. Currently only Rustler `skip_compilation?: true`. |
| `native_libs` | `{"//path/to:nif_target": "crate_name"}`. See [Native NIFs](#native-nifs). |
| `hdrs` | Public `.hrl` headers, so a dependent's `-include_lib` resolves. |

## How dependencies work

There is no `mix deps.get` anywhere in the Bazel graph. Every Hex package is a **Bazel
repository** declared in `MODULE.bazel`:

```python
hex_archive(
    name = "hex_jason",
    package_name = "jason",
    build_file = "//third_party/hex:jason.BUILD",
    sha256 = "88...",       # OUTER tarball checksum, the last field of the mix.lock entry
    version = "1.4.4",
)
```

and each has a generated `BUILD` stub in `//third_party/hex` that runs it through `mix_app`
like any other project.

Both halves are generated by `scripts/gen_hex_bazel.exs` from the `mix.lock` files:

```sh
elixir scripts/gen_hex_bazel.exs elixir/*/mix.lock
```

It writes `third_party/hex/<pkg>.BUILD` per package and
`third_party/hex/hex_archives.MODULE`, whose contents you paste into `MODULE.bazel`.

Two consequences that bite:

- **Bazel repositories are global.** `@hex_ecto` can only be one version. If two projects'
  locks disagree, the generator fails rather than silently picking one. Reconcile the locks
  first.
- **First-party path overrides are invisible to `mix.lock`.** `connection`, `elixir_uuid`,
  `opentelemetry_oban` and `serviceradar_srql` are `path:` deps, so they never appear as lock
  entries, but Hex packages still declare edges to them (`gnat -> connection`). The
  `@path_deps` map at the top of `gen_hex_bazel.exs` redirects those edges. Miss one and the
  dependent fails with `module Connection is not loaded and could not be found`, which reads
  like a missing dependency rather than a shadowed one.

`bundlex` is pinned from git rather than Hex, so it is a hand-written `git_repository` in
`MODULE.bazel` and appears in `@path_deps` for the same reason.

## How tests work

### The `ex_unit_tests` macro

`//build:elixir_tests.bzl` generates one `ex_unit_test` per **top-level test directory**, plus
a `test_suite` over them.

Not one target per file, deliberately. `rules_erlang` stages the whole `ERL_LIBS` tree
(~140 applications for `serviceradar_core`) separately for **every** target. At one target per
file that is 595 x 140 staging actions before a single test runs, which never finished on a
developer machine.

Grouping by directory keeps what mattered: a group whose files did not change is a cache hit;
`--test_output=errors` prints only the failing group and ExUnit names the file and line inside
it; and groups run in parallel. A group over `max_group_size` (default 100) is split one level
deeper, with children under `min_subgroup_size` (default 20) pooled into `<parent>_other` so
each does not pay a full `ERL_LIBS` staging.

Group names come from the directory layout, so **a new test file needs no generator run and
nothing kept in sync**.

Which tests actually run is decided at runtime by the project's `test_helper.exs`, not by
Bazel. `serviceradar_core`'s excludes `[:integration, :external, :cluster, :large_ingestion,
:benchmark]` unless a database URL is in the environment. That keeps the "what needs a
database" decision where it already lived.

### Config loading

`elixir -r` does not evaluate `config/config.exs` the way `mix test` does, so
`//build:elixir_test_config_loader.exs` runs first (`load_config = True`, the default). It:

1. `Application.load/1`s every app on the code path, so each one's `env` from its `.app` file
   lands in the application environment;
2. reads `config/config.exs` with `Config.Reader` (which honours `import_config/1`, so the
   env-specific file comes along) and applies it with `persistent: true`.

`persistent: true` matters: without it, a later `Application.load/1` -- for instance when a
suite boots the app via `ensure_all_started/1` -- resets that app's environment from its
`.app` file and discards the config.

The macro stages `native.glob(["config/**"])` automatically when `load_config = True`. It has
to: the loader treats a missing `config/config.exs` as "this project has no config", which is
legitimate, and that guard turns a staging mistake into silence. It cost a full debugging
cycle once -- with `config/` unstaged, `config :swoosh, :api_client, false` never landed,
Swoosh fell back to `Swoosh.ApiClient.Hackney`, and the VM died with "Could not find hackney
dependency", a dependency the project does not have and whose absence is correct.

### Staging rules (the thing that actually goes wrong)

`ex_unit_test` stages **only `srcs` and `data`**. Anything a test opens from disk has to be
declared, and *where* it must be declared depends on *when* it is read:

| Read at | Declare on | Why |
| --- | --- | --- |
| Runtime, inside a test | `data` on the test target | It has to be in the test's runfiles |
| Module level / compile time, in a **test** file | `data` on the test target | Still the test's runfiles; no tag can skip it |
| Compile time, in a **lib** file | `srcs` on `mix_app` | It has to be an input to the compile action, in the `mix_app` build tree |

The third row is the subtle one. `ServiceRadar.Plugins.AddonConfigContractFixtures` pins
`@repo_root Path.expand("../../../../..", __DIR__)` at compile time, which under `mix_app`
resolves inside the build tree. Declaring those fixtures on the test target instead puts them
in the test's runfiles -- a different directory, and not the one the baked-in path points at.
The failure reads `could not read file .../erlang_app_mix/go/...`.

A file read at compile time *and* at runtime has to be declared in **both** places -- the two
are different directories, so satisfying one does not satisfy the other. `serviceradar_core`
does exactly that for the addon manifests: `//addons/bumblebee-scan:bumblebee_scan_manifest`
and friends appear in `mix_app`'s `srcs` *and* in the integration targets' `data`.

## The database-backed tier

Only `serviceradar_core` has one. It is separate from `unit_tests` because it needs a
PostgreSQL fixture (CNPG with TimescaleDB and Apache AGE).

### Shape

- **8 shards**, `integration_tests_s0` .. `integration_tests_s7`, one Bazel target each, each
  with **its own database**.
- Shard count, names and the file partition live in `//build:integration_shards.bzl`, which is
  read by both the Elixir targets and `//rust/integration-db:provision_db`. One list, both
  sides -- a mismatch would not be a build error, it would be a suite running against a
  database nothing provisioned.
- A database per shard is not optional. Ecto's SQL sandbox isolates concurrent tests inside a
  BEAM VM and does nothing across OS processes, so parallel targets against one database
  deadlock (measured: 25 failures across 6 of 7 groups, dominated by `40P01
  deadlock_detected`, where each group passed alone).

### The template

Migrations run **once** into a long-lived `sr_core_template`. Each run then takes a
`CREATE DATABASE ... TEMPLATE` physical file copy (~0.7s) instead of replaying 368
migrations.

A physical copy is faithful where a schema dump is not: 31 Timescale hypertables, 20
continuous aggregates and 3 AGE graphs survive it but do not survive `pg_dump --schema-only`.

Whether the template needs migrating is decided by comparing migration versions on disk
against its `schema_migrations` -- the same predicate `Ecto.Migrator` uses -- so there is no
marker to go stale.

### Lifecycle targets

Bazel deliberately does not order tests, so sequencing is the caller's job:

```
//rust/integration-db:sweep_stale_dbs     drop leaked databases from previous runs
//rust/integration-db:prepare_template    create the template if absent; report if it is behind
//elixir/serviceradar_core:migrate_template   only when behind; the only step that needs the BEAM
//rust/integration-db:provision_db        clone one database per shard from the template
//elixir/serviceradar_core:integration_tests_s0..s7
//rust/integration-db:teardown_db         drop the per-run databases
```

`migrate_template` is the only piece that must run on the BEAM, because the migrations are
`use Ecto.Migration` modules and only `Ecto.Migrator` can apply them. Everything else --
creating databases, extensions, AGE graphs, sweeping, teardown -- is Rust, which starts in
0.1s where the BEAM target costs 30-45s before it does anything.

### Tags

| Tag | Meaning here |
| --- | --- |
| `manual` | Keeps the target out of `//...`, so an ordinary `bazel test` never points DDL at the shared fixture, and never reports a vacuous pass when the fixture URL is absent. Every database target has it. |
| `external` | Disables Bazel's **test caching**. Load-bearing on the lifecycle targets: a cached "pass" would mean a rerun provisioned nothing and dropped nothing. **Not** on the shard targets -- their result is a function of their declared inputs, so a remote cache hit is a legitimate hit. |

Do not add `external` to the shard targets. It is pure loss there.

## Native NIFs

A Rustler NIF is built by Bazel as a `rust_shared_library` and handed to `mix_app` through
`native_libs`. Mix must not shell out to `cargo`.

Three details, all of which produce confusing failures if missed:

1. **`skip_compilation?: true` via `extra_config`.** `use Rustler` reads
   `Application.compile_env(otp_app, __MODULE__)` and merges it *over* its own options, so
   setting this in `extra_config` keeps cargo out of the Bazel action without touching `lib/`,
   the checked-in config, or what `mix release` does.
2. **`RUSTLER_PRIMARY_NIF_INIT=1` in `rustc_env`.** Rustler always emits
   `<crate>_nif_init`, but emits the plain `nif_init` that `:erlang.load_nif` looks for only
   when `RUSTLER_PRIMARY_NIF_INIT` or `CARGO_PRIMARY_PACKAGE` is set. Cargo sets the latter;
   Bazel does not. Without it the library loads and then fails with
   `{:bad_lib, "Failed to find library init function: dlsym(..., _nif_init)"}`.
3. **macOS needs `-Wl,-undefined,dynamic_lookup`.** The BEAM supplies the `enif_*` symbols at
   load time, so the shared object links with them undefined. That is the ELF default; Mach-O
   has to be told.

The extension is `.so` on macOS too, not `.dylib` -- `rustler` resolves the NIF as
`Application.app_dir(otp_app, "priv/native/<crate>")` and `:erlang.load_nif` appends `.so`.
`mix_app` handles this, dropping cargo's `lib` prefix.

## Step by step: add a first-party Elixir app

Say you are adding `elixir/serviceradar_widget`, OTP app name `serviceradar_widget`.

**1. Create the Mix project as usual.** `mix.exs`, `lib/`, `config/`, `test/`. Nothing
Bazel-specific goes in the project itself.

**2. Write `elixir/serviceradar_widget/BUILD.bazel`:**

```python
load("@serviceradar//build:elixir_tests.bzl", "ex_unit_tests")
load("@serviceradar//build:mix_app.bzl", "mix_app")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "srcs",
    srcs = glob(
        ["**"],
        exclude = [
            "bazel-*",
            "_build/**",
            "deps/**",
            "tmp/**",
        ],
    ),
)

# Bootstrap files only -- what `mix deps.get` needs to resolve this project as a path
# dependency, with none of its lib/ sources. Keeping this separate from :srcs is what lets
# //elixir/web-ng:deps_cache stay keyed on lockfiles.
filegroup(
    name = "deps_srcs",
    srcs = ["mix.exs"] + glob(
        [
            "mix.lock",
            "config/**",
        ],
        allow_empty = True,
    ),
)

mix_app(
    name = "erlang_app",
    srcs = [":srcs"],
    app_name = "serviceradar_widget",
    deps = [
        "@hex_jason//:erlang_app",
        "@rules_elixir//elixir",
    ],
)

ex_unit_tests(
    name = "unit_tests",
    srcs = glob(["test/**/*_test.exs"]),
    data = glob(
        [
            "lib/**",
            "priv/**",
            "test/**",
        ],
        allow_empty = True,
        exclude = ["test/**/*_test.exs"],
    ),
    test_helper = "test/test_helper.exs",
    deps = [":erlang_app"],
)
```

**3. Set `mix_env = "test"` if you have `test/support`.** Check `mix.exs`:

```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
```

If that line exists and your tests use those modules, add `mix_env = "test"` to `mix_app`.
Compiling under `:prod` silently omits them and the tests fail with `module ... is not
available`.

**4. Regenerate the Hex stubs** so every dependency in your new `mix.lock` exists as a Bazel
repository:

```sh
elixir scripts/gen_hex_bazel.exs elixir/*/mix.lock
```

Paste the emitted `third_party/hex/hex_archives.MODULE` block into `MODULE.bazel`. If the
generator errors on a version conflict, reconcile the locks -- do not hand-edit around it.

**5. If another first-party app will depend on yours**, add it to `@path_deps` in
`scripts/gen_hex_bazel.exs` *and* to that app's `mix_app` `deps` as
`//elixir/serviceradar_widget:erlang_app`.

**6. Build and test:**

```sh
bazel build //elixir/serviceradar_widget:erlang_app
bazel test  //elixir/serviceradar_widget:unit_tests
```

**7. Run buildifier:**

```sh
buildifier elixir/serviceradar_widget/BUILD.bazel
```

**8. If the app ships as a container or release**, wire `mix_release` (see
`elixir/serviceradar_agent_gateway/BUILD.bazel` for a worked example: `extra_dir_srcs` and
`extra_dirs` must list every path dependency, because `mix release` resolves them from the
source tree).

## Step by step: add a Hex dependency

**1. Add it to the project's `mix.exs` and run `mix deps.get`** so `mix.lock` gets a real
entry with a real checksum. Do this in the project directory as normal.

**2. Regenerate:**

```sh
elixir scripts/gen_hex_bazel.exs elixir/*/mix.lock
```

Pass **every** project's lock, not just the one you changed. Bazel repositories are global and
the generator's job is to assert the locks agree.

**3. Paste** the `hex_archive(...)` block(s) from `third_party/hex/hex_archives.MODULE` into
`MODULE.bazel`, keeping the alphabetical ordering.

**4. Add the dep to your `mix_app`'s `deps`:**

```python
deps = [
    "@hex_new_package//:erlang_app",
    ...
]
```

This is not inferred. The generated stub wires the *package's own* transitive deps; your
project's edge to it is yours to declare.

**5. Build.** A missing transitive edge shows up as `module X is not loaded and could not be
found` at compile time, not as a Bazel error.

### If the package is not on Hex

Declare a `git_repository` by hand in `MODULE.bazel` with a `build_file` pointing at a stub
you write in `//third_party/hex`, and add the package name to `@path_deps` in
`gen_hex_bazel.exs` so edges to it resolve. `bundlex` is the worked example.

### If the package will not build

Add it to the `@skip` map in `gen_hex_bazel.exs` **with a reason**. The map is currently
empty, which is the point -- it is a record of what Bazel cannot build, not a convenience.

## Step by step: add a test file

For a database-free test, there is nothing to do. Drop `test/foo/bar_test.exs` in place and
`ex_unit_tests` picks it up on the next `bazel test` -- group names come from the directory
layout, so no generator runs and no list is kept in sync.

Two cases need a BUILD change:

**The test reads a file.** Add it to `data` on the test target. If the file lives outside the
package, use a label (`"//helm/serviceradar:values"`), and make sure that package exports it
as a `filegroup`.

**The test reads a file at module level.** Same thing -- `data` -- but note that no ExUnit tag
can skip a module-level read, so the file is required even for a run that would exclude every
test in the module.

**The test needs the application running.** Tag it `@moduletag :requires_app` (or `use
ServiceRadar.DataCase`, which does it for you). It will then be excluded from the
database-free tier and included in the integration tier.

## Step by step: add a database-backed test

**1. Write the test** in `elixir/serviceradar_core/test/...`, tagged `@moduletag :integration`.
`use ServiceRadar.DataCase` gives you the Ecto sandbox; use plain `ExUnit.Case, async: false`
if the test drives its own connections, so it does not hold a sandbox connection idle.

**2. Nothing to declare for sharding.** `ALL_TEST_SRCS` globs `test/**/*_test.exs` and
`partition_by_shard` deals the files out, so a new file lands in a shard automatically.

The one exception is `test/db/**`, which the glob excludes. Those files are the database
lifecycle targets (`migrate_db_test.exs` and its helpers), declared individually rather than
partitioned -- they are not suite tests. Do not put an ordinary test there.

**3. If the test is slow**, add it to `_HEAVY_SRCS` in `//build:integration_shards.bzl` so it
does not share a shard with another slow file. Measure first:

```sh
bazel test //elixir/serviceradar_core:integration_tests_s6 \
  --test_env=SERVICERADAR_TEST_SLOWEST=15 --test_output=all
```

That list is a hint, not a contract -- a stale entry costs a slightly worse balance, a missing
one shows up as a single slow shard.

**4. If you added a migration**, nothing special: migrations are append-only and
`Ecto.Migrator` tracks what it applied, so `prepare_template` notices the template is behind
and `migrate_template` advances it by exactly that migration.

Two rules for migrations that this tier enforces the hard way:

- `CREATE INDEX CONCURRENTLY` needs **both** `@disable_ddl_transaction true` **and**
  `@disable_migration_lock true`. Without the second it deadlocks deterministically against
  Ecto's own migration lock -- and it will hang `mix ash.migrate` on a fresh database too.
- Everything goes in the `platform` schema (`prefix: "platform"`). Never `public`.

**5. Run it.** See below.

## Step by step: add a Rustler NIF

**1. Create the crate** at `elixir/<project>/native/<crate>/` with a `BUILD.bazel`:

```python
load("@rules_rust//rust:defs.bzl", "rust_shared_library")
load("//third_party/crates:defs.bzl", "all_crate_deps")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "srcs",
    srcs = glob(["**"], exclude = ["bazel-*", "target/**"]),
)

rust_shared_library(
    name = "widget_nif",
    srcs = glob(["src/**/*.rs"]),
    crate_name = "widget_nif",
    edition = "2021",
    rustc_env = {"RUSTLER_PRIMARY_NIF_INIT": "1"},
    rustc_flags = select({
        "@platforms//os:macos": ["-Clink-arg=-Wl,-undefined,dynamic_lookup"],
        "//conditions:default": [],
    }),
    deps = all_crate_deps(normal = True),
)
```

**2. Wire it into `mix_app`:**

```python
mix_app(
    name = "erlang_app",
    extra_config = [
        "config :serviceradar_widget, ServiceRadarWidget.Native, skip_compilation?: true",
    ],
    native_libs = {
        "//elixir/serviceradar_widget/native/widget_nif:widget_nif": "widget_nif",
    },
    deps = ["@hex_rustler//:erlang_app", ...],
)
```

The `native_libs` value is the **crate name**, which is what the file is installed as
(`priv/native/<crate>.so`) and what `rustler` looks for.

**3. Dependency rules apply** -- versions live in `[workspace.dependencies]` in the root
`Cargo.toml`, and a green `cargo check` does not prove the Bazel build. See
`rust/README_RUST.md`.

**4. Verify the NIF actually loads**, not just that it links:

```sh
bazel test //elixir/serviceradar_widget:unit_tests
```

A `{:bad_lib, ...}` at test time means step 2 of [Native NIFs](#native-nifs) is missing.

## Running things locally

### Unit tier

```sh
bazel test //elixir/...                                  # everything database-free
bazel test //elixir/serviceradar_core:unit_tests         # one project's suite
bazel test //elixir/serviceradar_core:unit_tests --test_output=errors
```

Integration targets are `manual`, so they do not run here.

### Integration tier

You need a PostgreSQL fixture with TimescaleDB and AGE. This is the exact invocation that
works against the project image:

```sh
docker run -d --name sr-pg -p 55433:5432 \
  registry.carverauto.dev/serviceradar/serviceradar-cnpg@sha256:c349a1d34aef056f818630e0766501b5c98fa7598bdeee38d59d677a94cb18c9 \
  bash -c 'export PGDATA=/tmp/pgdata; \
    if [ ! -s "$PGDATA/PG_VERSION" ]; then \
      initdb -U postgres --auth-host=trust --auth-local=trust >/dev/null \
        && echo "host all all all trust" >> "$PGDATA/pg_hba.conf"; \
    fi; \
    exec postgres -D "$PGDATA" \
      -c listen_addresses=0.0.0.0 \
      -c shared_preload_libraries=timescaledb,age \
      -c max_connections=300 \
      -c max_worker_processes=64'
```

Every part of that is load-bearing:

- **Pinned by digest.** The `:18.3.0-sr5` tag is a broken re-push whose container dies with a
  `GLIBC_2.38` error. Do not use the tag.
- **`initdb` into `/tmp/pgdata`.** The image's default entrypoint expects CNPG's operator
  environment; running `initdb` yourself is what makes it usable standalone.
- **The `PG_VERSION` guard.** Without it the command is single-use: `docker stop` followed by
  `docker start` re-runs `initdb` against a populated directory, it fails, and the container
  exits 1 before `postgres` ever starts. The guard makes the fixture survive a restart with
  its template and shard databases intact.
- **`--auth-host=trust` plus the `pg_hba.conf` line.** Without them every connection fails
  with `no pg_hba.conf entry for host ...`.
- **`shared_preload_libraries=...,age`.** AGE must be *preloaded*, not merely on the
  `search_path`. `create_graph` fails without the library loaded, which surfaces during
  template preparation, not at connect time.
- **`max_connections=300`.** Eight shards plus their pools exceed the default 100.
- **`max_worker_processes=64`.** Each cloned shard database carries Timescale's
  continuous-aggregate policy jobs, and eight of them exhaust the default. The symptom is a
  log full of `failed to launch job NNNN "Refresh Continuous Aggregate Policy": failed to
  start a background worker`. Harmless for the tests, which do not depend on background
  refresh, but it buries real errors.

On Apple Silicon the image is `linux/amd64` and runs under emulation; Docker prints a platform
warning, which is expected.

Then create the owner role. A fresh `initdb` has only `postgres`, and
`//rust/integration-db:{prepare_template,provision_db}` create every database owned by the
**user in `SRQL_TEST_DATABASE_URL`** -- `serviceradar` for the DSN below:

```sh
docker exec sr-pg psql -U postgres -c "CREATE ROLE serviceradar LOGIN SUPERUSER;"
```

Without it the very first step fails with `ERROR: role "serviceradar" does not exist`.
`SUPERUSER` because the migrations create extensions and AGE graphs; a plain owner is not
enough.

The owner is taken from that DSN rather than fixed, because it has to be the role the suite
*connects* as -- a database owned by anyone else fails on the first DDL the tests attempt. A
fixture whose application role is named something else therefore needs no configuration here.
Set `SERVICERADAR_TEST_DATABASE_OWNER` only to separate the owning role from the connecting
one deliberately.

You do **not** need to create `serviceradar_bootstrap_test` -- `StartupMigrations` creates the
application role itself, which is part of what the bootstrap test exercises.

Then:

```sh
export SRQL_TEST_DATABASE_URL="postgres://serviceradar@127.0.0.1:55433/postgres?sslmode=disable"
export SRQL_TEST_ADMIN_URL="postgres://postgres:postgres@127.0.0.1:55433/postgres?sslmode=disable"
export SERVICERADAR_TEST_ADMIN_URL="$SRQL_TEST_ADMIN_URL"

bazel run  //rust/integration-db:prepare_template
bazel test //elixir/serviceradar_core:migrate_template     # only if prepare_template says it is behind
bazel test //rust/integration-db:provision_db
bazel test //elixir/serviceradar_core:integration_tests    # the test_suite over all 8 shards
bazel test //rust/integration-db:teardown_db
```

**Put a password in the admin DSN even on a `trust` fixture.** `StartupMigrations` discards
admin credentials whose password is empty and silently falls back to the unprivileged
application role; the bootstrap test then dies in ownership repair with `42501 must be owner
of schema platform`, which names neither the credentials nor the cause. Under `trust`
PostgreSQL ignores the value, so any non-empty password works.

The fixture URLs reach the test through `--test_env` entries in `.bazelrc`. If they are
absent, `test_helper.exs` takes the no-database branch and excludes every test -- which is
why the integration targets are `manual`, so that never reads as a pass.

A single shard, when you know where the failure is:

```sh
bazel test //elixir/serviceradar_core:integration_tests_s5 --test_output=all --nocache_test_results
```

### Compiling only

```sh
bazel build //elixir/serviceradar_core:erlang_app
bazel build //elixir/...
```

### Quality gates

Formatting, Credo and Dialyzer are not Bazel targets; they run through Mix:

```sh
./scripts/elixir_quality.sh --project elixir/serviceradar_core
./scripts/elixir_quality.sh --project elixir/web-ng --phoenix
```

web-ng additionally has `//elixir/web-ng:precommit`, which runs `mix precommit_fast` (three
source-level lint tasks) as a **cacheable build action** rather than a test: `precommit_check`
does the work and `precommit` is a `build_test` over it, so an unchanged tree is a remote
cache hit. It takes OTP/Elixir from `@rules_elixir` like everything else, and sets
`SERVICERADAR_SKIP_NIF_COMPILATION` so Rustler skips all four crates -- nothing in that action
reads Rust sources.

## Failure modes and what they actually mean

| Symptom | Cause |
| --- | --- |
| `tar: Option --transform is not supported` | `portable_tar_extract.patch` not applied. macOS only. |
| `GenServer.call(Mix.ProjectStack, ...) no process` | Something compiled outside a Mix project. Use `mix_app`, not `elixir_app`. |
| `could not read file ".../erlang_app_mix/go/..."` | A compile-time read declared on the test target instead of `mix_app`'s `srcs`. |
| `could not read file ".../config/config.exs"` | `config/**` not staged. `load_config = True` handles it; a hand-written `ex_unit_test` must list it. |
| `could not fetch application environment ... because the application was not loaded` | Config loader did not run. Check `elixir_opts` ordering. |
| `Could not find hackney dependency` | Same root cause: `config/` unstaged, so `config :swoosh, :api_client, false` never landed. |
| `module ServiceRadar.TestSupport is not available` | `mix_env` is `"prod"` but `test/support` is needed. Set `mix_env = "test"`. |
| `module Connection is not loaded and could not be found` | A `path:` dep edge dropped. Add it to `@path_deps` in `gen_hex_bazel.exs`. |
| `{:bad_lib, "Failed to find library init function"}` | `RUSTLER_PRIMARY_NIF_INIT=1` missing from the NIF's `rustc_env`. |
| Cargo runs during a Bazel build | `skip_compilation?: true` missing from `extra_config`. |
| `40P01 deadlock_detected` across integration groups | Two shards sharing a database. Check `provision_db` ran with the current shard list. |
| Integration suite green having run zero tests | Fixture URL absent, so `test_helper` took the no-database branch. The `manual` tag exists to prevent this. |
| `42501 must be owner of schema platform` | Admin DSN has no password; see [Running things locally](#running-things-locally). |
| `template ... is behind by N migration(s)` | Run `//elixir/serviceradar_core:migrate_template`. |

## See also

- `//build:mix_app.bzl` -- the compile rule, with rationale
- `//build:elixir_tests.bzl` -- test grouping, with the arithmetic
- `//build:integration_shards.bzl` -- shard count and why eight
- `//rust/integration-db` -- database lifecycle
- `elixir/web-ng/AGENTS.md` -- Phoenix/LiveView/Ash rules for web-ng
- `rust/README_RUST.md` -- Rust dependency rules, which NIFs are subject to
- `AGENTS.md` -- repo-wide hard rules
