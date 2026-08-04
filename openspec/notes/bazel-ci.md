# Master CI Workflow: Audit and Consolidation Plan

Status: plan only. Nothing here has been implemented.

Date: 2026-08-04

## Why

CI is spread across 28 Forgejo workflows. Nine drive Bazel. Each re-implements the same
preamble: checkout, install bazelisk, write `.bazelrc.remote`, resolve a target list, run
bazel. They differ mostly in their `paths:` filter and their target query.

The goal is one master workflow running a fixed sequence. That workflow is also the
rehearsal for replacing BuildBuddy with NativeLink, because a job that only names
`--config=ci` can be repointed at a different backend by editing three lines in `.bazelrc`.

Decisions already taken:

- `--config=ci`. It carries the 15m remote timeout, `ROLE=CI`
  metadata, and the `NpmPackageExtract=local` strategy pin.
- Keep `-c opt` on every command.
- Keep BES pointed at BuildBuddy during the rehearsal, and drop it after the sequence is
  green.
- Go race detection gets its own job, running concurrently with the main test job.

Accepted cost of `-c opt`: no workflow uses it today and `.bazelrc` sets no
`compilation_mode`, so CI runs `fastbuild`. The first master run is a full cold build, and
the CAS carries two trees from then on.

## Part 1: Audit of every non-Bazel guard

The question for each: is it load-bearing, and if so can it be a Bazel target?

### Delete outright

**1. Bazel version assertion (`main.yml`)**

```
expected="$(tr -d '\r\n' < .bazelversion)"
actual="$(bazel --version | awk '{print $NF}')"
test "${actual}" = "${expected}"
```

Circular. Bazelisk reads `.bazelversion` to decide which Bazel to fetch, then this compares
bazelisk's output against the file bazelisk just read. It can only fail if bazelisk itself
is broken, in which case every later step fails anyway with a better message. Delete.

**2. Setup Beam (`main.yml`)**

Installs OTP 28.3 and Elixir 1.19.4 on the runner. The evidence that this is unnecessary is
in the repo: `elixir-unit-tests.yml` and `precommit-web-ng.yml` both build and test Elixir
with zero `setup-beam`. `build/mix_precommit.bzl:13` states it directly: the rule takes OTP
and Elixir from `@rules_elixir//:toolchain_type` as declared action inputs. Bazel supplies
the toolchain. Delete.

**3. Setup Rust (`main.yml`)**

Curl-installs rustup and a stable toolchain. Same evidence: `rust-tests.yml` and
`rust-musl.yml` build and test all of `//rust/...` with no rustup step. `@rules_rust`
supplies cargo and rustc. Delete.

**4. `ensure-forgejo-tools.sh service-build` (`main.yml`)**

Every other Bazel workflow uses the `bazel-build` profile. `service-build` adds `rpmbuild`,
`rpm2cpio` and `psql` on top of it. RPM tooling belongs in `release.yml`, not in a build
and test job. Downgrade to `bazel-build` at most.

Worth checking empirically whether even `bazel-build` is needed. It requires gcc, g++,
make, pkg-config, protoc, cmake, flex, bison, file, readelf and libpcap on the runner. Under
`--config=ci` every compile happens on the executor, and `remote_base` sets
`BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1`. The only local actions are `ExpandTemplate`,
`CopyDirectory` and `NpmPackageExtract`, none of which need a C compiler. Do not delete this
on reasoning alone. Run the master once without it and read the failure.

**5. `publish-oci.yml`**

Its own header says the push trigger was removed in 2026-06 and that signing always failed,
because the RBE build uses `--remote_download_minimal` so the image index metadata cosign
needs is never materialized locally. It is manual-dispatch only, broken, and redundant with
`bazel run //:push` in the master. Delete the file.

### Keep as workflow steps

These are load-bearing and genuinely cannot be Bazel actions. AGENTS.md permits exactly this
class of exception.

**6. Native add-on version bumps**

Needs a git range against the base branch, which no hermetic action can have.

Not redundant with Bazel, despite appearances. `//scripts:native_addon_version_bumps_test`
exists and sits inside `//build/native_addons:build_gates_test`, but reading
`scripts/BUILD.bazel:83-89` shows it is `test-native-addon-version-bumps.sh` invoked with
the checker passed as a `$(rootpath)` argument. It is a unit test of the checker's logic
against fixtures. It never looks at your actual diff. Both are wanted.

**7. Rust vendor snapshot (`check-rust-vendor-tracked.py`)**

Needs `git ls-files`, so it cannot be hermetic either.

This one guards a bug the repo already hit. `.gitignore:294-299` carries a
`!third_party/crates/**` un-ignore with a comment explaining that the vendor snapshot must
stay byte-complete "even when an upstream crate contains paths such as debug/, target/,
*.pem, or *.dll". Line 237 is a bare `target/`, which is exactly what was swallowing them.

A build does not subsume it. Bazel only compiles crates reachable from a built target's
dependency graph, and rustc never opens a vendored `*.pem` or test fixture. The check also
runs the other direction, flagging tracked files absent from the checksum manifests, which
catches a hand-edited vendor tree. It costs about two seconds. Keep it.

**8. SRQL fixture configuration and Docker auth**

Credential handling that must reach the bazel client's environment before the build starts.
This is the stated AGENTS.md carve-out.

**9. Socket Firewall install**

Runner-level network policy. Outside the sandbox by definition.

### Migrate to Bazel targets

**10. Gazelle drift — DONE**

Now `//:gazelle_diff_test`, a `gazelle_test` in the root `BUILD.bazel`. `scripts/check-gazelle-drift.sh`
and the `main.yml` step that ran it are gone, along with the `git fetch` of the base branch
that step needed. The whole repo is gated instead of only the Go directories a change touched.

The root cause of the old narrow scoping was not policy, it was that Gazelle was walking
`//third_party/crates` and erroring on vendored crates holding multiple proto packages. Three
exclusions fixed it: `third_party`, `proto/cri`, `proto/dgraph`, plus `google/protobuf`.

Applying the remaining drift was not cosmetic. Gazelle proposed four changes that would have
broken the build, and only one was caught by analysis. The rest needed a real compile:

1. Deleting `//proto/dgraph:proto_dgraph` while `rust_prost_library` still referenced it.
   Triggered by excluding only the nested `proto/dgraph/proto`, which orphaned the parent.
2. Generating a second `google.golang.org/protobuf/.../wrapperspb` in `google/protobuf`.
3. Collapsing `compilers` to `go_grpc_v2` alone in `//proto/profiler` and `//proto/rperf`.
   That emits the service stubs without the message types, so the package analyzes fine and
   fails at compile with `undefined: StartProfilingRequest`. Both now carry `# keep`.
4. Appending duplicate `go_test` rules embedding a `_lib` that does not exist, wherever a
   package's rule names use underscores but its directory name has a hyphen. Hit
   `go/cmd/tools/sshca-signer`, `go/cmd/tools/mapper-baseline` and `build/release`.

Standing rule that came out of it: in a hyphenated Go package, name rules the way Gazelle
does, from the directory. `sshca-signer_lib`, not `sshca_signer_lib`. Four packages already
did; two did not and broke.

Three packages are marked `# gazelle:ignore` because Gazelle cannot model them:
`build/release` (names from the source file, plus `data` deps it drops) and
`build/native_addons` (release gate, mostly py_test/sh_test/genquery/macros).
`go/pkg/models` keeps a `# keep` on its `srcs` glob.

Verified: drift is zero and stable across repeated runs, `//:gazelle_diff_test` passes,
`//go/...`, `//proto/...`, `//tools/...` and `//build/release:all` build, and the renamed
test targets pass.

**11. netprobe libpcap-free assertion — DONE**

Now `//rust/netprobe:static_linkage_test`. `scripts/ci/assert-netprobe-libpcap-free.sh` is
deleted, and `rust-musl.yml` lost its two-architecture matrix, its `Build` step and its
`Verify static linkage` step in favour of one `bazel test`.

The open question in the original note was real: a plain `//...` build does not produce a
musl artifact. `platform_transition_filegroup` from `@aspect_bazel_lib` answers it. The test
depends on the binary twice, once transitioned to each musl platform, so no `--platforms`
on the command line and no `bazel cquery --output=files | tail -n 1` to rediscover the path.

It is a `go_test`, not the `sh_test` this note predicted. The `sh_test` was written first
and failed on the executor with `file(1) is required to assert static linkage`: the RBE
image does not carry `file`, and `.bazelrc` deliberately withholds `PATH` from test actions,
so a test sees only `/bin:/usr/bin:/usr/local/bin`. Go's `debug/elf` is stdlib and
architecture-neutral, which removes the host-tool dependency and lets one test on an x86_64
executor check the aarch64 artifact too. `DT_NEEDED` is read as a list rather than grepped
out of `readelf` prose, and the check extends to `DT_RPATH`, `DT_RUNPATH` and `DT_SONAME`.

Verified both directions. Against the real musl artifacts both subtests pass. Pointed at the
glibc build it fails with exactly the expected findings: a `PT_INTERP` and five `DT_NEEDED`
entries (`libgcc_s`, `libm`, `libc`, `ld-linux-x86-64`, `libstdc++`).

`rust-musl.yml` is now a single `bazel test` and is a deletion candidate once the master
workflow lands, since the target rides `bazel test //...`. Confirmed it is selected by the
existing sweep query.

## Part 2: Workflow inventory

28 workflows.

### Replaced by the master (8)

| Workflow | Absorption note |
|---|---|
| `main.yml` | Test sweep absorbed. Guards 1-4 deleted, 6-9 kept as steps, 10 migrated. |
| `golang-tests.yml` | Plain run absorbed. The race and count=10 pass becomes its own job. |
| `rust-tests.yml` | Fully absorbed. |
| `elixir-unit-tests.yml` | Fully absorbed. **DELETED 2026-08-04** — the Bazel CI covers it, and its `paths:` triggers watched `third_party/patches/rules_{erlang,elixir}/**`, which no longer exist now that both rulesets are vendored. |
| `elixir-integration-sr-core.yml` | Becomes the integration job, chain unchanged. |
| `precommit-web-ng.yml` | Absorbed only if the master stops excluding `//elixir/web-ng:precommit`. |
| `rust-musl.yml` | Absorbed once the linkage assertion is an `sh_test`. |
| `publish-oci.yml` | Broken and redundant. Delete, see audit item 5. |

Plus `buildbuddy.yaml` and `.buildbuddy/workflows.yaml`, both duplicate paths.
`.buildbuddy/workflows.yaml` is already superseded by `release.yml`. Removing them also
removes `//build/buildbuddy:release_pipeline`.

### Kept: linters and static analysis (8)

`golangci-lint.yml`, `rust-lint.yml`, `web-ng-lint.yml`, `helm-lint.yml`,
`elixir-quality.yml`, `secret-scan.yml`, `tests-fingerprint-licensing.yml`,
`rust-audit.yml`.

They run fast and fail for their own reasons. Folding a formatting nit into a 30-minute job
makes it indistinguishable from a compile break.

### Kept: publish and release, tag-triggered (7)

`release.yml`, `native-addons.yml`, `wasm-plugins.yml`, `palisade-publish.yml`,
`external-wasm-plugin.yml`, `image-security.yml`, `source-security.yml`.

None fire on push or pull request. Different trigger, different lifecycle, no overlap.

### Kept: special hardware, scheduled, manual (5)

| Workflow | Why |
|---|---|
| `netprobe-ebpf-verifier.yml` | Needs the `netprobe-kernel-5.4` runner label. |
| `rust-tests-addon-interop.yml` | Cargo and go directly, no Bazel. Could become a target later. |
| `armis-dire-e2e.yml` | Weekly cron. |
| `banner-grab-large.yml` | Nightly. Its header says it is too slow to gate every PR. |
| `inspect-oidc.yml` | Manual debugging tool. |

## Part 3: Master workflow shape

New file: `.forgejo/workflows/ci-master.yml`. Trigger: `push` to `staging` and
`pull_request`. Runner: `ubuntu24`.

Five jobs, so that failures stay readable and the race pass runs in parallel.

```
guards                     fast, no bazel
   |
   +-- build_test          bazel build + unit tests
   |      |
   |      +-- integration  the six-step database chain
   |
   +-- go_race             race + count=10, concurrent with build_test
                |
   publish  <---+          staging pushes only
```

### Job: guards

No Bazel. Version bumps check, vendor snapshot check. Both need git, both take seconds.
Failing here skips everything downstream, which is the point.

### Job: build_test

Preamble: checkout preserving `third_party/bazel-repo-cache` and
`third_party/bazel-disk-cache` (copy the `git clean -ffdx -e ...` form from `main.yml`
exactly, an unqualified clean wipes both every run), Socket Firewall, bazelisk, write
`.bazelrc.remote`, Docker auth.

Then, every command with `-c opt --config=ci`:

1. `bazel run //:buildbuddy_setup_docker_auth`
2. `bazel build //...`
3. `bazel test //... --test_tag_filters=-integration_test,-acceptance_test`

Do not exclude `//elixir/web-ng:precommit`. That exclusion in `main.yml` is why
`precommit-web-ng.yml` exists separately.

### Job: go_race

Concurrent with build_test, not after it. Lifted from `golang-tests.yml`:

```
--@io_bazel_rules_go//go/config:pure=false
--@io_bazel_rules_go//go/config:race
--test_timeout=600
--flaky_test_attempts=1
--test_arg=-test.count=10
--test_arg=-test.short
--test_arg=-test.shuffle=on
```

This is a different configuration from the main sweep, so it shares no cached actions with
it. Running it concurrently costs executor slots, not wall clock. That is the right trade.

### Job: integration

Needs build_test. SRQL fixture configuration runs here. Every step takes
`--//build:enable_integration_tests` and `--test_tag_filters=`:

1. `bazel test //rust/integration-db:sweep_stale_dbs`
2. `bazel run //rust/integration-db:prepare_template --build_tag_filters=`
   (a binary, so the build filter, not the test filter)
3. `bazel test //elixir/serviceradar_core:migrate_template`, only if step 2 reported
   `needs_migration`
4. `bazel test //rust/integration-db:provision_db`
5. `bazel test //... --test_tag_filters=integration_test,-acceptance_test`
6. `bazel test //rust/integration-db:teardown_db` with `if: always()`

Three things that are easy to get wrong:

- `prepare_template` is required. The chain is documented at
  `rust/integration-db/BUILD.bazel:73`.
- `migrate_template` is conditional. Unconditional means 368 Ecto migrations every build.
- `teardown_db` needs `if: always()`. `build --keep_going` is set but a failing `bazel test`
  still exits non-zero, so under `set -e` teardown never runs and a database leaks on every
  red build. That leak is why `sweep_stale_dbs` exists.

### Job: publish

Staging pushes only, never pull requests. `bazel build //:images` then
`bazel run //:push`.

### Concurrency

The 8 integration shards share one CNPG fixture. The concurrency group in `main.yml` is
scoped per workflow per branch, so two open pull requests already run the chain
simultaneously, and a master with no path filters makes that worse. The integration job
needs a concurrency group keyed to the fixture, not the branch, so the chain serializes
across branches. Decide this before the first run.

## Part 4: Live bugs found during the audit

`--//build:enable_integration_tests` landed in `f14be4eba` on 2026-08-02. The last fix to
`elixir-integration-sr-core.yml` was `736c1b2b7` on 2026-07-31 and it never passes the flag.
Every fixture target is `@platforms//:incompatible` without it, so those six steps are
broken on `staging` right now, independent of this work.

`//elixir/web-ng:precommit` no longer exists — FIXED.

It was not renamed, it was withdrawn on purpose. `8fb020fb9` pulled `:precommit` and
`:precommit_check` because `mix format --check-formatted` fails against pre-existing HEEx
formatting and was blocking `//elixir/...` from going green. The header of
`elixir/web-ng/BUILD.bazel` says to restore it once the tree is formatted, and keeps
`//build:mix_deps.bzl` and `//build:mix_precommit.bzl` untouched for that.

Two things were broken by the withdrawal and are now repaired:

- `main.yml`'s Test step ended its target query with `except set(//elixir/web-ng:precommit)`.
  `set()` hard-errors on an unknown label rather than skipping it, so the query aborted with
  exit 7 and the step died through its own "refusing to run an empty test sweep" guard. **No
  tests ran at all.** The clause is removed; the query now resolves 134 targets.
- `precommit-web-ng.yml` is deleted. Its only substantive step was
  `bazel test //elixir/web-ng:precommit`, so every run exited 1. Everything else in it was
  preamble.

Both removals are recorded in the restoration note at the top of `elixir/web-ng/BUILD.bazel`,
so whoever formats the tree brings back the target, the workflow and the exclusion together —
or decides deliberately that the separate red X is not worth a workflow.

This is the third live bug of its kind, and they share a shape: a target moves or goes away,
and a `set()` or an explicit label in a workflow keeps naming it. The master workflow should
prefer tag- and wildcard-based selection over `set()` for exactly this reason.

Two stale comments to correct while the files are open. The `NOTE:` in
`rust/integration-db/BUILD.bazel` says `prepare_template` does not exist as a target; it
does, as a `rust_binary` a few lines below. And the `main.yml` test step attributes
integration tests to `rust-tests-integration.yml`, a file that does not exist.

`tools/go/derive_agent_release_public_key` is invoked as raw `go run` from `release.yml:317`
(and `publish-oci.yml:160`, which is slated for deletion). Gazelle has now given it a BUILD
file, so `release.yml` can `bazel run //tools/go/derive_agent_release_public_key` instead,
which removes one more reason for the runner to carry a Go toolchain. Separately,
`tools/go/gen_agent_release_key.go` is referenced nowhere in the repo and is a deletion
candidate; Gazelle currently generates `//tools/go:go` for it, which is a poor target name
that would disappear along with the file.

## Part 5: Removing `test.env-secrets`

### Scope

Small. One `exec_properties` block at `elixir/serviceradar_core/BUILD.bazel:376-378`,
covering 3 variables. It sits in a comprehension over `integration_shard_names()`, and
`INTEGRATION_SHARD_COUNT = 8`, so 8 targets: `integration_tests_s0` through `s7`. A repo-wide
grep finds one live use; every other hit is a comment explaining why some other target
deliberately does not set it.

### Why the replacement already works

Three things are in place. `.bazelrc:114-116` already declares all three as `--test_env`.
`main.yml` already passes those exact three explicitly on its sweep, so the mechanism is
proven in this repo on this backend. And the runner already holds the values, from
`configure-srql-fixture.sh`.

The gap: `main.yml` excludes `integration_test` targets, so the fallback has never run on
these 8 shards. That is what the rehearsal is for.

### Costs

The DSN including password enters the action cache key for those 8 targets, so a password
rotation invalidates their cached results. The value becomes visible in action details.
Changing `exec_properties` changes the platform, so the 8 targets rebuild once.

If either of the first two is unacceptable, pass the credential as a file path and let the
test open it. The Rust side already works that way.

### Verdict — DONE

Removed. The `exec_properties` block is gone from all 8 shards, confirmed by querying each
one. Nothing else in the repo sets `env-secrets`.

Two cross-referencing comments were rewritten rather than left to rot, since both explained
why some OTHER target deliberately did not set the property: the `migrate_template` note in
`elixir/serviceradar_core/BUILD.bazel` and the lifecycle-target note in
`rust/integration-db/BUILD.bazel`. Both now describe the single mechanism that remains, the
`test --test_env=` list in `.bazelrc` lines 112-114.

Nothing about execution changed. The shards still run remotely: they carry no
`no-remote-exec`, and the PEM-content form of the fixture CA is what made that possible.

**Verified:** the three `--test_env` entries are present, no shard carries `exec_properties`,
and `//elixir/serviceradar_core:integration_tests_s0` builds under
`--//build:enable_integration_tests` (267 actions).

**Not verified, and it needs to be:** the shards have not been RUN since the change. That
takes the shared CNPG fixture and the full lifecycle chain, which is destructive against a
resource concurrent PRs share, so it is not something to do unilaterally from a workstation.
The first CI run of the integration chain is the real proof that the credentials arrive by
`--test_env`. Watch that run before treating this as settled.

## Part 6: Execution order

Delete workflows last. A broken master with the old workflows already gone leaves no CI.

1. Remove `test.env-secrets`. Small, reversible, makes the config backend-agnostic.
2. Delete audit items 1-4 from `main.yml` (version assertion, Setup Beam, Setup Rust,
   `service-build`). Do this in the existing `main.yml` first. If the sweep stays green
   without them, the finding is proven before the master depends on it.
3. Make audit item 11 an `sh_test`. Confirm `rust-musl.yml` is then redundant.
4. Fix repo-wide Gazelle drift, add `gazelle_diff`, delete `check-gazelle-drift.sh`.
   Independent of everything else, and can slip.
5. Add `ci-master.yml` alongside the existing workflows. Both run. Direct comparison plus a
   fallback.
6. Let it settle. Use the BuildBuddy invocation UI to debug the sequence.
7. Delete the 8 replaced workflows plus `buildbuddy.yaml` and `.buildbuddy/workflows.yaml`.
8. Only then repoint `--remote_executor`, `--remote_cache` and `--bes_backend` at
   NativeLink, as a separate commit.

Steps 1-7 and step 8 stay apart on purpose. Two variables, changed one at a time.

Step 2 is worth doing early on its own merits. It removes an OTP install, an Elixir install,
a rustup bootstrap and an apt install from every CI run, for a build that gets all of those
from Bazel.

## Part 7: What the rehearsal proves, and what it cannot

Validated against BuildBuddy:

- Command sequence and ordering
- `--//build:enable_integration_tests` correctness
- `prepare_template`, conditional migrate, `always()` teardown
- The `--test_env` credential fallback on all 8 shards
- Docker auth, `//:images`, `//:push`
- Tag filter target selection

Must be re-tested after the NativeLink cutover:

- Auth: API key header becomes an mTLS client cert
- `container-image` stops being an image pull and becomes a routing label
- `EstimatedCPU` and `EstimatedMemory` become `cpu_count` and `memory_kb`
- Worker pool routing between the Ubuntu and EL9 images

One thing resolves itself. The sequence filters `-acceptance_test` everywhere, so the dgraph
Firecracker suite never enters this workflow. The isolation blocker and the CI consolidation
do not intersect, and neither waits for the other.
