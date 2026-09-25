# Change: IRE-style de-duplication tasks for identity decisions DIRE cannot make

## Why

DIRE had two outcomes for a suspected duplicate: merge it automatically, or refuse and emit
telemetry. With `add-identity-decision-log` every refusal is now a persisted identity decision,
but nothing turns those records into work an operator can finish. Ambiguous cases were either
merged on weak evidence or left in a table nobody acts on (#4604). ServiceNow's CMDB
Identification and Reconciliation Engine solves the same problem with de-duplication tasks: when
it finds duplicates it cannot reconcile safely it opens a task instead of merging.

## What Changes

- `ServiceRadar.Inventory.DeduplicationTask` (`platform.identity_deduplication_tasks`): the
  candidate device set, the category (the kind of decision that opened it), the latest decision
  kind, reason and evidence, an occurrence count, status (`open`, `merged`, `distinct`,
  `dismissed`), and who resolved it, when, into which survivor, with what note.
- Exactly one task per candidate set for its whole life: every identity decision naming two or
  more devices (`policy_block`, `guard_block`, `source_block`, `alias_invalidated`,
  `ip_conflict`, `source_override`, and the new `component_block`) opens the set's task or
  counts on it. A repeat never opens a second task and never reopens a resolved or dismissed
  one. `Identity.DecisionLog` calls `Identity.Deduplication.open_for_decisions/1` after writing
  each batch of decisions.
- The scheduled duplicate sweep records each ambiguous component it declines as a
  `component_block` decision (bounded by the run record's capture limit), so it opens a task too.
- Operator actions (operator role; tasks are readable by any viewer):
  - **merge** into a chosen survivor, through the administrative merge path
    (`MergeEngine.merge_devices/3`, reason `manual_dedup_task`, the requesting actor recorded in
    the merge details);
  - **mark distinct**, which writes a durable `DistinctDeviceAssertion` for every pair
    (`platform.identity_distinct_assertions`); `MergeEngine.merge_devices/3` refuses every
    automatic merge of an asserted pair (guard `asserted_distinct`), and every automatic path --
    ingest, alias, registration and the scheduled backfill -- merges through it;
  - **dismiss**, and **reopen** a dismissed task.
- A decision about devices already asserted distinct (every pair) opens no task; the decision
  row still records the refusal.

## Impact

- Affected specs: `device-identity-reconciliation` (ADDED "Identity De-duplication Tasks").
- Affected code: `elixir/serviceradar_core` identity modules, one migration.
- Depends on `add-identity-decision-log` (#4613).
- Not in this change (tracked for a follow-up): the web-ng review queue, an SRQL entity for
  tasks and decisions, and MCP visibility. The resources are readable through Ash by any viewer
  and resolvable by operators through `Identity.Deduplication`.
- The DIRE formal model's `NoSilentDecision` (every resolution goal configuration) is the
  property "no ambiguous or overridden identity decision is silent" that #4604 asks for.
