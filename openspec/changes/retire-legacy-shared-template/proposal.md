# Change: Retire the legacy shared template lifecycle

## Why

PR #4306 (merged 2026-09-05, change `isolate-ci-schema-templates`) moved every CI database
lifecycle to immutable, content-addressed template generations named `sr_tpl_<48 hex>`
(`rust/integration-db/src/generation.rs`). The old mutable singleton, `sr_core_template`, is now a
frozen rollback artifact: no BuildBuddy action migrates or clones it, and
`build/contracts/ci_heavy_gate_contract_test.py` forbids any workflow from naming its writers.

The code that built and ratcheted it is still in the tree. It is dead in CI but not harmless:

- `//rust/integration-db:provision_base` still runs `ensure_template`, which CREATES
  `sr_core_template` when it is absent and clones from it when present. Developer runbooks still
  point at it, so a workstation can still read and recreate the singleton.
- The trunk-only authority flag `//build:template_authority`, its marker rule and the
  Rust/Elixir consumers exist only to gate writes nothing performs.
- Every protected-name list and the Elixir test database guard carry special cases for the name.
- The singleton holds 451 migration versions (max `20260904120000`) against 500 on disk. It is
  49 migrations behind trunk, so it is no longer a fast rollback: reviving it costs a large
  replay either way.

Two lifecycle families in one fixture are exactly what the generation change set out to remove.
This change deletes the legacy family and then, as a separate approved step, the database.

## What Changes

- **BREAKING (developer workflow)**: delete the legacy lifecycle targets and their sources:
  - `//elixir/serviceradar_core:migrate_template` and `:migrate_run`, plus
    `test/db/migrate_db_test.exs` and `test/db/template_env.exs`;
  - `//rust/integration-db:prepare_template`, `:reset_template`, `:provision_base`,
    `:provision_db`, `:provision_db_large_ingestion` and the per-lane `:provision_db_<lane>`
    targets, plus `src/bin/{prepare_template,reset_template,provision_base}.rs`,
    `tests/provision_db_test.rs` and `src/template.rs`.
- Add focused per-lane generation clone targets (`provision_generation_<lane>`) so the one-lane
  developer loop the deleted `provision_db_<lane>` targets served keeps working, on generations.
- Delete `//build:template_authority`, `//build:template_authority_file`,
  `build/template_authority.bzl`, `require_template_authority` / `is_template_authority` and the
  marker constants in `rust/integration-db/src/lib.rs`, and `TEMPLATE_WRITE_DATA`.
- Make the Elixir test database guard admit only a manifest-selected `sr_tpl_<48 hex>` generation
  for template lifecycle access, and reject `sr_core_template` in every mode.
- Replace the contract tests that guard the authority flag with one contract that fails if any
  retired target, the flag, or a retired source file reappears in BUILD files or workflows.
- Keep `sr_core_template` in every protected-name list (Rust sweep, Go reaper, scratch-reaper SQL
  and ConfigMap, gitops CronJob copies) until the database has been dropped and the drop verified.
  Removing the name first would let the age-based sweeps drop it without approval.
- As a final, separate, explicitly user-approved operational step: `DROP DATABASE
  sr_core_template` on the `srql-fixtures` cluster, re-verify, and only then remove the name from
  the protected lists.

## Relationship to other changes

- `isolate-ci-schema-templates` is complete (all tasks checked) and is **not** superseded. Its
  design deferred this work on purpose ("do not automatically delete or migrate the old template
  during transition"). Archive it first in its own PR; this change builds on the capability it
  creates and adds requirements only, so neither archive rewrites the other.
- `parallelize-core-integration-tests` (pending) carries requirement text naming
  `provision_db`, `provision_db_large_ingestion` and an `sr_core_template` carve-out in the
  test-database guard. Those deltas must be reconciled before either change archives (tasks 2.10
  and 2.11), so that archiving it does not replay retired target names into `specs/`.
- `route-bazel-cache-through-shared-edge` (complete, unarchived) has a scenario naming
  `provision_db_s0`..`s7`; it is already stale (lanes are `async`/`serial_N`) and is flagged to
  its owner rather than edited here.

## Impact

- Affected capability: `integration-test-execution` (ADDED requirements only).
- Affected code: `rust/integration-db` (BUILD, `src/lib.rs`, `src/template.rs`, `src/bin/*`,
  `tests/provision_db_test.rs`, `src/config/mod.rs` comment), `elixir/serviceradar_core`
  (BUILD, `config/test_database_guard.exs`, `test/db/*`), `build/BUILD.bazel`,
  `build/template_authority.bzl`, `build/contracts/*`, and later `go/pkg/srqlfixture/reaper`,
  `k8s/srql-fixtures/scratch-reaper.{sql,yaml}` plus the gitops CronJob copies.
- Docs that describe the legacy lifecycle as current are updated by the concurrent docs rewrite,
  not by this change: `AGENTS.md` (hard rule and SRQL fixture section), `docs/agent-runbooks.md`,
  `elixir/README.md`, `rust/integration-db/README.md`, `config/README.md`,
  `k8s/srql-fixtures/README.md`, `.agents/skills/srql-fixtures-db-tests/SKILL.md`.
- Manifest identity: several deleted files are declared schema-template inputs, so the first CI
  run after each code phase cold-builds one new generation. That is expected and bounded by
  `cleanup_generations` retention.
- No application schema, production database, or deployed service is touched. The only fixture
  mutation is the approved drop of one frozen development database.
