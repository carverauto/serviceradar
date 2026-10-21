# Change: Hold policy-derived plugin assignments when target queries resolve empty

## Why
The policy assignment reconciler treated a target query that resolved zero rows
as "no targets" and disabled every enabled assignment of that policy as stale.
An empty result is just as likely to mean the target is temporarily unknown: a
device whose primary address changed, an inventory that has not been ingested
yet, or a degraded query backend that answers with no rows. A credential rule
for a working camera integration lost both of its assignments that way. Nothing
named the rule or the reason, and the plugin simply disappeared from the agent.

## What Changes
- When an enabled policy or credential rule resolves zero target rows, the
  reconciler keeps its enabled assignments unchanged instead of disabling them.
- The reconcile result reports `held` (rows kept) and
  `hold_reason: :targets_unresolved`. The reconciler logs a warning naming the
  policy id and agents and emits
  `[:serviceradar, :plugins, :policy_assignments, :targets_unresolved]`
  telemetry.
- The credential-rule materializer reports a held rule as the skip reason
  `targets_unresolved`, which appears in the reconcile worker's summary line and
  in the existing credential-rule reconcile telemetry. A target policy's
  `reconcile_now` stores the result, hold fields included, in its existing
  `last_reconcile_summary`.
- Retraction is unchanged when the policy is disabled, and when the query
  resolves rows that no longer include an assignment.
- The AWX inventory-sync reconciler opts out
  (`hold_unresolved_targets: false`): its rows are the enabled controller list
  itself, so an empty list means every controller was removed.
- A resolver error already halts the reconcile before any write, and it still
  does.

## Follow-up: owner lifecycle retraction
The periodic credential-rule worker only loads enabled rules in scope for an
agent, and the periodic target-policy worker only loads enabled policies.
Disabling a rule or policy, deleting it, or narrowing its scope therefore never
reached the reconciler, and its assignments kept running. Grant issuance for a
disabled rule is refused, but the assignment itself stayed enabled.

- The owner's own update and destroy actions now retract its enabled
  assignments in the same transaction: all of them when it is disabled
  (`owner_disabled`) or deleted (`owner_deleted`), and those of agents it no
  longer covers when its scope narrows (`owner_scope_narrowed`). A target
  policy's coverage comes from resolving its input definitions; zero rows
  retracts nothing, as in the reconciler.
- `plugin_assignments` gains catalog-only `disabled_reason`, `disabled_by` and
  `disabled_at` columns, cleared when an assignment is enabled again.
- Assignments orphaned before this change are not disabled by the migration or
  any periodic job. Core reports them, and an operator with
  `settings.plugins.manage` retracts a selected set or all of them from the
  plugins page with the reason `orphaned_owner_cleanup`.
- The reconcilers' assignment store checks, under a share lock on the owner
  row and in the write's transaction, that the owner still admits an enabled
  assignment before writing it. A reconcile that loaded the owner before it
  changed can therefore not write a retracted assignment back. Orphan cleanup
  decides eligibility under the same locks.
- The periodic reconcilers still load only enabled owners and never retract a
  disabled owner's assignments on their own.

## Impact
- Affected specs: `wasm-plugin-system`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/plugins/owned_assignment_retraction.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/changes/retract_owned_assignments.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/plugin_assignment.ex`
  - `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_rule.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/plugin_target_policy.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/plugin_package_live/index.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/policy_assignment_reconciler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/credentials/plugin_assignment_materializer.ex`
  - `elixir/serviceradar_core/lib/serviceradar/automation/ansible/awx_inventory_sync_reconciler.ex`
