# rules_elixir / rules_erlang Consolidation

> **Status: done.** This was a specification; it is now a record. Where the original plan was
> wrong, the correction is stated rather than quietly edited out -- the mistakes are the
> useful part.
>
> Audience: the maintainer of `rules_elixir` and `rules_erlang`, who also owns this
> repository. Companion document: `hex-promotion-design.md`, still accurate.

## Outcome

`build/` went from 4034 lines across 11 files to **8 files, all of them policy**. The de facto
ruleset that lived here now lives in the rulesets.

| | before | after |
|---|---|---|
| `build/` | 11 files, ~4034 lines of de facto rules | 8 files: 2 thin wrappers + 6 policy/config |
| `//third_party/hex` | generator + rules + 269 stubs + closure | 3 files + 269 generated stubs |
| rules_elixir public rules | 7 | 16 |
| OTP staging | `/tmp/bazel/erlang/<name>`, outside the sandbox | a declared directory artifact |

Verified throughout on RBE: the hex drift test, the binding drift tests,
`//elixir/...`, `//config/...`, and the multiarch `web-ng` / `core-elx` /
`agent-gateway` images -- finally with both rulesets fetched from GitHub rather than local
checkouts, which is the only run that proves the pushed commits are complete.

## What moved

| Promoted | As | Note |
|---|---|---|
| `mix_app.bzl` (1318) | `mix_app` | Mix semantics `elixir_app` cannot give |
| `elixir_release.bzl` (468) | `elixir_release` | provider-closure assembly, zero compilation |
| `elixir_tests.bzl` (262) | `ex_unit_tests` | `ex_unit_test` has no sharding |
| `phoenix_digest.bzl` (134) | `phoenix_digest` | |
| `//third_party/hex` generator + rules | `hex_stubs` / `_test` / `_write` | reshaped, see below |
| `integration_shards.bzl` -- the *algorithm* only | `shard_names`, `partition_by_shard` | |
| — | `mix_payloads` | new: repo inputs as a toolchain |
| — | `elixir_library` | new: instantiable more than once per package |
| — | `elixir_escript` | new: nothing equivalent in either ruleset |
| — | `elixir_proto_library` | new |
| — | `//elixir:eex` | the ruleset exposed elixir/iex/logger/mix but not eex |

**Deleted outright:** `mix_release.bzl` + `mix_release_patches.py` (1154 lines, no loader --
this is where the `/cache` hostPath, the seven absolute `/tmp` symlinks and the in-action
`mix deps.get` lived), `mix_deps.bzl` and `mix_precommit.bzl` (gen-2, no loader), and the
`mix_app` wrapper.

**Fixed in the rulesets:** `elixir_app` no longer hardcodes `priv = []` / `hdrs = []`;
`elixir_bytecode` accepts a TreeArtifact in `srcs`; OTP is a build artifact.

## What stayed, and why it had to

Two of these are not preferences. Both were discovered by the build failing, not by reading.

- **`//third_party/hex:extensions.bzl`.** Repositories a module extension creates resolve
  apparent repo names through the repo mapping of the module that *defines* the extension.
  The generated stubs name `@serviceradar//third_party/hex_vendored/...`; declared from
  rules_elixir those resolve against rules_elixir's own dependencies and fail.
- **`hex_packages.bzl`.** Loaded during module-extension evaluation, which happens before the
  analysis phase exists. No build output can ever feed it. This is why the checked-in tree
  cannot be replaced by generation, only guarded against it.
- `hex_compile_env.bzl`, `integration_shards.bzl`, `integration_tests.bzl`,
  `elixir_test_config_loader.exs` -- policy and data, correctly local.
- `//build:elixir_release.bzl` and `//build:phoenix_digest.bzl` -- thin wrappers carrying
  `SHIPPED_ERTS_*` (per-target `select()` values a caller passes) and this repository's
  Phoenix (`@hexpm` is a hub name only the consumer chooses).

## The one bug class behind almost every failure

**A label that resolves against whoever holds it.** It appeared six times, in three forms,
and every single build break in this work was an instance of it:

1. **Attribute defaults written as bare `//...`.** `mix_app` had seven; `elixir_release` and
   `phoenix_digest` one each. They resolved to serviceradar only because the rule lived there.
   Moved into a ruleset, they resolve against the ruleset.
2. **Label strings inside a promoted `.bzl`.** A label string in a macro is resolved by the
   package that *calls* it. My own replacement wrapper used bare `//third_party/...`, and the
   generated Hex stubs call it from inside `@hex_bundlex`, which has no `third_party/`.
   `Label()` resolves against the defining file and is the fix.
3. **`.bazelrc` as a carrier.** I first solved "one value, many call sites" with a
   `label_flag` set in `.bazelrc`. That is client configuration, not build graph: any
   invocation not reading it silently gets the empty default. For payloads that meant NIFs
   linking no C++ runtime -- which builds clean and fails at `dlopen`.

**The rule that falls out:** repository-specific inputs a rule needs are a **toolchain**,
declared in `MODULE.bazel`. `mix_payloads` is that. It is optional
(`mandatory = False`), so a repository with no NIFs and no Hex archive configures nothing.

Two of these were caught only by the multiarch image build, because the failing package
(`ex_libsrt`) is the one that compiles C++. Neither unit tests nor a plain `//...` build
would have found them.

## Where the original plan was wrong

- **"Promote `//third_party/hex` wholesale"** (old §1.1). The coupling was deeper: two files
  cannot move at all (above), and the generator emitted a call to `mix_app`, which the
  ruleset did not ship. Sequence was therefore inverted -- `mix_app` first.
- **The sequence itself.** Step 1 was "promote hex". The real first step was making OTP a
  build artifact in rules_erlang, forced by the zero-`/tmp` requirement: the hex rules called
  `maybe_install_erlang`, so promoting them first would have enshrined the violation.
- **"OTP installations are not relocatable."** rules_erlang said so and the whole `/tmp`
  install prefix followed from it. False for OTP 28: every launcher resolves its own root via
  `dyn_erl --realpath` and prefers it over the recorded path. Verified by copying a tree
  elsewhere and running it.
- **`integration_shards.bzl` marked PROMOTE.** Only the dealing algorithm is general. The
  shard count is tuned to this repo's measurements and the file exists to make
  `//elixir/serviceradar_core` and `//rust/integration-db` agree. Promoting it would have
  moved policy into a ruleset.
- **`hex_compile_env.bzl` marked "PROMOTE -- highest value per line".** The *invariant* is
  general and is now documented on `mix_app`'s `extra_config`; the key list is this repo's.
- **"Justify the hex reshape on cache sharing."** Wrong: `gen_test` was already cached. The
  real defects were that `bazel run` and `bazel test` resolved their inputs differently and
  could disagree, and that the pruning pass was a no-op in test mode.

## Still open

- **rules_erlang fetches OTP with `curl` inside a build action** (`use_default_shell_env =
  True`, no declared network requirement), twice. Fetching is a repository-rule concern. This
  is the last of the four §4 bugs; the other three went with the `/tmp` work.
- **rules_erlang's hex resolver is still dead code** -- `hex_tree` / `_resolve_hex_pm`, three
  defects, zero references. Now clearly superseded: `hex_packages_extension` plus the
  promoted generator is the working model. It should be deleted.
- **Both rulesets are pinned to feature-branch tips**
  (`feat/sandbox-native-otp`, `feat/hex-dependency-model`). `git_override` fetches by commit
  so this works, but the pins break if the branches are deleted after merging. Re-pin to the
  merge commits on `main`.
- **rules_elixir has no test for any of the new rules.** Its own suite is 4 tests in a nested
  workspace at `test/`, and none of `mix_app`, `hex_stubs`, `elixir_library`,
  `elixir_escript` or `elixir_proto_library` is covered there. Everything above was verified
  against *this* repository, which is not the same thing as the ruleset being tested.
- **`elixir_escript` is worth a second look.** Getting it working took four fixes
  (runfiles-locating launcher, `FilesToRunProvider`, `bin_dir`-rooted staging, an
  `erlc`-compiled shim doing `io:setopts([binary])` and loading the entry app). The shim in
  particular reproduces what `mix escript.build` generates, and that similarity is worth
  making explicit rather than rediscovering.
