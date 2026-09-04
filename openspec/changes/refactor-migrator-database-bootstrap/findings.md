# Findings: mechanism of the #4151 migration stall

Task 1 of `tasks.md`. Status: **mechanism established.** Read from source hop by hop (E1-E3) and
measured against the fixture CNPG instance (E4-E5). This document records evidence, not
inference — where something is inferred it says so.

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

### E2. The migrator holds a lock on that table while each migration runs

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
the statement is `LOCK TABLE "ash_schema_migrations" IN SHARE UPDATE EXCLUSIVE MODE`.

The lock is taken **per migration**, not once around the whole run: `migrate/4`
(`migrator.ex:754-758`) loops over migrations and each iteration calls
`conditional_lock_for_migrations` → `lock_for_migrations` → the adapter callback above. So for
`20260126120000` specifically, the ledger is locked immediately before that migration's body
runs — which is exactly why the issue observed it "blocked from its start".

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

The full chain, verified by reading each hop:

```
migrate/4                             migrator.ex:754   per migration
  do_direction(:up, ...)              migrator.ex:760
    conditional_lock_for_migrations   migrator.ex:606
      lock_for_migrations             migrator.ex:553
        do_lock_for_migrations        postgres.ex:332   conn A: BEGIN + LOCK TABLE ledger
          do_up                       migrator.ex:279
            async_migrate_...         migrator.ex:332   Task.async -> conn B
              run_maybe_in_transaction migrator.ex:346  conn B: BEGIN + migration body
```

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

### E5. Confirmed live: two connections, and the wait is real

E3 was read from Ecto's source; this measures it. Because the claim is a property of
Ecto + DBConnection rather than of ServiceRadar, it was tested with a minimal
`ecto_sql` + `postgrex` repo against a throwaway database on the fixture CNPG instance,
reproducing the exact topology from the chain in E3.

```
parent_backend_pid=689488
task_backend_pid=689490
C1 PASS: different connections (689488 -> 689490).

C2 PASS: the move did not succeed.
   result={:ok, {:raised, "ERROR 55P03 (lock_not_available) canceling statement due to lock timeout"}}

QUERY ERROR db=15035.1ms
  ALTER TABLE public.ash_schema_migrations SET SCHEMA platform

schemas holding ash_schema_migrations: [["public"]]
```

Both claims hold:

- **C1** — `Task.async` checked out a *different* pooled connection (`689488` → `689490`). The
  two-connection premise is confirmed, not inferred.
- **C2** — with the outer connection holding `SHARE UPDATE EXCLUSIVE` and blocked in
  `Task.await`, the inner connection's `ALTER TABLE ... SET SCHEMA` waited the **entire**
  15,000 ms `lock_timeout` (`db=15035.1ms`) and was cancelled. It never acquired the lock, and
  the table stayed in `public`.

The 15 s figure is the whole point: the wait was bounded only because the probe set a
`lock_timeout`. Without one it does not end — which is what produced the 264 s in the issue,
where the wait was terminated by the Sandbox `ownership_timeout` killing the connection instead.

Both the probe database and the E4 control database were dropped and their absence re-queried.

## Status

E1, E2 and E3 are read directly from source, hop by hop. E4 and E5 are measured. The mechanism
is established; no step of it remains inferred.

What is *not* established, and does not need to be for the fix: whether the same stall also
reproduces through `MIX_ENV=dev`. The issue reports dev completing, which is consistent with a
dev run made from `elixir/serviceradar_core`, where `migration_source` is unset and the ledger
is the already-excluded `schema_migrations`. That is a plausible reading of a secondary detail,
not a measurement, and nothing in the fix depends on it.
