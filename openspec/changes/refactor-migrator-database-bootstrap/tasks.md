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

- [ ] 3.1 Create `ServiceRadar.Repo.SchemaBootstrap` with `classify/1` returning
      `:empty | :migrated | {:ambiguous, details}` and `apply_baseline!/1` performing checksum
      verification, schema file execution, ledger marking, and baseline recording. Take the repo
      as an argument; no cluster or startup concerns.
- [ ] 3.2 Reduce `ServiceRadar.Cluster.StartupMigrations` to a caller of that module, preserving
      its current behaviour exactly.
- [ ] 3.3 Confirm `test/serviceradar/cluster/database_bootstrap_integration_test.exs` passes with
      no assertion changes. Assertion edits here mean the extraction was not
      behaviour-preserving.

## 4. Wire the migrator-driven entry points

- [ ] 4.1 Have `test/db/migrate_db_test.exs` classify first and apply the baseline on `:empty`
      before calling `Ecto.Migrator.run/3`, so the fixture template applies the baseline plus
      only the pending migrations.
- [ ] 4.2 Add `mix serviceradar.db.migrate` wrapping the same module, and document it in
      `AGENTS.md` as the developer entry point in place of bare `mix ecto.migrate`.
- [ ] 4.3 Confirm the fixture template is actually rebuilt rather than reused from cache. The
      `migrate_db` target is tagged `external` to defeat Bazel test caching, but the *template
      database* is a separate cache - verify against the template's `schema_migrations` contents,
      not against the target's exit status.

## 5. Stop relocating the migration ledger tables

- [ ] 5.1 Exclude the ledger named by the repo's configured `migration_source` -- not a
      hardcoded name -- from the table loop in
      `priv/repo/migrations/20260126120000_move_public_schema_objects_to_platform.exs`.
      `Ecto.Migration.repo/0` is public API, so `repo().config()[:migration_source]` is
      available inside the migration. The current literal `tablename <> 'schema_migrations'`
      is correct only when `migration_source` is unset; web-ng sets it to
      `ash_schema_migrations`. See `findings.md` E1.
- [ ] 5.2 Confirm the exclusion is safe: `StartupMigrations` already creates
      `platform.ash_schema_migrations` and syncs rows into it, so nothing depends on the move
      to place it.
- [ ] 5.3 Extend the `lock_timeout` guard and diagnostic exception handler to the sequence, view
      and materialized-view loops, which are currently unwrapped.

## 6. Apply the recorded mechanism's fix

- [ ] 6.1 Only if task 1 confirmed a blocker beyond the ledger tables: implement the fix that
      blocker calls for, citing `findings.md`.
- [ ] 6.2 Reproduce the original failing condition and confirm it now completes, or fails inside
      `lock_timeout` naming the blocker.

## 7. Gate baseline freshness

- [ ] 7.1 Add a check that fails when migrations on disk are newer than the baseline's
      `included_through` by more than the agreed margin. The baseline is currently 118
      migrations behind.
- [ ] 7.2 Document the regeneration procedure alongside the gate, so a red gate has an action.
- [ ] 7.3 Decide and record whether this change delivers the full schema-diff validation that
      `refactor-fresh-install-db-bootstrap` specified, or only the drift check. Do not mark that
      change's requirement satisfied unless the validation exists in the tree.

## 8. Verification

- [ ] 8.1 Unit tests for `SchemaBootstrap.classify/1` across empty, migrated and ambiguous
      databases.
- [ ] 8.2 A database test asserting that a fresh database bootstrapped through the migrator path
      records the baseline-covered versions in `schema_migrations` *without* their migrations
      having run, and applies only the pending remainder.
- [ ] 8.3 A regression test that `20260126120000` leaves a pre-existing
      `public.ash_schema_migrations` alone.
- [ ] 8.4 Run the srql-fixtures database-test lifecycle in order
      (sweep, prepare template, migrate, provision, test, teardown) per the
      `srql-fixtures-db-tests` skill, and confirm teardown ran even on a red shard.
- [ ] 8.5 Run `make test` before opening the PR.
- [ ] 8.6 Update every task above to `- [x]` only once the work is actually done.
