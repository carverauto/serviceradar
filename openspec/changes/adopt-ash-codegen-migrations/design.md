# Design: Re-adopt `ash.codegen` for ordinary relational tables

## Context

`serviceradar_core` has ~231 `AshPostgres` resources and 358 hand-written
migrations. Snapshots were dropped in #2320 in favor of a pg_dump baseline
(`priv/repo/baseline/platform_schema.sql`, replayed through migration
`20260707120000`) applied by `startup_migrations.ex`. Without snapshots,
`mix ash.codegen` has no diff base and emits a full baseline, so the team
hand-writes every migration.

Two facts shape the design:
- **~66 resources set `migrate? false`** and **62 migrations do
  Timescale/AGE/matview/trigger/raw DDL** — codegen genuinely can't own these.
- **~165 resources are ordinary relational tables** — codegen can own these.

The goal is a **hybrid**: codegen for the ordinary majority, hand-written for
the special minority, with the pg_dump baseline untouched.

## Decisions

### D1: Snapshot-only baseline first (no migration)
Run `mix ash.codegen --snapshots-only` to write `priv/resource_snapshots/`
matching the *current resources*, and commit them. This produces **no
migration** — it just gives codegen a diff base. Un-ignore the directory.
This is safe because it changes no schema; it only records "what Ash believes
the schema is."

### D2: Reconcile drift before trusting codegen
After D1, `mix ash.codegen <name>` (dry) will reveal where the resources
disagree with the live schema (the hand-written migrations may have added
indexes/constraints/columns the resources don't declare, or vice versa). The
first diff is the reconciliation worklist. For each item:
- If the live schema is right and the resource is under-specified -> fix the
  resource (add the attribute/index/identity) so codegen goes quiet. **No
  schema change.**
- If the resource is right and the live schema truly lacks something -> that's
  a genuine corrective migration; review and commit it deliberately.
- Never let codegen emit a `drop`/destructive statement unreviewed.
The exit condition: `mix ash.codegen --check` is green with no pending diff.

### D3: `migrate? false` policy for non-codegen objects
Keep the existing pattern (as `MtrTrace`, `adhoc_scan_results` use):
Timescale hypertables + retention, AGE/`ag_catalog`, matviews, continuous
aggregates, triggers, functions -> `migrate? false` + hand-written migration.
Document the decision rule so contributors know which bucket a new table is
in. A quick test: if the table is a plain relational table with normal
columns/indexes/FKs, it's codegen; if it needs any Timescale/AGE/raw DDL,
it's `migrate? false`.

### D4: pg_dump baseline unchanged
The baseline + `startup_migrations` flow is orthogonal and stays. Codegen
migrations are ordinary migrations newer than the baseline version. When the
baseline is next re-dumped (existing process), it simply captures whatever the
migrations produced, codegen or hand-written alike. Snapshots and the pg_dump
baseline are independent artifacts serving different tools (Ash vs. fresh
install) and both remain committed.

### D5: CI gate
Add `mix ash.codegen --check` to the Elixir quality workflow for
`serviceradar_core`. It fails when a resource changed without a matching
regenerated migration + snapshot, preventing the drift that made snapshots
painful before.

## Rollout

1. `--snapshots-only` + un-ignore + commit snapshots (mechanical, no schema
   change).
2. Reconciliation pass (the real work): iterate resource-by-resource until
   `ash.codegen --check` is clean. Land as its own reviewed PR (or a small
   series) so the diff is auditable.
3. Add the CI gate.
4. Update AGENTS.md + `serviceradar_core/CLAUDE.md`.
5. Announce the workflow change to contributors.

## Risks / Trade-offs

- **Reconciliation is the hard part.** 165 tables is a lot; some will have
  subtle divergences (index naming, default expressions, array/jsonb types,
  enum storage). Budget for a careful pass and review the first codegen diff
  line by line. Mitigation: snapshots-only first means nothing destructive
  happens until a human reviews a real diff.
- **Snapshot merge conflicts.** Historically a pain; modern Ash writes
  one JSON per table, so conflicts are localized to tables two branches both
  touch — manageable, and the CI gate keeps them honest.
- **Two sources of "truth."** Snapshots (Ash's view) and the pg_dump baseline
  (fresh-install DDL) must stay consistent. They do as long as migrations are
  the single write path and both are regenerated from that path; the CI gate
  enforces the snapshot side, the existing re-dump process the baseline side.
- **Not a full migration to codegen.** The Timescale/AGE minority stays
  hand-written forever. That's correct, not a shortcoming — those objects are
  outside Ash's schema model.

## Out of scope

- Migrating the Timescale/AGE/matview resources to codegen (impossible; they
  stay `migrate? false`).
- Removing or replacing the pg_dump baseline mechanism.
- Any functional schema change — this is a workflow + snapshot-baseline
  change; corrective migrations from reconciliation are reviewed individually.
