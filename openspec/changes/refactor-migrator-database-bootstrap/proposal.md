# Change: Route every database migration entry point through the schema baseline

## Why

`refactor-fresh-install-db-bootstrap` gave ServiceRadar a schema baseline and taught
*service startup* to use it. Nothing else learned. The two paths that developers and CI
actually run - `mix ecto.migrate`, and the Bazel fixture template target
`//elixir/serviceradar_core:migrate_db` - still call `Ecto.Migrator.run(repo, :up, all: true)`
and replay all 436 migrations on an empty database, including the 318 the committed baseline
already contains.

That replay is what puts issue #4151 on the path. `MovePublicSchemaObjectsToPlatform`
(`20260126120000`) reports 264 seconds for roughly 340 ms of SQL against a remote CNPG
instance. It is not working for those 264 seconds, it is blocked; under `MIX_ENV=test` the
Sandbox `ownership_timeout` fires first, the connection is killed mid-migration, and the run
dies inside `do_lock_for_migrations/5` with `{:error, :rollback}` - an error naming neither
the object nor the blocker. A remote or shared fixture database is therefore a hard failure,
not a slow success.

Both mitigations #4151 suggested have already landed: commit `8ec2325a29` added
`SET LOCAL lock_timeout` plus a handler that names the table and its lock holders, and
`SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS` is honoured by both
`elixir/serviceradar_core/config/test.exs` and `elixir/web-ng/config/test.exs`. What remains
is the part the issue was careful not to guess at - the mechanism - and the structural reason
a fresh database runs that migration at all.

## What Changes

- Establish the stall's mechanism with a reproduction that can fail, and record the result
  before any fix is written. The issue's own probe was invalid; this one asserts its
  preconditions and has an explicit branch for "the hypothesis is wrong".
- Extract the `:empty | :migrated | :ambiguous` classification and baseline application out of
  `ServiceRadar.Cluster.StartupMigrations` into a repo-argument-taking module, so there is one
  implementation rather than one per entry point.
- Apply the baseline from the `Ecto.Migrator`-driven paths: the Bazel fixture template target
  and a `mix serviceradar.db.migrate` task that becomes the documented developer entry point.
- Stop relocating the migration ledger tables that the running repo reads and writes.
  `StartupMigrations` already creates `platform.ash_schema_migrations` directly, so moving it
  with `ALTER TABLE ... SET SCHEMA` under a live repo buys nothing and needs
  `ACCESS EXCLUSIVE`.
- Gate baseline freshness. The baseline is currently 118 migrations behind the tip
  (`included_through: 20260707120000`, 436 migrations on disk) and nothing detects that.

## Impact

- Affected specs: `database-bootstrap` (all ADDED; composes with the pending
  `refactor-fresh-install-db-bootstrap`, which introduces the capability and whose
  requirements this change does not modify)
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex` (extraction)
  - new `ServiceRadar.Repo.SchemaBootstrap`
  - new `Mix.Tasks.Serviceradar.Db.Migrate`
  - `elixir/serviceradar_core/test/db/migrate_db_test.exs`
  - `elixir/serviceradar_core/priv/repo/migrations/20260126120000_move_public_schema_objects_to_platform.exs`
  - `elixir/serviceradar_core/priv/repo/baseline/` and its freshness gate
- Gate impact: `priv/repo/baseline/platform_schema.sql` is a declared input to
  `//:ci_heavy_gate_contract_test` (root `BUILD.bazel`). That contract is refreshed first, in
  its own step - a red contract gate masks the integration failures behind it.
- Operational impact: none for deployed installs. Service startup behaviour is unchanged; this
  change only gives the developer and CI paths the bootstrap that startup already has.
