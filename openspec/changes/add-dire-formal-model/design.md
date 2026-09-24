# Design: a formal model of the DIRE device lifecycle

## Context

DIRE is spread across `elixir/serviceradar_core/lib/serviceradar/inventory/identity/`
(`merge_engine.ex`, `resolver.ex`, `batch_resolver.ex`, `registrar.ex`, `alias_guard.ex`,
`duplicate_sweep.ex`, `fence.ex`), the `Device` resource's lifecycle actions, the raw
upsert in `inventory/sync/device_writes.ex`, the sweep processors, and the alias state
machine in `identity/device_alias_state.ex`. Lifecycle state is not held in one place:

- A tombstone is `deleted_at`/`deleted_by`/`deleted_reason` on `ocsf_devices`.
- There is no merged-into column. "Where did this uid go" is derived from `merge_audit`: the
  latest row for `from_device_id` whose reason is not `unmerge`.
- `identity_revision` is bumped by `BumpIdentityRevision` and by raw SQL at a handful of
  remediation sites.
- Identifier ownership is `device_identifiers`, unique on
  `(identifier_type, identifier_value, partition)`.
- Provisional devices are a metadata marker, not a column.

Several writers can clear a tombstone, and they disagree about whether that bumps the
revision. That is the kind of property a model checker is for.

## Goals

- A bounded TLA+ model of the lifecycle that TLC checks in about one to two minutes.
- Each known defect is an executable, isolated counterexample.
- The intended design (no defects) is checked before any fix is written.
- The model is tied to the Elixir code by validating traces the real code produces, so a
  code change that the model does not reflect fails a test.
- Everything runs as Bazel tests; no scripts.

## Decisions

### D1. Model the code as it is, not as intended

A model of the intended design passes and teaches nothing. Each action is written from the
code path it names, including its defects, and cites the function (for example
`CommitWork` -> `DeviceWrites` `on_conflict`). Reviewers check the model against the source
action by action.

### D2. Known defects are switches

`CONSTANT Bugs` is a subset of:

| Switch | Code path | Invariant it violates |
|---|---|---|
| `upsert_revives_merged` | `DeviceWrites` `on_conflict` clears the tombstone, no bump | `NoZombieRevival`, `RevivalBumpsRevision` |
| `gateway_sync_no_bump` | `Device` `:gateway_sync` clears the tombstone, no bump | `RevivalBumpsRevision` |
| `follow_stale_audit` | `Resolver.do_follow_canonical/3` ignores `deleted_reason` | `NoStaleRedirect` |
| `sweep_restores_merged` | sweep `restore_eligible?/1` ignores `deleted_reason` | `NoZombieRevival` |
| `fence_observe_only` | `Fence.pin/2` has no production callers | `NoStaleCommit` |

Each action takes its defective branch only when its switch is in `Bugs`. The set grows
only when TLC produces a counterexample that is then confirmed in the code (see D7).

### D3. Three kinds of configuration

- `current.cfg`: `Bugs` = every known switch. Checks the invariants that hold for today's
  code. `expect = pass`.
- `witness_<switch>.cfg`: `Bugs = {<switch>}`. `expect = violation:<Invariant>`, naming one
  invariant. Isolating each switch means fixing one defect flips exactly one witness.
- `fixed.cfg`: `Bugs = {}`. Every invariant. `expect = pass`. If the intended design itself
  violates an invariant, a model says so before a fix built on it ships.

### D4. The model

Bounds: three device uids, three identifiers, two IPs, a clock of a few ticks (the merge
cooldown window is one tick), at most four `merge_audit` rows, at most two in-flight work
items. These are model constants in the `.cfg` files. Merge wars and zombie revivals need
two or three devices, so small bounds lose nothing that matters here.

State:

- `status[u]` in {absent, live, tomb, purged}; `tombReason[u]` in {merged, other}
- `rev[u]`: `identity_revision`
- `owner[i]`: owning uid or none; a function because of the unique index
- `audit`: sequence of `[from, to, kind, ids]`, where `ids` is what the code actually stores
  in `details.identifiers` (both sides' matches for conflict merges; nothing usable for
  Registrar merges, which store a map)
- `ipOf[u]`, `alias[ip, u]` in {none, detected, confirmed, stale}
- `work`: in-flight items `[uid, pinnedRev, target]`
- `clock`

Actions, each citing its source:

- `StartWork(u)` / `CommitWork(w)`: resolve through `follow_canonical`, then later upsert
  through the `DeviceWrites` `on_conflict`. Splitting resolve from write is what lets TLC
  interleave a merge between them; it covers BatchResolver's phase ordering and the
  observe-only fence.
- `Merge(from, to, reason)`: `MergeEngine.merge_devices/3` with guards in the code's order
  (manual/unmerge bypass, distinct agent identity, source authority, provisional topology,
  pair cooldown), then MergePolicy where the calling path applies it. Moves identifiers,
  appends the audit row, tombstones the source (bump), bumps the survivor.
- `Unmerge(from)`: `MergeEngine.unmerge_device/2`. Latest non-unmerge audit row; restores the
  source (bump); moves back identifiers whose `{type, value}` appears in the stored `ids`.
- `SoftDelete(u)`, `SweepRestore(ip)`, `GatewaySync(u)`, `Purge(u)`: the remaining tombstone
  writers and revival paths with their real bump behavior. `Purge` models
  `DeviceCleanupWorker`: the row and its identifiers go; `merge_audit` rows stay.
- `AliasSighting`, `AliasConfirm`, `AliasInvalidate`, `AliasReactivate`, `AliasMerge`: the
  `DeviceAliasState` machine and `AliasGuard.maybe_merge_ip_alias_device/3`. Reactivating a
  stale alias is intended behavior, not a defect.
- `Tick`: advances the clock so the cooldown can expire.

Invariants:

- State: `TypeOK`, `MergedNeverOwnsIdentifiers`, `MergeGraphAcyclic`,
  `MergedRedirectsSomewhere` (a merged-away uid resolves to a different uid),
  `NoStaleRedirect` (a device tombstoned for a non-merge reason resolves to itself).
- Action properties, checked as `[][A => B]_vars`: `NoZombieRevival` (a merged-away device
  becomes live only through `Unmerge`), `RevivalBumpsRevision`, `NoPurgedResurrection`,
  `UnmergeRestoresExactly`, `NoStaleCommit` (no commit lands when the pinned revision has
  changed).

### D5. Assumptions (Lean candidates)

These are abstract predicates in the model, not proven:

- `MergePolicy.merge_allowed_for_matches?/1`: which evidence sets permit a merge.
- MAC normalization and locally-administered classification (`Identity.Mac`).
- Canonical survivor selection (`DuplicateSweep.choose_canonical_device_id/2`).
- Duplicate-component grouping (`DuplicateSweep.classify_duplicate_components/1`).

The model lets TLC choose any outcome these predicates permit. If a counterexample depends on
one of them, that function is the first candidate for a Lean 4 proof. Until then they are
covered by property tests against the Elixir functions, not by this change.

### D6. Bazel wiring

- `tla2tools.jar` is an `http_file` in `MODULE.bazel` with a pinned sha256.
- `rules_java` supplies the remote JDK; `java_binary(name = "tlc", main_class = "tlc2.TLC")`
  gives a TLC that does not depend on the host Java, on RBE or under `TestRunner=local`.
- `//build/tla:tlc.bzl` defines
  `tlc_test(name, spec, cfg, deps, expect = "pass" | "violation:<Property>")`, backed by a
  `py_test` driver. The driver decides on TLC's exit status and on the name of the violated
  property, parsed from the exact line TLC prints (copied from a real run, not guessed).
  `expect = "violation:X"` fails if TLC passes and fails if TLC reports a different
  property.
- A self-test spec under `//build/tla/selftest` has one passing and one deliberately
  violating configuration, proving the driver can fail in both directions before anything
  depends on it.

### D7. Trace validation

A model the code can drift away from verifies nothing. Trace validation is the coupling.

- `test/support/dire_trace.ex` records, after each step a test drives, a projection of the
  identity state: tombstone columns, `identity_revision`, identifier owners, `merge_audit`
  rows, alias states. Real uids and identifiers are mapped to model constants (`d1`, `i1`,
  ...) in first-seen order. Each step also records which action was performed.
- The recorder writes the trace as a generated TLA+ module (a sequence of state records).
  `TraceCheck.tla` requires each consecutive pair to be one step of `DireLifecycle`'s next
  state relation, taken by the named action. The test runs `:tlc` from runfiles and fails
  when the trace is not a behavior of the model. No JSON module or community-modules jar is
  needed.
- One witness trace test per switch drives that defect's scenario on the real database and
  validates against `current.cfg`, plus one ordinary-lifecycle trace. While the defect exists
  the trace matches. When someone fixes the code, the trace no longer matches the buggy
  model, the trace test fails, and the author turns the switch off, which fails the witness
  config until the invariant is promoted into the must-pass set.
- A recorder self-test feeds a hand-corrupted trace (a revival without a revision bump under
  `fixed` rules) and asserts TLC rejects it.
- These are `:integration` tests on the shared srql-fixtures CNPG, run through the existing
  sweep, provision_base, migrate_run, provision lanes, test, teardown lifecycle with
  `TestRunner=local` (RBE executors cannot resolve the fixture host). `:tlc` and the model
  files join the core integration runtime data. Each new test file gets a DB-backed row in
  `test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` and in `build/integration_test_dispositions.bzl`.
- Every trace is synthetic: invented uids, `192.0.2.0/24` addresses, `00:00:5e:00:53:xx`
  MACs. Nothing is captured from a running deployment.

### D8. Delivery

Three pull requests, each on a fresh branch from `origin/staging` after the previous one
merges, each through the `no-mistakes` pipeline:

1. This change, the TLC toolchain, `tlc_test` and its self-test.
2. `formal/dire/`: the model and its `current`, `witness_*` and `fixed` configurations.
3. The trace recorder and witness integration tests.

GitHub issues for confirmed defects are filed after PR 2 lands, each citing its witness
configuration and counterexample.

## Risks and trade-offs

- **The model can be wrong about the code.** Mitigated by citing a function per action, by
  review against the source, and by trace validation, which fails when they disagree.
- **Bounds hide deep bugs.** Accepted. Every defect listed above needs at most three devices.
  Bounds are constants and can be raised for an occasional deeper local run.
- **TLC runtime creep.** The model is sized to one to two minutes per configuration; a
  configuration that outgrows the budget is split or given symmetry reduction, not
  left slow in `make test`.
- **A JVM enters the build.** TLC runs only on the JVM. The JDK is Bazel-hermetic and
  used only by these test targets.
- **Unconfirmed candidates.** A code read also suggests: BatchResolver phase 3 merging after
  the phase 2 canonical map, so a same-batch upsert revives the merged uid; unmerge matching
  identifiers on `{type, value}` alone, so it can move the survivor's own identifiers; and a
  purged merged tombstone being re-created as a new device. These are modeled faithfully
  but become switches only once TLC produces a counterexample that is confirmed in the code.
