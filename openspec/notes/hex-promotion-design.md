# Promoting the Hex stub generator into rules_elixir

> Design for consolidation step 1. Derived from a four-lens audit of the generator, the
> ruleset's conventions, the action shape, and the consumers; every claim carries a file:line
> in the audit output. Supersedes the "promote `//third_party/hex` wholesale" line in
> `rules-elixir-consolidation.md` §1.1, which underestimated the coupling.

## What can move, and what cannot

The audit split `//third_party/hex` cleanly. Three things are ruleset machinery; everything
else is this repository's dependency policy and has to stay.

| Artifact | Verdict | Why |
|---|---|---|
| `gen_hex_bazel.exs` | **PROMOTE** | reads `mix.lock`, emits stubs -- generic once parameterised |
| `hex_gen.bzl` (`hex_gen`, `hex_gen_test`) | **PROMOTE**, reshaped | the run/test/diff machinery |
| the erlang_app stub template | **PROMOTE** as default | emits `@rules_erlang//:erlang_app.bzl`, ruleset-level |
| `extensions.bzl` | **STAYS** | see "repo mapping" below -- this one is not a preference |
| `hex_packages.bzl` | **STAYS**, and stays a source file | see "why it cannot be generated at build time" |
| `*.BUILD` (269) | **STAYS** | generated data |
| `bundlex.BUILD` + the `git_pkg` block | **STAYS** | a Membrane git pin, a commit SHA, three patch labels |
| the mix_app stub template | **STAYS for now** | see "the Mix template blocker" |

### Repo mapping is why `extensions.bzl` cannot move

Generated stubs name `@serviceradar//third_party/hex_vendored/connection:erlang_app` and
`@serviceradar//elixir/serviceradar_srql:erlang_app`. Those apparent repo names resolve
against the repo mapping of **the module that defines the extension**. Defined from
rules_elixir, they would resolve against rules_elixir's own dependencies and fail. The
extension declaring a repository's closure therefore belongs to that repository, permanently.
Only the *factory* (`hex_packages_extension`, already in rules_erlang) is ruleset-level.

### The Mix template blocker

The Mix stub emits `mix_app` from `@serviceradar//build:mix_app.bzl` -- 1,318 lines, and
rules_elixir has no equivalent. A ruleset cannot emit a call to a rule it does not ship.

So the stub body is a **template file supplied by the caller**, with the erlang_app template
defaulting to a ruleset-provided one. When `mix_library` lands (consolidation step 3), the
Mix template becomes a ruleset default too and this attribute goes back to being optional.
This is the seam that lets step 1 land before step 3, in the reverse of the order the
consolidation note assumed.

## Why reshape at all

Not for cache sharing. `gen_test` carries no `external` or no-cache tag and nothing disables
test caching, so Bazel already caches its result keyed on the generator, the locks, the
toolchain and the checked-in stubs. That claim was wrong and is not a justification.

The real defects:

1. **`bazel run` and `bazel test` do not read the same inputs.** Run mode `cd`s into
   `$BUILD_WORKSPACE_DIRECTORY` and resolves lock paths against the live working tree; test
   mode resolves the same relative strings against the runfiles tree. The two can disagree,
   and the drift guard is the thing that is supposed to make disagreement impossible.
2. **Pruning is dead code in test mode.** `prune/2` globs `out_dir`, which in test mode holds
   only what the generator just wrote, so nothing is ever eligible. The test compensates with
   an independent shell reimplementation of staleness detection -- two rules for one property.
3. **The test carries the toolchain.** Generation at test time means every invocation is an
   Elixir invocation. As an action it is one cacheable, remotely-executable step, and the test
   becomes a comparison.

## Shape

Three targets over one generation action.

```
hex_stubs        ACTION: locks + config + templates -> TreeArtifact + manifest
hex_stubs_test   TEST:   compares that output against the checked-in labels
hex_stubs_write  RUN:    copies that output into the source tree (tags = ["manual"])
```

Both consumers read the **same declared output**, which is what removes defect 1 by
construction.

### Output is a TreeArtifact plus a manifest

The generator decides filenames from `mix.lock`, so the output set is not knowable at analysis
time -- a TreeArtifact is the only honest model, and it matches `elixir_bytecode`'s
`declare_directory` precedent.

A TreeArtifact alone cannot be diffed declaratively, so the same action also emits a
**manifest**: one sorted `name<TAB>sha256` line per generated file. The test compares manifests
first, so a name-set difference is reported as `added: foo.BUILD` / `pruned: bar.BUILD` before
any content comparison is attempted. This is also what replaces pruning: a checked-in file the
locks no longer produce is a manifest difference, not a deletion an action has to perform.

A fixed list of `declare_file` outputs was considered and rejected. It is achievable here --
`HEX_PACKAGES` is checked in and loadable at analysis time -- but it bootstraps the validator
off the artifact under validation, and a newly locked package fails as a Bazel internal error
rather than an actionable message.

### The comparison is driven by labels, never by walking the directory

`third_party/hex/` also holds `BUILD.bazel`, `extensions.bzl`, the generator and the
hand-written `bundlex.BUILD`. A `diff -r` against it is therefore wrong. The test takes an
explicit `checked_in` label list, which also makes the one hand-written exemption visible in
BUILD.bazel instead of implied by grepping files for a marker string.

## Constraints that are easy to get wrong

- **`hex_packages.bzl` must stay a checked-in source file.** `extensions.bzl` loads it during
  module-extension evaluation, which happens before the analysis phase exists. No build output
  can ever feed it. This is the reason the checked-in tree cannot simply be deleted in favour
  of generation.
- **The checked-in files are inputs to the TEST only.** If they reach the generation action's
  inputs, its cache key becomes a function of its own previous output and every regeneration
  invalidates the action that produced it.
- **The action needs `short_path = False`.** The current rule passes `short_path = True`
  throughout because it builds a runfiles script; an action runs in the execroot, where those
  paths do not exist. The writeback executable still needs `True`.
- **The action needs its own writable `HOME`.** The test sets `HOME=$TEST_TMPDIR`, which an
  action does not have, and the run mode sets none at all and inherits the developer's. Use
  `export HOME="$PWD"`, per `ex_unit_test`.
- **Writeback must fix permissions.** Action outputs are commonly non-writable, and `cp`
  propagates mode, so the first `bazel run` succeeds and the second fails on 268 files.
- **Only the writeback target is `manual`.** The generation rule must be reachable from a
  wildcard build; a target that mutates the source tree must not be.

## Ruleset conventions this must follow

A public rule is implemented in `private/<name>.bzl` and re-exported by a top-level
`<name>.bzl` that loads it under an underscore alias and wraps it in a `**kwargs` passthrough.
The toolchain type is the literal `"//:toolchain_type"`. Toolchain paths are never read off the
providers directly -- they go through the `private/elixir_toolchain.bzl` helpers, each taking a
`short_path` flag.
