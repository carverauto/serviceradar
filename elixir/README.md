# Elixir under Bazel

How the Elixir tree is built and tested by Bazel, and what you have to do to add a package,
a dependency, a test tier, or a NIF.

This document covers local mechanics only. CI wiring lives in `.github/workflows/` and the root
`buildbuddy.yaml` workflow.

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
| `elixir/datasvc` | `erlang_app` | gRPC data service |
| `elixir/serviceradar_srql` | `erlang_app` | Wraps the `srql_nif` Rust NIF |
| `elixir/serviceradar_core` | `erlang_app`, `unit_tests`, `integration_tests_async`, `integration_tests_serial_0..serial_6`, `migrate_run`, `migrate_template`, `migrations` | The big one; ~2700 unit + ~1570 integration tests |
| `elixir/serviceradar_agent_gateway` | `erlang_app`, `unit_tests`, `release_tar` | |
| `elixir/web-ng` | `erlang_app`, `unit_tests`, `deps_cache`, `precommit`, `release_tar` | Phoenix; see `elixir/web-ng/AGENTS.md` |
| `elixir/serviceradar_core_elx` | `release_tar` | Release wrapper, no `mix_app` |
| `elixir/palisade` | none | Not compiled by Bazel; its `BUILD.bazel` only exports `mix.lock` for the Hex closure |

Vendored Hex packages that used to sit in this tree now live in
`//third_party/hex_vendored`, with the rest of the vendored code. They are still
Mix path deps and Bazel `mix_app`s; only the path changed.

| Path | Bazel targets | Notes |
| --- | --- | --- |
| `third_party/hex_vendored/connection` | `erlang_app` | Vendored `Connection`; shadows the Hex package |
| `third_party/hex_vendored/elixir_uuid` | `erlang_app` | Vendored; shadows the Hex package |
| `third_party/hex_vendored/opentelemetry_oban` | `erlang_app` | Vendored fork |
| `third_party/hex_vendored/boombox` | `erlang_app` | Patched Hex boombox (hackney source removed); single copy read by both Mix and Bazel |

Shared Starlark lives in `//build`:

| File | Purpose |
| --- | --- |
| `mix_app.bzl` | Compile a Mix project in one action. The core rule. |
| `elixir_tests.bzl` | `ex_unit_tests` macro: generate grouped ExUnit targets |
| `elixir_test_config_loader.exs` | Applies `config/config.exs` the way `mix test` does |
| `integration_shards.bzl` | Async/serial lane topology, shared with `//rust/integration-db` |
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
| `deps` | Always. `@hexpm//:<app>` for Hex, `//elixir/x:erlang_app` for first-party, plus `@rules_elixir//elixir`. |
| `mix_env` | `"test"` when `mix.exs` has `elixirc_paths(:test) => ["lib", "test/support"]` and the ExUnit targets need those support modules. Default `"prod"`. |
| `extra_config` | Build-system concerns that must not leak into checked-in config. Currently only Rustler `skip_compilation?: true`. |
| `native_libs` | `{"//path/to:nif_target": "crate_name"}`. See [Native NIFs](#native-nifs). |
| `hdrs` | Public `.hrl` headers, so a dependent's `-include_lib` resolves. |

## How dependencies work

There is no `mix deps.get` anywhere in the Bazel graph. Every Hex package is a **Bazel
repository**, and you depend on it through the `@hexpm` hub:

```python
deps = ["@hexpm//:jason"]
```

`@hexpm` is a repository of aliases, one per package, generated by a single module
extension. The whole Hex section of `MODULE.bazel` is two lines:

```python
hex_ext = use_extension("//third_party/hex:extensions.bzl", "hex")
use_repo(hex_ext, "hexpm")
```

Behind each alias is a `hex_archive` repository named `@hex_<app>`, overlaid with a
generated `BUILD` stub in `//third_party/hex` that runs the package through `mix_app` like
any other project. You should not need to name `@hex_<app>` directly — the generated stubs
refer to each other that way, but first-party code goes through the hub.

Both halves — the stubs and the package list the extension reads — come out of one target:

```sh
bazel run //third_party/hex:gen        # regenerate from the mix.lock files
bazel test //third_party/hex:gen_test  # fails when the checked-in tree is stale
```

`gen_test` runs in CI. That is what stops a `mix.lock` bump from leaving Bazel building an
older closure than Mix resolves.

Three consequences that bite:

- **Bazel repositories are global.** `@hexpm//:ecto` can only be one version. When the
  projects' locks disagree the generator consolidates onto the **highest** version and warns,
  naming every lock and version involved. The warning is not cosmetic: the project on the
  losing side compiles against one version under Mix and another under Bazel, so reconcile
  the locks. If a closure ever genuinely needs two versions side by side, the convention is a
  version-suffixed pair (`@hexpm//:plug_crypto_2_1`, `@hexpm//:plug_crypto_2_2`) with each
  target choosing — not two unnamed repositories.
- **First-party path overrides are invisible to `mix.lock`.** `connection`, `elixir_uuid`,
  `opentelemetry_oban` and `serviceradar_srql` are `path:` deps, so they never appear as lock
  entries, but Hex packages still declare edges to them (`gnat -> connection`). The
  `@path_deps` map at the top of `third_party/hex/gen_hex_bazel.exs` redirects those edges.
  Miss one and the dependent fails with `module Connection is not loaded and could not be
  found`, which reads like a missing dependency rather than a shadowed one.
- **A package that leaves every lock is pruned.** `gen` deletes generated stubs that no
  longer resolve, and `gen_test` fails if one is still checked in. Hand-written stubs are
  recognised by the absence of the generated marker and left alone.

`bundlex` is pinned from git rather than Hex, so it is declared by hand as a `git_pkg` in
`//third_party/hex:extensions.bzl` — in the same extension as the fetched packages, which is
what lets sibling stubs resolve `@hex_bundlex` — with a hand-written stub, and it appears in
`@path_deps` for the same reason.

### Compile-time config a dependency reads

`Application.compile_env/3` bakes a value into a module attribute at compile time and records
what it saw. At boot, `Config.Provider` compares every recorded value against the release's
`sys.config` and refuses to start if they disagree:

```text
ERROR! the application :ash has a different value set for key
:include_embedded_source_by_default? during runtime compared to compile time.
  * Compile time value was not set
  * Runtime value was set to: false
Runtime terminating during boot
```

Mix satisfies that invariant for free: one `mix compile` evaluates the root config once, and
every dependency is compiled under it. Here each Hex package is its own `mix_app` target in
its own sandbox, so a dependency reading a key with `compile_env` sees **only its own
default** -- while the assembled release still applies our `config/config.exs` at runtime.

`//build:hex_compile_env.bzl` exists for exactly this. Its `HEX_COMPILE_ENV_CONFIG` list is
emitted by `gen_hex_bazel.exs` into every Mix-built package's `extra_config`, so dependencies
record the same value the release will supply. Add a key there when both are true:

- our `config/config.exs` sets it, and
- a Hex dependency reads it through `Application.compile_env/2,3`

**Do not "fix" this with `validate_compile_env: false`.** The release would boot while the
dependency keeps its own compiled-in default -- for the current entry, `ash` would behave as
`true` when we mean `false`. That turns a loud boot failure into a silent behavioural change.

Keep the list short: every entry invalidates the cached build of all ~249 Mix-built packages.

Two things `extra_config` has to tolerate, both real:

- a package whose `config/config.exs` exists but is empty (`yaml_elixir`'s is a single
  newline), so nothing imports `Config` and the appended lines fail with
  `undefined function config/2`
- a package still using the deprecated `use Mix.Config` (`stream_split`), where an
  unconditional `import Config` fails the other way with
  `function config/2 imported from both Config and Mix.Config, call is ambiguous`

`mix_app` therefore imports `Config` only when the file provides neither form.

### Inspecting build outputs locally

`--config=ci` sets `--remote_download_minimal`, so **build outputs are not downloaded**.
An `oci_image` layout will appear to contain only `blobs/` with no `index.json`, a `.digest`
file will be empty, and a release tarball simply will not be there. None of that means the
build failed -- the artifacts are on the remote.

To inspect anything locally, ask for it:

```sh
bazel build -c opt --config=ci --remote_download_outputs=all //some:target
```

`bazel run` materializes the runfiles its executable needs. Workflows that inspect generated
files directly must request `--remote_download_outputs=all` or the narrower `toplevel` mode
explicitly; there is no separate `remote_push` profile.

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

- **8 lanes**: `integration_tests_async` plus `integration_tests_serial_0` through
  `integration_tests_serial_6`. Each has its own database and matching provision target:
  `provision_db_async` or `provision_db_serial_0` through `provision_db_serial_6`.
- Lane names and the audited source partition live in `//build:integration_shards.bzl`, which
  both the Elixir targets and Rust provisioner read. The async lane runs `max_cases=8`; every
  serial lane runs `max_cases=1`.
- Every ordinary lane uses `pool_size=12`. The async BEAM's eight test cases leave four checkout
  slots as BEAM-internal headroom for test-supervised child processes; they are not capacity for
  more BEAMs or for deployed services.
- A database per lane is mandatory. Ecto's SQL sandbox isolates concurrent tests inside one BEAM
  VM and does nothing across OS processes. The only allowed target databases are disposable
  `sr_core_test_<run-id>_<lane>` clones on `srql-fixtures`; never point this topology at demo,
  production, or another non-disposable database.

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
//rust/integration-db:provision_base      seed sr_core_test_<run> from the template; report if it is behind
//elixir/serviceradar_core:migrate_run    only when behind; the only step that needs the BEAM
//rust/integration-db:provision_db_async  clone the async lane database from the run base
//elixir/serviceradar_core:integration_tests_async
//rust/integration-db:provision_db_serial_0..serial_6
//elixir/serviceradar_core:integration_tests_serial_0..serial_6
//rust/integration-db:teardown_db         drop the per-run databases
```

Pair a provision and test target with the exact same suffix. These targets are for disposable
`srql-fixtures` clones only; never substitute demo or production.

The migrator is the only piece that must run on the BEAM, because the migrations are
`use Ecto.Migration` modules and only `Ecto.Migrator` can apply them. Everything else --
creating databases, extensions, AGE graphs, sweeping, teardown -- is Rust, which starts in
0.1s where the BEAM target costs 30-45s before it does anything.

#### The template is a cache of trunk's schema, and only trunk writes it

`sr_core_template` is shared by every run on the fixture and only ratchets forward, so a run
that migrates it changes what every later run clones. That write belongs to trunk alone, and
lives in one place: the `LargeIngestionGate` action, which triggers on a push to `staging`, runs
`//rust/integration-db:prepare_template` and then `//elixir/serviceradar_core:migrate_template`.

It is the only action that may, and that is enforced by the targets rather than by where they
are named. All three template writers -- those two plus `//rust/integration-db:reset_template` --
refuse unless the caller passes `--//build:template_authority=true`, the checkout declaring
itself to be trunk. `LargeIngestionGate` passes it; `//:ci_heavy_gate_contract_test` fails if
any other action does. The decision reaches Rust and Elixir as the same staged file
(`//build:template_authority_file`), for the reason the run id does: several invocations must
agree, and ambient environment lets them differ. It fails closed -- an absent, empty or mangled
marker is a refusal -- so the worst a mistake costs is a loud stop.

Every other lifecycle -- BazelCI included, and BazelCI only ever runs on a branch -- applies its
own migrations to its **run base** instead. `provision_base` seeds `sr_core_test_<run>` from the
template, `migrate_run` brings that one database up to the checkout, and the lane databases are
cloned from it. A branch's migrations therefore never become visible to another branch.

That split is a fix, not a preference. While every action shared one destination, a branch with
seven unmerged migrations advanced the template, and from then on every branch whose checkout
lacked them was refused a clone -- correctly, since it would otherwise have run against a future
schema, but the branch that paid was never the branch that caused it.

Two consequences worth knowing:

- If `provision_base` reports the template **AHEAD** of your checkout, it does not fail. It
  builds the run base from nothing and says so; the run costs a full schema build and the shared
  template is left untouched. A cache that cannot be used is a cache miss, not an outage.
- `bazel run //rust/integration-db:reset_template` drops the template so the next trunk run
  rebuilds it, and needs `--//build:template_authority=true` from a trunk checkout. The trunk
  lifecycle already does this automatically when `prepare_template` reports it ahead, which is
  the only context where "ahead of this checkout" and "ahead of the schema of record" mean the
  same thing. Do not add the flag on a branch to make a refusal go away -- it is a statement
  about the checkout, and a branch that sets it recreates the outage this split fixed.

### Tags

| Tag | Meaning here |
| --- | --- |
| `manual` | Keeps the target out of `//...`, so an ordinary `bazel test` never points DDL at the shared fixture, and never reports a vacuous pass when the fixture URL is absent. Every database target has it. |
| `external` | Disables Bazel's **test caching**. Load-bearing on the lifecycle targets: a cached "pass" would mean a rerun provisioned nothing and dropped nothing. Supported lane invocations pass `--nocache_test_results` because lane outcomes depend on mutable fixture state. CI additionally disables uploading local test results; a workstation does not, so locally compiled cache misses can still populate the shared cache. |

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
        "@hexpm//:jason",
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
repository, and add your lock to `MIX_LOCKS` in `//third_party/hex/BUILD.bazel`:

```sh
bazel run //third_party/hex:gen
```

Nothing to paste anywhere. If the generator warns about a version conflict, reconcile the
locks -- it will build, but Mix and Bazel are then compiling different versions.

**5. If another first-party app will depend on yours**, add it to `@path_deps` in
`third_party/hex/gen_hex_bazel.exs` *and* to that app's `mix_app` `deps` as
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
bazel run //third_party/hex:gen
```

The target already passes **every** project's lock, not just the one you changed: Bazel
repositories are global, so the closure has to be resolved across the whole workspace at
once.

**3. Nothing to paste.** `gen` writes both the stubs and `third_party/hex/hex_packages.bzl`,
which is the list the module extension reads. Review the diff as you would any generated
file.

**4. Add the dep to your `mix_app`'s `deps`:**

```python
deps = [
    "@hexpm//:new_package",
    ...
]
```

This is not inferred. The generated stub wires the *package's own* transitive deps; your
project's edge to it is yours to declare.

**5. Build.** A missing transitive edge shows up as `module X is not loaded and could not be
found` at compile time, not as a Bazel error.

### If the package is not on Hex

Add a `git_pkg(...)` to `//third_party/hex:extensions.bzl` with a `build_file` pointing at a
stub you write in `//third_party/hex`, and add the package name to `@path_deps` in
`third_party/hex/gen_hex_bazel.exs` so edges to it resolve. Keep the stub free of the
`do not edit by hand` marker, or `gen` will prune it as a package that left the closure.
`bundlex` is the worked example.

### If the package will not build

Add it to the `@skip` map in `third_party/hex/gen_hex_bazel.exs` **with a reason**. The map
is currently empty, which is the point -- it is a record of what Bazel cannot build, not a
convenience.

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

**2. Classify the source for lane selection.** `ALL_TEST_SRCS` globs `test/**/*_test.exs`, and
the checked-in disposition inventory places every selected source in `partition_by_lane` as async
or serial. Do not assign a file based on a one-off duration measurement.

The normal exception is `test/db/**`, which the glob excludes. Those files are the database
lifecycle targets (`migrate_db_test.exs` and its helpers), declared individually rather than
partitioned -- they are not suite tests. Do not put an ordinary test there. A deliberately heavy
test may also be explicitly source-separated when its complete production-path coverage cannot
fit the PR lifecycle budget; cold database bootstrap is the current example and runs intact in
`//elixir/serviceradar_core:large_ingestion_release_gate`. Any new exception requires a checked-in
source-membership contract and release-qualification coverage.

**3. If the test is slow**, profile it as a lane step of the
[canonical fixture lifecycle](../.agents/skills/srql-fixtures-db-tests/SKILL.md), after its
matching provision target. Use `provision_db_async` with `integration_tests_async`, or the same
`serial_0` through `serial_6` suffix on `provision_db_serial_*` and
`integration_tests_serial_*`. Built-in slowest reporting enables trace, forces serial execution,
and disables test timeouts, so explicitly set the profiling cap to one and never use this command
as latency or concurrency evidence:

```sh
bazel test "${TEST_FLAGS[@]}" --test_env=SERVICERADAR_INTEGRATION_MAX_CASES=1 \
  --test_env=SERVICERADAR_TEST_SLOWEST=15 \
  --test_output=all //elixir/serviceradar_core:integration_tests_serial_6
```

Profiling does not change lane membership. Update an audited disposition only when the source's
isolation semantics change; controlled BuildBuddy cohorts remain acceptance evidence.

**4. If you added a migration**, nothing special: migrations are append-only and
`Ecto.Migrator` tracks what it applied, so `provision_base` notices the run base is behind and
`migrate_run` advances it by exactly that migration. Your migration reaches the shared template
only once it is on `staging`, applied there by the trunk lifecycle.

Two rules for migrations that this tier enforces the hard way:

- `CREATE INDEX CONCURRENTLY`, and any other `CONCURRENTLY` index statement such as
  `REINDEX INDEX CONCURRENTLY`, needs **both** `@disable_ddl_transaction true` **and**
  `@disable_migration_lock true`. Without the second it deadlocks deterministically against
  Ecto's own migration lock -- and it will hang `mix ash.migrate` on a fresh database too.
- Everything goes in the `platform` schema (`prefix: "platform"`). Never `public`.

**5. Run it.** See below.

## Step by step: add a Rustler NIF

**1. Create the crate** at `elixir/<project>/native/<crate>/` with a `BUILD.bazel`:

```python
load("@rules_rust//rust:defs.bzl", "rust_shared_library")
load("@crates//:defs.bzl", "all_crate_deps")

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
    deps = ["@hexpm//:rustler", ...],
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
  its template and lane databases intact.
- **`--auth-host=trust` plus the `pg_hba.conf` line.** Without them every connection fails
  with `no pg_hba.conf entry for host ...`.
- **`shared_preload_libraries=...,age`.** AGE must be *preloaded*, not merely on the
  `search_path`. `create_graph` fails without the library loaded, which surfaces during
  template preparation, not at connect time.
- **`max_connections=300`.** One async and seven serial test BEAMs, each with a 12-connection
  pool, exceed the default 100.
- **`max_worker_processes=64`.** Each cloned lane database carries Timescale's
  continuous-aggregate policy jobs, and all eight lanes exhaust the default. The symptom is a
  log full of `failed to launch job NNNN "Refresh Continuous Aggregate Policy": failed to
  start a background worker`. Harmless for the tests, which do not depend on background
  refresh, but it buries real errors.

On Apple Silicon the image is `linux/amd64` and runs under emulation; Docker prints a platform
warning, which is expected.

Then create the owner role. A fresh `initdb` has only `postgres`, and
`//rust/integration-db:{provision_base,provision_db_async,provision_db_serial_0..serial_6}`
create every database owned by the
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

Then establish one numeric run identity for the entire lifecycle. Keep the fixture URL in
`SRQL_TEST_DATABASE_URL`; the integration target derives its disposable lane URL inside the test
action:

```sh
export SRQL_TEST_DATABASE_URL="postgres://serviceradar@127.0.0.1:55433/serviceradar_test?sslmode=disable"
export SRQL_TEST_ADMIN_URL="postgres://postgres:postgres@127.0.0.1:55433/postgres?sslmode=disable"
unset SERVICERADAR_TEST_DATABASE_URL SERVICERADAR_TEST_ADMIN_URL

# The run correlation id. Passed to EVERY bazel invocation in the sequence as
# --//build:run_id=$RUN_ID; it reaches each step as a declared input, not as environment.
RUN_ID="$(uuidgen | tr -d - | tr 'A-Z' 'a-z' | cut -c1-8)"
```

Invoke the Bazel targets with the caller-owned cleanup trap in
`.agents/skills/srql-fixtures-db-tests/SKILL.md`. For this Docker fixture, reuse the recipe from
`RUN_ID` onward with the two URLs and run id above; omit its Kubernetes host/TLS
exports plus `buildbuddy_setup_fixture_env`/source lines. This Docker setup is a local development
fixture, not a substitute for the guarded async/serial topology: that topology requires disposable
`srql-fixtures` clones and must never target demo or production. The canonical cleanup preserves a
red lane status and also fails an otherwise-green run when teardown fails.

**Put a password in the admin DSN even on a `trust` fixture.** `StartupMigrations` discards
admin credentials whose password is empty and silently falls back to the unprivileged
application role; the bootstrap test then dies in ownership repair with `42501 must be owner
of schema platform`, which names neither the credentials nor the cause. Under `trust`
PostgreSQL ignores the value, so any non-empty password works.

The fixture URLs reach the test through `--test_env` entries in `.bazelrc`. If they are
absent, `test_helper.exs` takes the no-database branch and excludes every test -- which is
why the integration targets are `manual`, so that never reads as a pass.

With an ignored mode-0600 `.bazelrc.remote` credential, the skill selects `--config=cache_only`.
Bazel then reuses and populates the authenticated cache while `TestRunner` stays on the native
workstation. Do not use `--config=ci` locally: it selects the Linux RBE platform.

### Compiling only

```sh
bazel build //elixir/serviceradar_core:erlang_app
bazel build //elixir/...
```

### Quality gates

Formatting, Credo and Dialyzer are not Bazel targets; they run through Mix.

Pull requests gate `mix format --check-formatted` and `mix credo --strict` via
`.github/workflows/elixir-quality.yml` (`--lint-only`). Compile warnings, xref,
dependency audits, Sobelow, and the OpenAPI dump check run daily from
`//buildbuddy.yaml` (`Elixir Quality (daily)`).

```sh
./scripts/elixir_quality.sh --project elixir/serviceradar_core --lint-only
./scripts/elixir_quality.sh --project elixir/web-ng --lint-only
./scripts/elixir_quality.sh --all --skip-dialyzer --skip-nif
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
| `module Connection is not loaded and could not be found` | A `path:` dep edge dropped. Add it to `@path_deps` in `third_party/hex/gen_hex_bazel.exs`. |
| `{:bad_lib, "Failed to find library init function"}` | `RUSTLER_PRIMARY_NIF_INIT=1` missing from the NIF's `rustc_env`. |
| Cargo runs during a Bazel build | `skip_compilation?: true` missing from `extra_config`. |
| `40P01 deadlock_detected` across integration groups | Two lanes sharing a database. Check the matching `provision_db_async` or `provision_db_serial_*` target ran first. |
| Integration suite green having run zero tests | Fixture URL absent, so `test_helper` took the no-database branch. The `manual` tag exists to prevent this. |
| `42501 must be owner of schema platform` | Admin DSN has no password; see [Running things locally](#running-things-locally). |
| `run base ... does not match this checkout` | The migrate step did not run. Run `//elixir/serviceradar_core:migrate_run` before `provision_db`. |
| `template ... is AHEAD of this checkout` | Not fatal: `provision_base` builds the base from nothing instead. If the named versions are on `staging`, rebase. If they are on no landed branch, `bazel run //rust/integration-db:reset_template` from a trunk checkout. |
| `writes the SHARED template sr_core_template, which only a trunk checkout may do` | Working as intended on a branch. Use the run base: `//rust/integration-db:provision_base`, then `//elixir/serviceradar_core:migrate_run`. Do not pass `--//build:template_authority=true` to get past it. |
| `the application :X has a different value set for key :Y during runtime compared to compile time` | A Hex dependency read `Y` with `compile_env` and was compiled without it. Add it to `HEX_COMPILE_ENV_CONFIG` in `//build:hex_compile_env.bzl`. Never `validate_compile_env: false` -- see [Compile-time config a dependency reads](#compile-time-config-a-dependency-reads). |
| `undefined function config/2` while compiling a Hex package | That package's `config/config.exs` exists but is empty, so nothing imported `Config`. `mix_app` handles this; if you see it, the guard regressed. |
| `function config/2 imported from both Config and Mix.Config` | That package uses the deprecated `use Mix.Config`. Same guard, other direction. |
| An `oci_image` layout has only `blobs/`, a `.digest` is empty, a release tar is missing | Nothing failed. `--config=ci` implies `--remote_download_minimal`. Rebuild with `--remote_download_outputs=all` to inspect locally. |

## See also

- `//build:mix_app.bzl` -- the compile rule, with rationale
- `//build:elixir_tests.bzl` -- test grouping, with the arithmetic
- `//build:integration_shards.bzl` -- async/serial lane topology and capacity
- `//rust/integration-db` -- database lifecycle
- `elixir/web-ng/AGENTS.md` -- Phoenix/LiveView/Ash rules for web-ng
- `rust/README_RUST.md` -- Rust dependency rules, which NIFs are subject to
- `AGENTS.md` -- repo-wide hard rules
