# Change: Re-adopt `ash.codegen` for ordinary relational tables

## Why

Today every schema change in `serviceradar_core` is a **hand-written**
Ecto migration. For Timescale hypertables, AGE graph objects, materialized
views, continuous aggregates, and triggers that is correct and unavoidable —
`ash.codegen` cannot represent them, which is why **66 resources already set
`migrate? false`** and **62 migrations do raw/Timescale/AGE DDL**.

But the convention over-applies. **~165 of ~231 `AshPostgres` resources are
ordinary relational tables** whose migrations `ash.codegen` could generate
mechanically. Hand-writing those is pure toil and a recurring source of bugs:
a migration column type that disagrees with the resource attribute, a
forgotten index, a wrong default. It bit us implementing the ad-hoc scan
tables (an enum attribute whose hand-written column type had to be inferred
by hand). The resource definition is already the source of truth for these
tables; hand-copying it into a migration just invites drift.

Ash snapshots were committed until **#2320 ("tenant cleanup")** deleted them
and gitignored `priv/resource_snapshots/`, replacing them with a pg_dump
**baseline** (`priv/repo/baseline/platform_schema.sql`, a "migration-replayed
empty database" through migration `20260707120000`). `startup_migrations.ex`
applies that baseline to a fresh DB then runs newer migrations. That baseline
mechanism is good and stays — it is orthogonal to codegen. What we lost with
the snapshots is the ability to run `ash.codegen` and get a **diff** instead
of a from-scratch create-everything migration.

This change re-adopts `ash.codegen` for the ordinary-relational subset while
keeping the special resources hand-written, so contributors stop hand-writing
routine table/column migrations without giving up the pg_dump baseline or
breaking the Timescale/AGE parts codegen can't handle.

## What Changes

- **RE-ENABLE snapshots.** Regenerate the Ash resource snapshots to match the
  current live schema with `mix ash.codegen --snapshots-only` (updates
  `priv/resource_snapshots/` without emitting a migration), and **un-ignore**
  `priv/resource_snapshots/` in `.gitignore`. This becomes the committed
  baseline from which future `ash.codegen` runs diff.
- **DEFINE a hybrid policy** (documented in AGENTS.md +
  `elixir/serviceradar_core/CLAUDE.md`):
  - Ordinary Ash-managed relational tables -> `ash.codegen` generates the
    migration. Do not hand-write these.
  - Timescale hypertables, retention policies, AGE/`ag_catalog` objects,
    materialized views, continuous aggregates, triggers, functions, and any
    other object `ash.codegen` cannot model -> the resource stays
    `migrate? false` and the DDL is a hand-written migration (unchanged from
    today; e.g. `MtrTrace`, `adhoc_scan_results`).
  - A resource that is *mostly* Ash-manageable but needs one raw touch (a
    special index, a check constraint) uses `ash.codegen` for the table and a
    small follow-on hand-written migration for the raw bit, or an
    AshPostgres `custom_indexes`/`custom_statements` block where supported.
- **RECONCILE resource <-> live-schema drift** for the Ash-managed subset so
  the first `ash.codegen` after snapshotting produces an **empty** diff (or a
  small, explicitly reviewed set of intentional corrections). This is the
  load-bearing, one-time effort: audit each Ash-managed table's attributes,
  identities, and indexes against the actual columns/indexes/constraints the
  hand-written migrations produced, and fix the resource (or record a
  deliberate corrective migration) until codegen is quiet.
- **ADD a CI gate**: `mix ash.codegen --check` (fails when resources changed
  without regenerating migrations/snapshots), wired into the Elixir quality
  workflow so drift can't merge.
- **KEEP the pg_dump baseline mechanism unchanged.** `ash.codegen` migrations
  are just migrations newer than the baseline version; `startup_migrations`
  runs them normally. Document that the baseline is periodically re-dumped
  (existing process) and that snapshots + baseline are independent artifacts.
- **UPDATE guidance**: AGENTS.md "Database Schema Management" and
  `serviceradar_core/CLAUDE.md` describe the hybrid workflow and the
  `migrate? false` decision rule, replacing "all migrations are hand-written."

## Impact

- **Affected specs**: NEW capability `schema-migration-workflow`.
- **Affected files**:
  - `.gitignore` — un-ignore `elixir/**/priv/resource_snapshots/`.
  - `elixir/serviceradar_core/priv/resource_snapshots/**` — newly committed
    baseline (one JSON per table).
  - Ash resources under `elixir/serviceradar_core/lib/**` — drift fixes so
    codegen is quiet (no behavior change; attribute/index/identity parity).
  - CI config (Elixir quality workflow) — add `ash.codegen --check`.
  - `AGENTS.md`, `elixir/serviceradar_core/CLAUDE.md` — workflow docs.
- **Contributor workflow**: adding/altering an ordinary table becomes
  "edit the resource, run `mix ash.codegen <name>`, commit the generated
  migration + snapshot" instead of hand-writing DDL. Special (Timescale/AGE)
  tables are unchanged.
- **Risk**: the drift-reconciliation pass is real work and must be reviewed
  table-by-table; a wrong reconciliation could emit a destructive migration.
  Mitigated by generating snapshots-only first (no migration), then reviewing
  the first `ash.codegen` diff before committing any migration, and by never
  auto-running destructive statements. See `design.md`.
- **Compatibility**: no runtime/schema change lands from this proposal itself
  — it changes the *authoring workflow* and commits snapshots. Any corrective
  migrations surfaced during reconciliation are reviewed individually.
- **Relationship**: unblocks cleaner schema work for in-flight features (e.g.
  `add-adhoc-network-scan`, whose ordinary tables would move to codegen once
  this lands; its Timescale `adhoc_scan_results` stays hand-written either
  way).
