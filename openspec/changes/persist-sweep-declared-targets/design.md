# Design: persist-sweep-declared-targets

## Context

`platform.device_sweep_overlap` answers "which sweep groups were told to
target this device versus which actually produced coverage" (issue 4167). Its
declared side reads `agent_config_instances.compiled_config` under
`config_type = 'sweep'`, but `SweepCompiler.compile/3` only ever populates the
in-memory `ConfigCache`; `ConfigServer` reads `ConfigInstance` only as a
fallback for config types that have no compiler, and sweep has one. So the
declared side is empty in every deployment and the entity's alert
(`declared_not_observed`) cannot fire (issue #4963).

The sweep-diagnostics plan assumed the resolved target list "survives in the
compiled config ... versioned per agent"; it does not, and
`refactor-sweep-config-shared-targets` is about to make per-agent documents
smaller, not persisted.

## Goals / Non-Goals

- Goals: make every relationship class of `device_sweep_overlap` reachable in
  production; persist one small row per (group, target); keep the compiled
  document ephemeral.
- Non-Goals: persisting compiled sweep config documents (works against
  `refactor-sweep-config-shared-targets`); a periodic refresh worker
  (inventory drift is handled by recording at compile time instead, see the
  follow-up decision below); changing the observed side or the availability
  attribution columns; any Go agent change.

## Decisions

- Decision: persist the declared relation per GROUP, not per agent. One row
  per `(sweep_group_id, target)`, with nullable `device_uid` for SRQL-derived
  targets. Persisting per-agent compiled documents was rejected in the issue:
  multi-megabyte rows per agent, rewritten on every change, working against
  the shared-targets refactor.
- Decision: the view derives agent eligibility from `sweep_groups`, mirroring
  `SweepGroup :for_agent_partition`: `agent_ids @> [agent]` for fixed-subset
  groups, `agent_ids = [] and partition = agent_partition` for partition-wide
  groups. Concretely the declared side CROSS JOINs
  `unnest(CASE WHEN cardinality(agent_ids) = 0 THEN ARRAY[NULL::text] ELSE
  agent_ids END)`: a partition-wide group declares once with a NULL agent
  (compatible with any observed agent under the existing compat matching),
  and a fixed-subset group declares once per selected agent so
  `declared_not_observed` names the agent that owes the sweep. Isolation
  scans (agent partition != device partition) are represented by exactly the
  agent ids in `agent_ids`; the view's `sg.partition` device-resolution scope
  is unchanged.
- Decision: refresh on sweep-group TARGETING changes only: create, and
  update/`add_targets`/`remove_targets` that change `target_query` or
  `static_targets`. Agent assignment, partition, enabled, name and profile
  changes do not rewrite rows -- the view reads those live from
  `sweep_groups`, which is also why `record_execution` (a hot per-run
  update of `last_run_at`) must not trigger a refresh. An Ash notifier
  refreshes the group just saved in the caller's process, so an earlier
  edit cannot overwrite a later one. Group destroy needs no hook: the FK
  cascades.
- Decision: the refresh reuses the compiler's own target resolution. A new
  public `SweepCompiler.declared_targets/1` returns
  `%{static: [target], device: [%{target:, device_uid:}]}` from the same
  normalize/paginate/normalize-ip path `compile/3` uses, so the persisted
  relation is what the compiler would deliver.
  `refactor-sweep-config-shared-targets` will optimize query evaluation
  underneath this seam (its task 2.1 evaluates each distinct query once per
  compile); it does not invalidate the seam.
- Decision: static targets are persisted too, not read from
  `sweep_groups.static_targets` in the view. One declared source means one
  view arm (both old `compiled_config` arms disappear), one `declared_at`
  covering the whole set, and no cross-arm dedup. The migration backfills
  static targets from `sweep_groups` in pure SQL; SRQL-derived targets
  appear after each group's first refresh. This is a deliberate half-fresh
  backfill: a declared_not_observed alert for a static target is exact
  immediately, and a device target becomes declared the next time the group
  is edited.
- Decision: rename the view column `config_delivered_at` to `declared_at`.
  The old name described `agent_config_instances.last_delivered_at`; the new
  value is when the group's declared snapshot was taken. Keeping the old
  name would publish a wrong meaning in every row. The SRQL order allowlist
  and viz metadata follow; no web-ng filter surface referenced the old name.
- Decision: the view keeps the matching machinery (inet containment turned
  into equality joins, the output grain, compat matching, availability
  attribution, profile masking) exactly as validated in the original
  migration -- only the declared source and the eligibility derivation
  change. Do not "simplify" it back toward the obvious shape; the original
  migration's warnings still apply.

## Risks / Trade-offs

- Inventory drift. As first shipped, declared device targets went stale
  between group edits: a device added to or removed from inventory changes
  the SRQL result set, and nothing rewrote the rows until the group's
  targeting changed again. The follow-up below records at compile time, so
  the rows follow the targets agents actually receive.
- A refresh can fail (DB hiccup, SRQL error). As first shipped, an SRQL
  resolution failure degraded as in `compile/3` (no device targets), and the
  refresh then pruned the group's SRQL rows. The follow-up below keeps them
  instead. A persistence failure is logged and rolls back, leaving the
  previous snapshot in place.

## Follow-up: record at compile time; keep rows on query failure

- Decision: `SweepCompiler.compile/3` records each group's declared targets
  from what it just compiled for the agent
  (`DeclaredTargets.record_compiled/2`), so query-derived rows follow
  inventory changes without a periodic worker and match what agents
  received. The notifier still records immediately on targeting edits.
- Decision: a group whose target query failed, raised or was only partly
  read is not written. `SweepCompiler.declared_targets/2` returns
  `device: :unresolved` for it and `compile_groups_with_resolution/3` reports
  it, so a transient SRQL error keeps the previous declaration instead of
  pruning it to "declares no devices". The agent still receives whatever
  the partial read produced.
- Decision: both paths share one writer: one transaction that takes a
  per-group `pg_try_advisory_xact_lock` (a writer finding it taken skips,
  since another writer is recording the same group), skips the write when
  the stored rows already equal the set (so `declared_at` moves only when
  the declaration changes), then upserts and prunes. The compile path also
  keeps a digest of the last recorded set under the `:sweep` config type, so
  an unchanged group costs no database round trip.
- Legacy `agent_ids` rows written before normalization could carry
  duplicates; the declared side keeps a cheap GROUP BY dedup so one
  duplicate agent id cannot fan out declared rows.

## Migration Plan

1. New migration creates `platform.sweep_group_declared_targets`, backfills
   static targets from `sweep_groups`, then drops and recreates
   `platform.device_sweep_overlap` with the new declared side.
2. Rollback drops the view and the table. The old view shape is not
   restored: its declared source never existed in production, so restoring
   it restores an empty arm.

## Open Questions

- None blocking. `sweep_compiled_config` (task 3.8 of
  `add-sweep-diagnostics-srql-entities`) still needs a decision about its
  data source now that sweep instances are confirmed never written; this
  change only annotates that task.
