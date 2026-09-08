## 1. Establish the mechanism (#4151)

- [x] 1.1 Read the mechanism out of source rather than reproducing blind. `migration_source`
      (web-ng config), `do_lock_for_migrations` (ecto_sql postgres.ex) and the `Task.async` in
      `async_migrate_maybe_in_transaction` (ecto_sql migrator.ex) compose into the stall. The
      full chain is recorded hop by hop in `findings.md` E1-E3. This replaced the planned
      "database at exactly 20260125090000" replay, which was a way to *discover* the mechanism;
      reading it was cheaper and gave a stronger answer.
- [x] 1.2 Write the concurrent observer polling `pg_locks` joined to `pg_stat_activity`, with a
      sample counter so the artefact can be gated on.
- [x] 1.3 Positive control: reproduce the lock topology with plain `psql` and confirm the
      observer detects it (`findings.md` E4). This validates the instrument -- a null result
      from an observer that cannot see contention is not evidence.
- [x] 1.4 Confirm the two-connection step live, with an explicit PASS/FAIL branch per claim
      (`findings.md` E5). C1: `Task.async` used a different backend pid. C2: the move waited the
      full 15,000 ms `lock_timeout` (`db=15035.1ms`) and was cancelled `55P03`.
- [x] 1.5 Record the outcome in `findings.md`, including what remains un-measured (the
      `MIX_ENV=dev` secondary claim) and that nothing in the fix depends on it.
- [x] 1.6 Contention WAS observed, so no re-scope is needed. Task 6 stands.

## 2. Refresh the CI contract first

- [ ] 2.1 Refresh `//:ci_heavy_gate_contract_test` for the inputs this change touches, as its
      own commit, and confirm it is green before any behaviour change lands.
- [ ] 2.2 Record what became visible once the contract was green - a red contract gate masks the
      integration failures behind it.

## 3. Extract the shared bootstrap classifier

- [x] 3.1 Created `ServiceRadar.Repo.SchemaBootstrap` with `classify/1`, `classify_state/2`
      (pure), `apply_baseline!/2`, `migration_ledger_versions/1`,
      `platform_owned_object_count/1`, `baseline_metadata!/0` and
      `migration_version_from_file/1`. Repo is an argument throughout.
- [x] 3.2 `StartupMigrations` now delegates: `classify_bootstrap_state/2` is a `defdelegate` to
      `classify_state/2`, `database_bootstrap_state/0` calls `SchemaBootstrap.classify/1`, and
      the `:empty` branch calls `SchemaBootstrap.apply_baseline!/2`. 145 lines removed from that
      module; compiles clean under `--warnings-as-errors`.
- [x] 3.3 `test/serviceradar/cluster/startup_migrations_unit_test.exs` passes with NO assertion
      changes (15 tests green alongside the migration tests), which is what makes the extraction
      behaviour-preserving rather than merely compiling.
      NOTE: `database_bootstrap_integration_test.exs` is the release-qualification cold-start
      target and is excluded from ordinary lanes; it was NOT run here. See 8.4.

## 4. Wire the migrator-driven entry points

- [x] 4.1 `test/db/migrate_db_test.exs` now classifies first, applies the baseline on `:empty`,
      fails closed on `{:ambiguous, _}`, and leaves `Ecto.Migrator.run/3` unchanged so a
      template that already has history behaves exactly as before.
- [x] 4.2 Added `mix serviceradar.db.migrate` (`lib/mix/tasks/serviceradar.db.migrate.ex`),
      wrapping the same module, with `--no-baseline` to reproduce a full replay deliberately.
      NOT yet documented in `AGENTS.md` -- see 4.4.
- [x] 4.3 Verified end to end against a scratch CNPG database, gating on the artefact rather
      than the exit status:

          applied 118 migration(s)            <- not 436; the baseline covered 318
          applied_versions_recorded=436       <- ledger complete
          baseline_rows=1                     <- baseline recorded
          20260126120000 recorded=1           <- the #4151 migration recorded, never run
          ash_schema_migrations location=ABSENT

      NOT yet verified: the same path through the actual Bazel `migrate_db` target against the
      shared template. That needs the srql-fixtures lifecycle (8.4) and RBE.
- [x] 4.4 Documented `mix serviceradar.db.migrate` in `AGENTS.md` as the developer entry point in
      place of bare `mix ecto.migrate`.

## 5. Stop relocating the migration ledger tables

- [x] 5.1 Exclude the ledger named by the repo's configured `migration_source` -- not a
      hardcoded name -- from the table loop in
      `priv/repo/migrations/20260126120000_move_public_schema_objects_to_platform.exs`.
      Done via `ledger_tables/1` + `move_objects_sql/1`, called from `up/0` as
      `move_objects_sql(ledger_tables(repo().config()[:migration_source]))`.
      Covered by `test/serviceradar/migrations/move_public_schema_objects_to_platform_test.exs`
      (7 tests) and verified behaviourally against a real database: both ledgers stay in
      `public`, an ordinary table still moves to `platform`.
- [x] 5.2 Confirmed: `StartupMigrations` already creates `platform.ash_schema_migrations`
      (`startup_migrations.ex:1099`) and syncs rows into it, so nothing depends on the move to
      place it.
- [ ] 5.3 Add the diagnostic exception handler to the sequence, view and materialized-view
      loops. NOTE: the premise this task was written with was wrong -- `SET LOCAL lock_timeout`
      is transaction-scoped, so those loops are ALREADY bounded by it. What they lack is only
      the handler that names the blocking object and its lock holders. Lower value than the
      table loop (a sequence or view is never the migration ledger), and a naive fix
      triplicates ~25 lines of PL/pgSQL, so prefer unifying the four loops into one
      `(kind, name)` pass with a single handler.

## 6. Apply the recorded mechanism's fix

- [x] 6.1 Not applicable, and that is the finding rather than a skip: task 1 identified the
      migration ledger itself as the blocker, so the fix this task was reserved for IS task 5.
      No second blocker exists. See `findings.md` E1-E5.
- [x] 6.2 Reproduced the failing condition (`findings.md` E5, C2): with the migrator's lock held
      on one connection and the move issued from a `Task.async` on another, the move waited the
      full `lock_timeout` and was cancelled `55P03`. After the task-5 fix the ledger is no longer
      a relocation target, so that wait cannot arise -- confirmed by running the generated SQL
      against a real database with both ledgers present (`ash_schema_migrations -> public`).

## 7. Gate baseline freshness

- [x] 7.1 `schema_baseline_freshness_test.py` + `//:schema_baseline_freshness_test`. Four
      checks: required metadata fields, checksum matches the SQL file, drift within
      `MAX_MIGRATIONS_BEHIND` (150), and `included_through` names a real migration.
      Proved it can fail: temporarily lowering the threshold to 10 produced
      "The schema baseline is 118 migrations behind (limit 10)" with the versions named.
- [x] 7.2 The failure message states the regeneration action and the two fields to update.
- [x] 7.3 Recorded, in the module docstring and the Bazel comment: this delivers the DRIFT
      check ONLY. It does NOT satisfy `refactor-fresh-install-db-bootstrap`'s
      "Baseline matches migration replay" requirement, which remains unimplemented -- that
      change's task 5.3 is ticked but no schema-diff target exists in the tree.

## 8. Verification

- [x] 8.1 `test/serviceradar/repo/schema_bootstrap_test.exs` covers `classify_state/2` across
      empty, migrated and ambiguous, plus duplicate/unsorted versions,
      `migration_version_from_file/1`, and the committed baseline metadata. 21 tests green with
      the startup and migration suites.
- [x] 8.2 Added "the migrator path baselines instead of replaying the whole history" to
      `test/serviceradar/cluster/database_bootstrap_integration_test.exs`, which already owns a
      per-test scratch database and a subprocess harness. It asserts on `applied_count` -- how
      many migrations `Ecto.Migrator` ACTUALLY ran -- because that is the only number that
      separates the two paths: a baselined bootstrap and a full replay both end with every
      version recorded in `schema_migrations`. Revert the wiring and `applied_count` becomes the
      full on-disk count and the test fails. Carries a guard-the-guard assertion so it cannot
      pass trivially if the baseline ever covers nothing.
      Runs in `//elixir/serviceradar_core:large_ingestion_release_gate`.

      NOT executed on this workstation, and deliberately not forced: that gate resolves its
      endpoint from the typed `ci` identity, whose host is in-cluster and unreachable from a
      workstation. `.agents/skills/srql-fixtures-db-tests/SKILL.md` says explicitly not to
      recreate those inputs from `SRQL_FIXTURE_HOST`, a NodePort or a direct DSN, so CI is its
      first real execution. De-risked instead by: the behaviour itself measured end to end
      (4.3), the file compiling, and a checker confirming both composed subprocess scripts parse
      as Elixir (the refactor that shares a preamble between them could otherwise have broken
      the pre-existing test too).
- [x] 8.3 A regression test that `20260126120000` leaves a pre-existing
      `public.ash_schema_migrations` alone. Unit coverage in
      `test/serviceradar/migrations/move_public_schema_objects_to_platform_test.exs`, plus a
      behavioural run of the generated SQL against a scratch CNPG database asserting
      `ash_schema_migrations -> public`, `schema_migrations -> public`,
      `some_app_table -> platform`.
- [ ] 8.4 Run the srql-fixtures database-test lifecycle in order
      (sweep, prepare template, migrate, provision, test, teardown) per the
      `srql-fixtures-db-tests` skill, and confirm teardown ran even on a red shard.
- [ ] 8.5 Run `make test` before opening the PR.
- [ ] 8.6 Update every task above to `- [x]` only once the work is actually done.
