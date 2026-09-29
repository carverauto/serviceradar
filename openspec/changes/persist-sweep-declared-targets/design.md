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
  `refactor-sweep-config-shared-targets`); refreshing declared targets on
  device-inventory drift; changing the observed side or the availability
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

- Declared device targets go stale between group edits (inventory drift
  changes the SRQL result set; nothing rewrites the rows until the group's
  targeting changes again). Accepted: the alternative is a periodic
  fleet-wide SRQL refresh worker, which is real scope, and today's baseline
  is that declared rows NEVER exist. The compiler stays the freshness
  authority for what agents actually receive.
- A refresh can fail (DB hiccup, SRQL error). An SRQL resolution
  failure degrades exactly as it does in `compile/3`: static targets still
  persist, the failed device resolution is logged per group. A persistence
  failure is logged and leaves the previous snapshot in place (upsert-then-
  prune ordering keeps the old set visible rather than an empty one).
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
