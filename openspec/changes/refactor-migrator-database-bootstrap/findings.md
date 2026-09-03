# Findings: mechanism of the #4151 migration stall

Task 1 of `tasks.md`. Status: **mechanism identified from source; live confirmation in
progress.** This document records evidence, not inference — where something is inferred it says
so.

## Summary

`MovePublicSchemaObjectsToPlatform` relocates the table Ecto's own migrator is using as its
migration ledger, while the migrator holds a lock on it for the duration of the run. The result
is a wait that neither PostgreSQL nor the BEAM can break.

The issue's leading hypothesis was close but named the wrong owner. It supposed AshPostgres was
using `ash_schema_migrations` as its own bookkeeping. It is not: **nothing in any dependency
references `ash_schema_migrations` at all.** The table is Ecto's `schema_migrations` under a
different name, set by ServiceRadar itself.

## Evidence

### E1. `ash_schema_migrations` is Ecto's migration ledger, renamed

`elixir/web-ng/config/config.exs:114`:

```elixir
config :serviceradar_core, ServiceRadar.Repo, migration_source: "ash_schema_migrations"
```

This is set **only** in web-ng's config, for the shared `ServiceRadar.Repo`.
`elixir/serviceradar_core/config/` sets neither `migration_source` nor `migration_lock`.

Consequence, and it decides whether the bug reproduces:

| Run from | Ledger table | Excluded by the migration? |
|---|---|---|
| `elixir/serviceradar_core` | `schema_migrations` | yes — `tablename <> 'schema_migrations'` |
| `elixir/web-ng` | `ash_schema_migrations` | **no** |

The issue's reproduction is `cd elixir/web-ng`. That is why it reproduces there, and why the
issue measured exactly one table to move: the ledger, created by the migrator itself in `public`
because `platform` does not exist yet on a fresh database.

Searching the whole dependency tree for `ash_schema_migrations` returns nothing; the only
references in the repository are ServiceRadar's own `startup_migrations.ex` and that config
line. The "AshPostgres reads and writes that table when the repo starts" hypothesis is therefore
**disproved**.

### E2. The migrator holds a lock on that table for the whole run

`deps/ecto_sql/lib/ecto/adapters/postgres.ex:332-347`, the default strategy
(`migration_lock` defaults to `:table_lock`):

```elixir
defp do_lock_for_migrations(:table_lock, meta, opts, _config, fun) do
  {:ok, res} =
    transaction(meta, opts, fn ->
      source = Keyword.get(opts, :migration_source, "schema_migrations")
      table = if prefix = opts[:prefix], do: ~s|"#{prefix}"."#{source}"|, else: ~s|"#{source}"|
      lock_statement = "LOCK TABLE #{table} IN SHARE UPDATE EXCLUSIVE MODE"
      {:ok, _} = Ecto.Adapters.SQL.query(meta, lock_statement, [], opts)
      fun.()
    end)
  res
end
```

`opts[:migration_source]` is populated from repo config at `migrator.ex:573`. So under web-ng
the statement is `LOCK TABLE "ash_schema_migrations" IN SHARE UPDATE EXCLUSIVE MODE`, and it is
held open across `fun.()` — every migration in the run.

### E3. Each migration runs on a different connection

`deps/ecto_sql/lib/ecto/migrator.ex:332-343`:

```elixir
defp async_migrate_maybe_in_transaction(repo, config, version, module, direction, opts, fun) do
  ...
  fn -> run_maybe_in_transaction(repo, dynamic_repo, module, fun_with_status, opts) end
  |> Task.async()
  |> Task.await(:infinity)
end
```

Each migration executes inside `Task.async` — a separate process — which then calls
`repo.transaction/2`. Ecto connection ownership is per-process, so this is a *second* pooled
connection, distinct from the one holding the lock in E2.

### E4. The resulting topology is an unbreakable wait (positive control)

Reproduced directly with `psql` against the fixture CNPG instance, to confirm the lock conflict
is real and that the observer can detect it:

```
=== blocked sessions ===
684231|{684227}|active|Lock|relation| ALTER TABLE public.ash_schema_migrations SET SCHEMA platform

=== lock modes on the ledger table ===
684227|ShareUpdateExclusiveLock|t     <- the migrator's lock, granted
684231|AccessExclusiveLock|f          <- the migration's move, NOT granted
ERROR:  canceling statement due to lock timeout
```

Why nothing breaks it on its own:

- **PostgreSQL's deadlock detector cannot see it.** Only one session is waiting *in the
  database*. The lock holder is `idle in transaction`, blocked in the BEAM on
  `Task.await(:infinity)`. There is no cycle in the database's wait-for graph.
- **The BEAM does not break it either**, because that await is `:infinity`.

This matches every timing detail in the issue: blocked from the migration's start (the lock is
taken before any migration body runs), and completing at the exact instant the connection was
force-closed — killing the lock holder rolled its transaction back, released
`SHARE UPDATE EXCLUSIVE`, and the waiting `ALTER TABLE` proceeded immediately. The reported
"264.1s" is the wait, and the ~340 ms is the work, exactly as the issue measured.

## What this means for the fix

The migration excludes the ledger by a hardcoded name:

```sql
AND tablename <> 'schema_migrations'
```

That name is correct only when `migration_source` is unset. The exclusion must cover **the
configured `migration_source`**, not a literal. A migration is an Elixir module and can read
`repo().config()[:migration_source]`, so this is expressible.

This does not weaken the `lock_timeout` that landed in `8ec2325a29`. That change bounds and
explains *any* such wait and should stay; it is what would have made this diagnosable in
minutes. But a bounded self-deadlock is still a failed migration — the migration must stop
moving the ledger out from under the migrator.

## Status of the live confirmation

E1, E2 and E3 are read directly from source. E4 is measured. Outstanding: an end-to-end run
showing the two distinct backend pids in a real `mix ecto.migrate`, confirming E3 holds under
this project's pool configuration rather than only in Ecto's source. See `probe.exs` results
appended below when complete.
