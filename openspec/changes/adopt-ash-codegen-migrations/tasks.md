# Tasks: Re-adopt `ash.codegen` for ordinary relational tables

## 1. Snapshot baseline (no schema change)
- [ ] 1.1 Run `MIX_ENV=dev mix ash.codegen --snapshots-only` in
  `elixir/serviceradar_core` to write `priv/resource_snapshots/` from the
  current resources.
- [ ] 1.2 Un-ignore `elixir/**/priv/resource_snapshots/` in `.gitignore`
  (remove both entries) and `git add` the generated snapshots.
- [ ] 1.3 Confirm no migration was emitted by the snapshots-only run; commit
  the snapshots as a standalone "snapshot baseline" commit.

## 2. Drift reconciliation (the load-bearing pass)
- [ ] 2.1 Run `mix ash.codegen check_drift --dry-run` (or `mix ash.codegen`
  to a scratch name) and capture the full proposed diff without committing.
- [ ] 2.2 Triage every proposed change into: (a) under-specified resource ->
  fix the resource; (b) genuine corrective migration -> review + keep;
  (c) non-codegen object that should be `migrate? false` -> set it.
- [ ] 2.3 Fix resources for the (a) items until they no longer appear in the
  diff. No schema change for these.
- [ ] 2.4 For any (b) corrective migration, review line-by-line; ensure no
  unintended `drop`/destructive statement; land only intentional ones.
- [ ] 2.5 Audit the `migrate? false` set (66 today): confirm every
  Timescale/AGE/matview/trigger resource is excluded from codegen and none of
  the ordinary tables are wrongly excluded.
- [ ] 2.6 Iterate until `mix ash.codegen --check` reports no pending changes.

## 3. CI gate
- [ ] 3.1 Add `mix ash.codegen --check` to the `serviceradar_core` Elixir
  quality workflow (`scripts/elixir_quality.sh` and/or the CI job) so a PR
  that changes a resource without regenerating fails.
- [ ] 3.2 Verify the gate fails on a deliberately-drifted resource and passes
  on a clean tree.

## 4. Documentation
- [ ] 4.1 Update AGENTS.md "Database Schema Management": describe the hybrid
  workflow (codegen for ordinary tables; `migrate? false` + hand-written for
  Timescale/AGE/matview/trigger/raw), replacing "all migrations hand-written".
- [ ] 4.2 Update `elixir/serviceradar_core/CLAUDE.md` with the decision rule
  and the `mix ash.codegen <name>` authoring flow.
- [ ] 4.3 Note that the pg_dump baseline is unchanged and is a separate
  artifact from snapshots; document the re-dump cadence.

## 5. Verification
- [ ] 5.1 `mix compile --warnings-as-errors` clean.
- [ ] 5.2 `mix ash.codegen --check` clean on the final tree.
- [ ] 5.3 Fresh-install smoke: apply the pg_dump baseline + run migrations on
  an empty DB and confirm `startup_migrations` still succeeds unchanged.
- [ ] 5.4 Demonstrate the new flow end to end: add a throwaway ordinary
  column, `mix ash.codegen`, confirm a minimal diff migration + snapshot are
  produced (then revert the throwaway).
- [ ] 5.5 `openspec validate adopt-ash-codegen-migrations --strict`.
