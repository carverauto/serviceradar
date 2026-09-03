## 1. Establish the mechanism (#4151)

- [ ] 1.1 Provision a scratch CNPG database migrated to exactly `20260125090000`, and assert
      that version from `platform.schema_migrations` before running anything else. Do not use
      `mix ecto.migrate --to`; it replays from the beginning, which is what invalidated the
      probe in the issue.
- [ ] 1.2 Write the concurrent observer: poll `pg_locks` joined to `pg_stat_activity` for the
      relations the migration touches, append timestamped samples to a file, and record its own
      start and stop times.
- [ ] 1.3 Run `20260126120000` alone under `MIX_ENV=test` against that database with the
      observer running, and with `SERVICERADAR_MIGRATION_LOCK_TIMEOUT_MS` set high enough to
      observe the stall rather than cut it short.
- [ ] 1.4 Gate on the artefact, not the run: assert the observer captured at least one sample
      and that the recorded start version was `20260125090000`. A run that produced no samples
      is a broken observer and must be reported as such, not as "no contention".
- [ ] 1.5 Record the outcome in this change directory as `findings.md`, naming the blocker
      (pid, application_name, query) or explicitly stating that no lock contention was observed
      and the stall is elsewhere.
- [ ] 1.6 If no contention is observed, stop and re-scope: the remaining candidates are the
      connection pooler, the Sandbox ownership proxy, and the network path. Tasks 3-5 proceed
      regardless; task 6 does not.

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

- [ ] 5.1 Exclude `ash_schema_migrations` (alongside the already-excluded `schema_migrations`)
      from the table loop in
      `priv/repo/migrations/20260126120000_move_public_schema_objects_to_platform.exs`.
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
