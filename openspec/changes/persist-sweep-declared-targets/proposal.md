# Change: Persist declared sweep targets per group

## Why

`in:device_sweep_overlap` can never report a declared sweep target in
production: the `platform.device_sweep_overlap` view builds its declared side
from `platform.agent_config_instances.compiled_config`, but no production code
path writes `config_type = 'sweep'` rows. `SweepCompiler.compile/3` returns an
in-memory map cached in ETS, so `relationship = 'declared_not_observed'` and
`'declared_and_observed'` never appear, and the entity's headline diagnostic
finds nothing (issue #4963).

## What Changes

- New table `platform.sweep_group_declared_targets` persisting the declared
  relation once per sweep group (not once per agent): `(sweep_group_id,
  target, device_uid, source, declared_at)` covering both SRQL-resolved device
  targets and static targets. A target that is both static and SRQL-resolved
  is one row, carrying the device uid.
- The relation refreshes when a sweep group's targeting changes (create,
  update touching `target_query`/`static_targets`, `add_targets`,
  `remove_targets`), via an Ash notifier dispatching one async refresh per
  group. Destroy cascades.
- Static targets of existing groups are backfilled in the migration (pure
  SQL); SRQL-resolved device targets appear after the first refresh of each
  group.
- The `device_sweep_overlap` view's declared side is rewritten to read the new
  table joined to `sweep_groups`, deriving agent eligibility from
  `agent_ids`/`partition` the way `SweepGroup :for_agent_partition` does:
  a fixed-subset group declares per selected agent, a partition-wide group
  declares once with a NULL agent compatible with any observed agent. Both
  `compiled_config` arms are gone. Disabled groups declare nothing, matching
  what the compiler delivers.
- The view column `config_delivered_at` is renamed `declared_at`: the value is
  now when the group's declared snapshot was taken, not when a compiled config
  was delivered to an agent. The SRQL order allowlist and viz metadata follow.
- Whole-document compiled-config persistence stays out of scope; it would
  fight `refactor-sweep-config-shared-targets`.

## Impact

- Affected specs: `sweep-jobs` (declared-target persistence), `srql`
  (overlap entity's declared source).
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/` (new table + view
    rewrite)
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/` (new resource,
    refresh module, notifier, `SweepGroup` notifier list)
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/sweep_compiler.ex`
    (public `declared_targets/1` reusing the compile-time resolution)
  - `rust/srql/src/query/device_sweep_overlap.rs`,
    `rust/srql/src/query/viz/inventory.rs` (column rename)
- Related: `refactor-sweep-config-shared-targets` task 1.1 (the audit it
  asked for is issue #4963; finding recorded in its design.md),
  `add-sweep-diagnostics-srql-entities` tasks 3.7/3.8 (declared source moves
  from compiled config to the persisted relation).
