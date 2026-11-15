# Change: Read policy target queries whole, never one SRQL page

## Why

`SRQLInputResolver.resolve/2` ran each target query once with no limit, and
SRQL answers such a request with its first 100 rows. Every caller treated that
page as the whole selection:

- credential rule materialization and plugin target policy reconciliation
  planned assignments for at most the first 100 selected devices, so the rest
  never received an assignment and nothing reported it;
- narrowing a target policy's inputs treated every agent past the first page as
  no longer covered and retracted its assignments;
- producer schedules with a `target_query` dispatched to at most the agents in
  the first page, and `target_input` reported a total of at most 100, so the
  truncation flag the run summary relies on never fired;
- the credential rule preview, the rule dry run and the target policy preview
  reported at most 100 matches.

`refuse-oversized-addon-profiles` added `SRQLInputResolver.reduce_pages/4` and
moved add-on profiles onto it; these callers were left on the single page.

## What Changes

- `SRQLInputResolver.resolve/2` reads each input's whole selection a page at a
  time through `reduce_pages/4`. A selection that cannot be read whole (a
  failed page, or a full page past SRQL's cursor window) is an error, never a
  shorter row list. No single-page resolver read remains.
- The unique `sort:uid:asc` tie-break for paged `in:agents` reads moves from
  the add-on profile reconciler into `reduce_pages/4`, so every paged agents
  read gets it.
- Previews report the true total beside a bounded sample that is labelled as a
  sample; `target_input` keeps its approved contract of delivering at most
  `max_items` with the true total and the truncation flag.

## Impact

- Affected specs: `wasm-plugin-system`.
- Affected code: `ServiceRadar.Plugins.SRQLInputResolver`, and through it
  `PolicyAssignmentReconciler` (credential rules and target policies),
  `OwnedAssignmentRetraction`, `PluginTargetPolicyOps`,
  `ProducerScheduleDispatcher`, `NetworkCredentialRulePreview` and
  `PluginAssignmentMaterializer.dry_run_rule/2`.
