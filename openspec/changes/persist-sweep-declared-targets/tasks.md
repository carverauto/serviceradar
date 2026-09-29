## 1. Persistence

- [x] 1.1 Ash resource `ServiceRadar.SweepJobs.SweepGroupDeclaredTarget`
      (`platform.sweep_group_declared_targets`, PK `(sweep_group_id, target)`,
      `device_uid` nullable, `source` in `static`/`srql`, `declared_at`),
      registered in the `SweepJobs` domain.
- [x] 1.2 Public `SweepCompiler.declared_targets/1` returning the group's
      static and SRQL-resolved device targets, built on the same
      normalize/paginate path `compile/3` uses. The existing compiler tests
      stay green unedited.
- [x] 1.3 Refresh module `ServiceRadar.SweepJobs.DeclaredTargets`:
      upsert-then-prune per group (device uid wins over static for the same
      target), system actor, bulk Ash writes.
- [x] 1.4 Notifier on `SweepGroup` targeting changes (create; update,
      `add_targets`, `remove_targets` touching `target_query` or
      `static_targets`) refreshing that group synchronously before the edit
      returns; failures are logged, never crash the caller.
      `record_execution` and schedule-only updates must not refresh.

## 2. Migration and view

- [x] 2.1 Migration: create the table (FK to `sweep_groups` ON DELETE
      CASCADE, index on `sweep_group_id`), backfill static targets from
      `sweep_groups` in SQL.
- [x] 2.2 Same migration: replace the `device_sweep_overlap` view's declared
      side with the new table + `sweep_groups` eligibility derivation,
      removing both `agent_config_instances` arms; rename
      `config_delivered_at` to `declared_at`; keep the validated matching
      machinery (containment-as-equality joins, grain, compat matching,
      availability attribution, profile masking) intact.
- [x] 2.3 `mix serviceradar.db.migrate` against a scratch database succeeds
      both up and down. (Round-tripped on the scratch fixture: down SQL
      validated manually after `mix ash.rollback` proved unusable there, and
      the round-trip found one real up-path defect -- `DROP VIEW` needed
      `IF EXISTS` -- which is fixed.)

## 3. SRQL column rename

- [x] 3.1 `rust/srql/src/query/device_sweep_overlap.rs`: order allowlist
      `config_delivered_at` -> `declared_at`.
- [x] 3.2 `rust/srql/src/query/viz/inventory.rs`: viz column metadata
      follows. `cargo fmt`, `cargo clippy`, `cargo test` in `rust/srql`
      (988 tests green).

## 4. Regression tests (fixture database)

- [x] 4.1 Declared persistence: a group create/update persists static and
      SRQL-resolved targets once per group (device uid retained; static and
      device target overlap collapses to one row); removing targets prunes
      rows.
- [x] 4.2 View classes on a fixture database: `declared_not_observed`
      (static target with no coverage), `declared_and_observed` (target with
      matching coverage), and `observed_not_declared` (coverage with no
      declaration) all appear; static targets included; fixed-subset group
      declares per selected agent and partition-wide group declares with a
      NULL agent that matches any observed agent.
- [x] 4.3 Each view-class test fails on the pre-fix view shape (no declared
      rows at all) for the intended reason. Verified by reinstalling the old
      view on the scratch fixture: all four view-class tests fail there and
      pass with the new view.

## 5. OpenSpec bookkeeping

- [x] 5.1 `refactor-sweep-config-shared-targets`: tick 1.1, record Decision 7
      (no production sweep instance writer; issue #4963; declared relation
      persisted per group by this change).
- [x] 5.2 `add-sweep-diagnostics-srql-entities`: annotate 3.7 (declared
      source moved from compiled config to the persisted declared relation)
      and 3.8 (sweep config instances confirmed never written; data source
      decision outstanding).
- [x] 5.3 `openspec validate persist-sweep-declared-targets --strict` and
      the two annotated changes still list cleanly.

## 6. Follow-up: inventory drift and query failures

- [x] 6.1 Record declared targets from `SweepCompiler.compile/3`
      (`DeclaredTargets.record_compiled/2`), skipping unchanged sets by
      digest.
- [x] 6.2 `SweepCompiler.declared_targets/2` returns `device: :unresolved`
      for a failed, raising or partly read target query;
      `DeclaredTargets.refresh/1` and the compile path keep the previous rows
      for such a group.
- [x] 6.3 One writer for both paths: a transaction behind a per-group
      `pg_try_advisory_xact_lock`, no rewrite when the stored rows already
      match.
- [x] 6.4 Tests: unit coverage of unresolved and partial queries; fixture
      database coverage of inventory drift picked up at compile, a failing
      query keeping rows, and an unchanged recompile keeping `declared_at`.
