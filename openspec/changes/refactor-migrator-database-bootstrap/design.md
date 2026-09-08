## Context

Issue #4151 reports `MovePublicSchemaObjectsToPlatform` (`20260126120000`) taking 264 s for
~340 ms of SQL against the `srql-fixtures` CNPG instance, and killing
`MIX_ENV=test mix ecto.migrate` outright. The issue is unusually careful: it rules out a
degraded cluster, a large `public` schema, expensive catalog scans, TimescaleDB hypertables,
and the `ALTER TABLE` itself by measurement, states a hypothesis, and then says the probe it
used to test that hypothesis was invalid and proves nothing.

Two things have changed since it was filed.

**The mitigations landed.** `8ec2325a29` added `SET LOCAL lock_timeout` (15 s, overridable via
`SERVICERADAR_MIGRATION_LOCK_TIMEOUT_MS`) and wrapped the table move so a timeout reports which
table could not be locked and which sessions hold it, with pid, state and query. Both test
configs read `SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS`. The failure is now bounded and
self-describing - but only for whoever next runs it under failing conditions, and nobody has.

**A baseline exists that would have skipped the migration entirely.**
`refactor-fresh-install-db-bootstrap` shipped `priv/repo/baseline/platform_schema.sql` with
`included_through: 20260707120000`, covering `20260126120000` and 317 others. But
`apply_schema_baseline!` is reachable only from `StartupMigrations.run_bootstrap_or_migrations!`,
which runs at service boot. The paths in the issue's repro do not go through it:

- `mix ecto.migrate` - the developer path, and the issue's literal reproduction.
- `//elixir/serviceradar_core:migrate_db` - `test/db/migrate_db_test.exs`, which calls
  `Ecto.Migrator.run(repo, :up, all: true)` under `MIX_ENV=test` with the Sandbox pool. This is
  the CI fixture template preparation, so CI pays the full replay and is exposed to the same
  ownership timeout.

So the migration is slow *and* it should not be running in those contexts at all. Both are in
scope; neither subsumes the other, because a database already mid-history still reaches the
migration on the `:migrated` branch where no baseline applies.

## Goals / Non-Goals

Goals:
- Record the stall's mechanism from evidence, not inference.
- Give every migration entry point the baseline bootstrap that startup already has, via one
  implementation.
- Make the migration ledger tables not participate in schema relocation.
- Detect baseline drift.

Non-Goals:
- No change to deployed service startup behaviour. `StartupMigrations` keeps its current
  semantics; it just calls the extracted module.
- No squashing or rewriting of migration history.
- No destructive reset path for existing databases.
- No second baseline implementation in Rust.

## Decisions

### Decision: Establish the mechanism before writing the fix, with a reproduction that can fail

The issue's leading hypothesis - that the migration takes `ACCESS EXCLUSIVE` on
`ash_schema_migrations` while the AshPostgres repo running the migration uses that table on
another pool connection - is plausible and unconfirmed. Writing a fix against an unconfirmed
mechanism is how the invalid probe happened in the first place.

The reproduction:

1. Provision a scratch CNPG database migrated to **exactly** `20260125090000`, and assert that
   version before proceeding. The earlier probe failed because `mix ecto.migrate --to <version>`
   replayed from the beginning and died on `relation "edge_sites" already exists`, never
   reaching the migration under test.
2. Start a concurrent observer polling `pg_locks` joined to `pg_stat_activity`, filtered to the
   relations the migration touches, appending samples to a file.
3. Run the single migration under `MIX_ENV=test` against that database.

Branches, all of which must be distinguishable:

- Blocker found, and it is a connection from the migrating repo's own pool - hypothesis
  confirmed.
- Blocker found, and it is something else - the landed `DETAIL` line names it; the fix follows
  that culprit instead.
- No blocker, migration completes in roughly 340 ms - the stall is **not** lock contention.
  Candidates then are the connection pooler, the Sandbox ownership proxy, or the network path.
  This branch re-scopes the change rather than quietly disappearing.

Per the repository rule that a verification must be able to fail: gate on the artefact, not on
the run. Assert the observer captured at least one sample and that the database was at
`20260125090000` when the migration started. An observer that recorded nothing is a broken
observer, not a clean result - which is exactly what the invalid probe's "no sessions blocked"
outcome was.

### Decision: One shared bootstrap module, not one per entry point

Extract from `StartupMigrations` into `ServiceRadar.Repo.SchemaBootstrap`, taking the repo as an
argument and free of cluster/startup concerns:

- `classify/1` - the `:empty | :migrated | {:ambiguous, details}` decision
- `apply_baseline!/1` - checksum verification, schema file execution, ledger marking, baseline
  recording

`StartupMigrations` then calls it and keeps its behaviour, so
`database_bootstrap_integration_test.exs` (the release-qualification cold-start target)
continues to cover the production path unchanged. `migrate_db_test.exs` and the new mix task
call the same functions.

**Alternative considered: apply the baseline inside `//rust/integration-db:prepare_template`.**
It fits the existing split, where everything that is not an `Ecto.Migration` has moved to Rust,
and `prepare_template` already owns template creation. Rejected because it reimplements
checksum verification and ledger seeding in a second language against the same `metadata.json`
contract - the drift the repository guidance warns about elsewhere - and because it does
nothing for the developer running `mix ecto.migrate`, which is the issue's actual repro.

**Alternative considered: squash the 318 covered migrations.** Rejected. The baseline already is
that squash. Doing it for real breaks every environment sitting mid-history and destroys the
record.

### Decision: Migration ledger tables are excluded from schema relocation

Independent of what the reproduction finds, `ALTER TABLE public.ash_schema_migrations SET SCHEMA
platform` is the wrong instrument. It needs `ACCESS EXCLUSIVE` on a table the running repo reads
and writes, and it is redundant: `StartupMigrations` already issues
`CREATE TABLE IF NOT EXISTS platform.ash_schema_migrations` and syncs rows into it. Excluding the
ledger tables from the move removes a lock the migration never needed, whether or not that lock
is the 264 s.

This is deliberately framed as an invariant rather than as the fix for a specific mechanism, so
that it survives the reproduction disproving the hypothesis.

### Decision: Gate baseline freshness

`refactor-fresh-install-db-bootstrap` task 5.3 ("Add CI schema-diff validation between baseline
and migration replay") is marked complete, and its spec delta carries a
"Baseline matches migration replay" requirement. Searching the tree for consumers of
`schema_sha256` / `included_through` returns exactly one file (`startup_migrations.ex`), and
there is no `pg_dump`- or schema-diff-based target anywhere in the Bazel graph. Whatever was
done, no gate is in the tree today.

That gap is tolerable while only service startup depends on the baseline, because the
`:migrated` branch applies the 118 newer migrations on top and converges. It stops being
tolerable when CI's fixture template and every developer's database also bootstrap from it: a
stale baseline then silently shapes the schema that tests run against.

Minimum viable gate: a check that fails when migrations exist on disk newer than
`included_through` by more than an agreed margin, with a documented regeneration procedure. Full
schema-diff validation is better and is what the sibling change's requirement asks for; this
change should not claim to deliver it unless it does.

## Risks / Trade-offs

- **The reproduction may disprove the hypothesis.** Mitigation: that branch is written into the
  plan and re-scopes the change rather than being absorbed. The baseline work (tasks 3-5) does
  not depend on the outcome and proceeds either way.
- **`platform_schema.sql` is a declared input to `//:ci_heavy_gate_contract_test`** (root
  `BUILD.bazel`). Changing its consumers turns that gate red, and a red contract gate masks the
  integration failures behind it. Mitigation: refresh the contract as its own step and confirm
  what becomes visible afterwards, rather than bundling it with the behaviour change.
- **Extracting from `StartupMigrations` touches the production bootstrap path.** Mitigation: the
  extraction is behaviour-preserving and `database_bootstrap_integration_test.exs` covers both
  the `:empty` and `:migrated` branches; it must stay green with no assertion changes.
- **A stale baseline becomes more load-bearing.** Mitigation: the freshness gate lands in the
  same change, not after it.
- **The fixture template caches aggressively.** `migrate_db` is tagged `external` to defeat Bazel
  test caching; changing what it does requires confirming the template is rebuilt rather than
  reused, or the change will appear to work while the old template is still being copied.

## Migration Plan

1. Reproduce and record the mechanism. Land the recorded evidence before the fix.
2. Refresh `//:ci_heavy_gate_contract_test` inputs, confirm green, and note what that unmasks.
3. Extract `SchemaBootstrap`; `StartupMigrations` delegates. No behaviour change.
4. Wire `migrate_db_test.exs` and the new mix task to it.
5. Exclude the ledger tables from the relocation migration.
6. Add the freshness gate.

Rollback: each step is independently revertable. Steps 3-4 revert to the current full replay,
which is slow but correct. Step 5 reverts to the current migration, which is bounded by
`lock_timeout` and self-describing.

## Open Questions

- Does the reproduction confirm the AshPostgres-ledger hypothesis, or send this at the pooler /
  Sandbox ownership proxy? Task 1 answers this and the answer is a precondition for task 5.
- Should `mix ecto.migrate` itself be aliased to the new task, or left alone with the new task
  documented alongside it? Aliasing a standard Ecto task is surprising to anyone who knows Ecto;
  the current plan documents rather than aliases.
- Is a drift threshold sufficient, or does this change owe the full schema-diff validation that
  `refactor-fresh-install-db-bootstrap` already specified and did not deliver?
