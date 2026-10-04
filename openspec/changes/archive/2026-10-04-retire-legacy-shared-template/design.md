## Context

The fixture has two template families. Generations (`sr_tpl_<48 hex>`, registry in
`sr_template_registry` on the `postgres` database) serve every BuildBuddy action:
`cleanup_generations -> prepare_generation -> [migrate_generation] -> prepare_generation ->
provision_generation[_large_ingestion] -> suite -> release_generation -> teardown_db`.
The singleton family serves no CI action, but its code still runs when invoked by hand:

| Legacy piece | What it still does | CI callers |
| --- | --- | --- |
| `//rust/integration-db:provision_base` | `ensure_template` creates `sr_core_template` if absent, clones it into `sr_core_test_<run>` if usable | none |
| `//elixir/serviceradar_core:migrate_run` | migrates the run base made by `provision_base` | none |
| `//rust/integration-db:provision_db`, `:provision_db_large_ingestion`, `:provision_db_<lane>` | clone lanes from that run base | none |
| `//rust/integration-db:prepare_template` | creates/checks the singleton; needs the authority flag | none |
| `//elixir/serviceradar_core:migrate_template` | ratchets the singleton; needs the authority flag | none |
| `//rust/integration-db:reset_template` | drops the singleton; needs the authority flag | none |
| `//build:template_authority` and marker rule | gates the three writers above | none pass it |

Callers were confirmed by searching `buildbuddy.yaml`, `.github/`, `Makefile`, `*.bzl` and
`.bazelrc`: the only references are the contract test that forbids them, source comments, the
`MISSING_RUN_ID` help text in `rust/integration-db/src/lib.rs`, and documentation.

## Goals / Non-Goals

- Goals: one template lifecycle in code; no path that can create, migrate, clone or reset the
  singleton; keep the one-lane developer loop; drop the database only with explicit approval and
  only after nothing can recreate it.
- Non-Goals: changing generation semantics, registry schema, retention policy, the ordinary
  teardown/sweep for `sr_core_test_*`, or rewriting docs (owned by the separate docs PR on branch
  `docs/ci-schema-generation-lifecycle`).

## Decisions

### Delete the run-base family too, not only the three writers

`provision_base`, `migrate_run` and `provision_db*` never write the singleton's migration set,
but `provision_base` creates the singleton when absent and reads it when present. Leaving it
would mean the database could reappear after the drop, from a workstation, with nothing in CI
noticing. `provision_db*` only clones the run base `provision_base` makes, so it is dead once
`provision_base` is gone. `src/template.rs` then has no consumer (`generation.rs` imports only
`lib.rs` helpers), so it goes too. Any `lib.rs` helper left without a caller by its removal is
deleted rather than silenced with `#[allow(dead_code)]`; `cargo clippy` on the crate decides.

### Replace focused `provision_db_<lane>` with `provision_generation_<lane>`

The pending `route-bazel-cache-through-shared-edge` scenario and the runbooks promise a
one-lane clone for focused local runs. `src/bin/generation.rs` already clones whatever
`SERVICERADAR_TEST_DB_SHARDS` names, so the replacement is one more entry per lane in the existing
`rust_binary` comprehension, generated from `integration_lane_names()`. Alternative considered:
tell developers to use `provision_generation` (all eight lanes). Rejected: it touches seven
databases the run never uses, which is what the focused targets were added to stop.

### Delete the authority flag outright

With no writer left there is nothing for `//build:template_authority` to authorize. Keeping a
flag that grants nothing invites someone to add a consumer. Remove the flag, the marker rule,
`build/template_authority.bzl`, the Rust marker constants and functions and their tests, the
`TEMPLATE_WRITE_DATA` list, and the `data = TEMPLATE_WRITE_DATA` on
`serviceradar_integration_db_test`.

### Replace the contract test, do not just delete it

Today's guard (`test_no_active_workflow_may_write_the_shared_template`, the authority-flag
test, `test_the_benchmark_never_writes_the_shared_template`,
`assert_shared_template_is_never_written`) reads `template_env.exs` and
`template_authority.bzl`, so it fails once they are deleted, and "no caller grants the flag"
means nothing once the flag is gone. Keeping a negative guard is still worth it: the failure it
prevents (a branch ratcheting shared state every other branch clones) was silent and fleet-wide.
The replacement contract:

- keeps a `retired_legacy_targets` tuple and asserts none is defined in
  `rust/integration-db/BUILD.bazel` or `elixir/serviceradar_core/BUILD.bazel` and none is named
  by any `buildbuddy.yaml` action or `.github` workflow;
- asserts `build/BUILD.bazel` defines no `template_authority` target and that
  `build/template_authority.bzl`, `test/db/template_env.exs`, `test/db/migrate_db_test.exs` and
  `rust/integration-db/src/template.rs` do not exist;
- keeps the existing positive generation-count assertions for each action.

It must be shown to fail: temporarily re-add one retired `name = "..."` block locally and confirm
the contract goes red before relying on it.

### Guard: generations only

`TestDatabaseGuard.authorize_template_lifecycle!/1` loses its `"sr_core_template"` default and
accepts only `~r/\Asr_tpl_[0-9a-f]{48}\z/`; the `disposable_database?("sr_core_template", true)`
clause is removed so the name falls through to the ordinary disposable-name check and is
rejected. The existing guard test that authorizes the singleton becomes a test that it is
rejected with and without `template_lifecycle?: true`.

### Keep the name protected until after the drop

`rust/integration-db` `sweep_stale` (run by every CI lifecycle), the Go reaper and the hourly
scratch-reaper CronJob all drop any unprotected, non-`sr_tpl_` database older than six hours, with
`FORCE`. `sr_core_template` is weeks old. Removing it from the protected lists in the code phase
would therefore drop it within one CI run, without the approval this change requires. The name
stays protected, in all mirrors (enforced by `reaper_test.go` and
`k8s/srql-fixtures/tests/scratch_reaper_contract_test.py`), until the drop is done and verified.

### The drop is a manual, approved, one-off statement

No Bazel target is added for it: a target that drops a shared fixture database is exactly the
kind of write path this change removes, and it would run once. The operator (the user) issues it
through the fixture's admin access after the pre-checks in tasks section 4, and records the
before/after evidence on the PR or tracking issue. This is not a repository script.

## Risks / Trade-offs

- Losing the documented rollback. The singleton was the rollback target for reverting callers to
  the legacy lifecycle. It is 49 migrations stale, and the legacy lifecycle recreates an absent
  singleton from nothing (`ensure_template` plus a full `migrate_template` replay; that is what
  `reset_template` relied on). So after the drop the rollback still works if the code is reverted;
  it costs one cold replay, which it would largely cost anyway. Mitigation: the drop is a separate
  approved step that can be declined indefinitely at no cost beyond disk.
- Stale branches. A branch cut before PR #4306 still names `provision_base` in its own
  `buildbuddy.yaml`; if such a branch's workflow ran after the drop it could recreate an empty
  singleton. Mitigation: pre-check open PRs before the drop, and re-query after the next CI runs.
- Manifest churn. The deleted Elixir helpers and the edited `rust/integration-db` BUILD/lib.rs
  are declared schema-template inputs, so each code phase cold-builds one generation on its first
  CI run. Accepted; retention cleanup reclaims the superseded generation.
- Pending-delta drift. `parallelize-core-integration-tests` names retired targets in requirement
  text. Mitigation: reconcile it in the same implementation PR (tasks 2.10-2.11).

## Migration Plan

1. Prerequisite: archive `isolate-ci-schema-templates` in its own PR.
2. Code phase (one PR): delete the legacy targets, sources, flag and guard special cases; add
   `provision_generation_<lane>`; replace the contract; reconcile pending deltas. Protected lists
   unchanged.
3. Verify: `make test`, contract tests, PR BazelCI green; after merge, `LargeIngestionGate` on
   staging green; confirm no client backend connects to `sr_core_template` during those runs.
4. Approval gate: ask the user. If declined, stop here; the frozen database stays protected.
5. Drop phase (user-run): pre-checks, `DROP DATABASE sr_core_template WITH (FORCE)`, re-query
   immediately and after the next BazelCI and `LargeIngestionGate` lifecycle and reaper pass.
6. Cleanup phase (one PR plus gitops PR): remove the name from all protected lists and mirrors.

Rollback:

- Code phase: `git revert` the PR. The frozen singleton is still present and protected, so the
  restored legacy targets work as before.
- Drop phase: no restore. Reverting the code phase and running the legacy trunk lifecycle
  rebuilds the singleton by full replay.
- Cleanup phase: `git revert`; re-adding a protection for an absent name is harmless.

## Open Questions

- Should the drop be preceded by a schema-only dump kept outside the repository? It has little
  value (the schema is reproducible from any migration set), so this proposal does not require
  one; the user may ask for it at the approval gate.
