# Add a formal model of the DIRE device lifecycle

## Why

DIRE (the Device Identity and Reconciliation Engine) decides when two device records are the
same thing, merges them, tombstones the loser, and resolves stale uids to the survivor. Its
worst failures have not been wrong arithmetic. They have been interleavings and lifecycle
transitions that no single test composes: an IP-alias merge war, a soft-deleted device a
sweep revived twice (the revival also erased the tombstone's `deleted_reason`), in-flight work
landing on a uid a merge had already retired, and a scan that reversed a merge.

Example-based tests check the orderings someone thought of. Reading the current code with a
state machine in mind turns up five defects or gaps that none of the existing integration
tests reach, each verified against the source:

- `Inventory.Sync.DeviceWrites` upserts with `conflict_target: [:uid]` and an `on_conflict`
  that sets `deleted_at`, `deleted_by` and `deleted_reason` to NULL unconditionally and does
  not bump `identity_revision`. Any upsert of a merged-away uid revives it.
- `Device` action `:gateway_sync` clears the tombstone without `BumpIdentityRevision`, while
  its mirror `:restore` bumps.
- `Resolver.do_follow_canonical/3` follows the latest non-unmerge `merge_audit` row for any
  tombstoned device, whatever `deleted_reason` says. After an unmerge, a later unrelated
  deletion of the former source redirects it to its former survivor.
- The sweep processor's `restore_eligible?/1` checks only `discovery_sources`, never
  `deleted_reason`, so a sweep can restore a device that was merged away.
- `Identity.Fence.pin/2` and `with_pinned_identity/3` have no production callers; every fence
  site is observe-only (`add-device-identity-fence` task 4.5 is open).

These are exactly the defects a model checker finds mechanically. TLA+ with TLC enumerates
every interleaving of a small bounded model and returns a concrete counterexample trace,
without proof effort.

## What Changes

- Add a TLA+ model of the DIRE lifecycle, `formal/dire/DireLifecycle.tla`, written from the
  code as it is today. Every action names the Elixir function it models.
- Encode each known defect as a switch in a `Bugs` constant, and check three kinds of TLC
  configuration: `current` (every known defect on; must-pass invariants hold), one
  `witness_<bug>` per defect (only that defect on; TLC MUST find the named violation), and
  `fixed` (no defects; every invariant holds, which checks the intended design before anyone
  writes a fix).
- Add hermetic TLC to the Bazel build: a pinned `tla2tools.jar`, the `rules_java` remote JDK,
  a `:tlc` binary, and a `tlc_test` macro whose `expect` is `pass` or `violation:<Property>`.
  All model checks are ordinary tests under `//...`, so `make test` blocks on them.
- Add trace validation: `:integration` tests on the shared srql-fixtures CNPG drive real
  merges, tombstones, revivals and alias transitions, record a projection of the identity
  state after each step, and run TLC to check the recorded sequence is a behavior of the
  model. This is what couples the model to the Elixir code: fixing a defect changes the real
  trace, the trace test fails against the still-buggy model, and the author must turn the
  switch off and promote the invariant.

No production code changes in this change. Each defect the model confirms is fixed in its
own follow-up, which carries the witness-to-must-pass flip.

## Non-goals

- Lean 4 proofs. The pure decision functions (`MergePolicy`, MAC classification, canonical
  survivor selection, duplicate-component grouping) are modeled as abstract predicates and
  listed in `design.md` as explicit assumptions; they are the candidates for a later Lean
  phase if a counterexample turns on one of them.
- Liveness properties (for example "no merge flapping"). Phase 1 checks safety only.
- Fixing any of the defects above.

## Impact

- Affected specs: new capability `dire-formal-model`.
- New code: `formal/dire/`, `build/tla/`, `elixir/serviceradar_core/test/support/dire_trace.ex`,
  new `:integration` witness tests.
- Build: new `rules_java` dependency and a pinned `tla2tools.jar` `http_file` in
  `MODULE.bazel`; `:tlc` and the model files added to the core integration runtime data;
  disposition rows for the new test files.
- Related changes: `add-device-identity-fence` (the `NoStaleCommit` witness flips when its
  enforcement task lands), `refactor-device-identity-reconciliation`.
