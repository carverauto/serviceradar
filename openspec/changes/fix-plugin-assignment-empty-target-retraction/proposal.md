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

## Known gap (not changed here)
The periodic credential-rule worker only loads enabled rules in scope for an
agent, and the periodic target-policy worker only loads enabled policies.
Disabling a rule, deleting it (which requires disabling it first), or narrowing
its scope therefore never reached the reconciler. Its assignments were not
retracted before this change either. Grant issuance for a disabled rule is
already refused, so such an assignment cannot obtain credential material. With
this change, a target query that resolves empty no longer retracts either.
Explicit retraction of a disabled, deleted or out-of-scope rule's assignments is
left to a follow-up change.

## Impact
- Affected specs: `wasm-plugin-system`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/plugins/policy_assignment_reconciler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/credentials/plugin_assignment_materializer.ex`
  - `elixir/serviceradar_core/lib/serviceradar/automation/ansible/awx_inventory_sync_reconciler.ex`
