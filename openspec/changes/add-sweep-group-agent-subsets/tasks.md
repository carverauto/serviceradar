# Tasks: Scalable sweep-group agent subset targeting

## 1. Sweep-group assignment model

- [x] 1.1 Add normalized `SweepGroup.agent_ids`, accept it on create/update,
  validate newly added UIDs through a scoped Infrastructure Agent read, and
  preserve pre-existing unresolved UIDs during unrelated edits.
- [x] 1.2 Author a narrowly scoped expand Ecto migration: add/backfill/index
  `agent_ids`, retain `agent_id`, and install the rolling-compatibility scalar
  mirroring trigger. Do not use `mix ash.codegen` while resource snapshots are
  absent because it emits a whole-application migration.
- [x] 1.3 Make new code read only `agent_ids` behaviorally and enable subset
  submission immediately; dual-write scalar nil for All and the first
  normalized selected UID for every non-empty assignment so old readers fail
  narrow during the rolling overlap.
- [x] 1.4 Keep the old-writer trigger/scalar/index through the rollback window;
  verify an old reader sees at most one actually selected UID and an old writer
  is mirrored into the array.
- [ ] 1.5 In later deprecation releases, first remove application scalar writes,
  then author the scoped Ecto cleanup that removes the trigger, scalar index,
  and column after no current or rollback binary references them.
- [x] 1.6 Replace a superseded agent UID wherever it occurs in an explicit
  subset during agent gateway synchronization, preserving every other member
  and de-duplicating when the replacement is already selected.
- [x] 1.7 Update `:by_agent`, `:for_agent_partition`, documentation, summaries,
  and fixtures to use empty-array or nonblank membership semantics.
- [x] 1.8 Add resource/read-action, query-plan, migration, and Helm migration
  version/ordering tests for legacy all-agent
  behavior, one/many membership, nil requesting agent, de-duplication, blank
  removal, newly unknown versus grandfathered stale UIDs, advisory capability,
  cross-partition agents, old-writer mirroring, fail-narrow multi-member scalar
  projection, UID supersession in first/non-first positions, GIN index
  usability, and array preservation across rollback. Normal hooked Helm
  upgrades run the migration before pods roll; no-hooks or migrations-disabled
  upgrades must apply it externally first.

## 2. Config compilation and coverage

- [x] 2.1 Update sweep config loading so every selected agent receives the
  group, unselected/nil agent identities do not receive selected groups, and
  empty assignments remain partition-wide.
- [x] 2.2 Preserve fleet-wide sweep dependency invalidation on membership edits
  so deselected agents drop stale groups and newly selected agents receive them.
- [x] 2.3 Update composite-check sweep coverage and assignment labels to use
  `agent_ids` membership.
- [x] 2.4 Add compiler/distribution, `SweepContext`, and direct
  `ServiceRadar.CompositeChecks.Validation.Coverage` tests for empty, single,
  multiple, nil-agent, deselected, and cross-partition assignments; assert the
  compiled agent JSON schema is unchanged.

## 3. On-demand dispatch and execution semantics

- [x] 3.1 Extend `AgentCommandBus.run_sweep_group/2` to dispatch a non-empty
  selection to each selected agent's live control-session partition.
- [x] 3.2 Return successful command IDs and per-agent failures for partial
  subset dispatch; treat missing capability or ambiguous/non-canonical control
  sessions as explicit per-agent failures and retain an error when none succeed.
- [x] 3.3 Key command status by group plus agent/command ID and derive a group
  aggregate so later ACK/progress/completion events cannot overwrite another
  selected agent's state.
- [x] 3.4 Update the sweep-group LiveView event and status presentation to
  distinguish complete, partial, and zero-success dispatch and retain member
  failure details.
- [x] 3.5 Add command-bus and LiveView tests for all selected online, mixed
  online/offline/capability, all offline, exact membership, cross-partition
  sessions, ambiguous sessions, and independent asynchronous member updates.

## 4. Result ownership and diagnostics

- [x] 4.1 Replace scalar conflict detection with expected-assignment logic for
  empty, one, and many selections.
- [x] 4.2 Suppress conflict warnings for expected selected reporters, warn for a
  reporter outside a non-empty assignment, and retain its per-agent execution
  and availability observation for stale-config forensics.
- [x] 4.3 Integrate canonical availability with
  `add-per-agent-availability`: configured source wins, otherwise use its
  deterministic consolidated fallback over expected reporters only; retain an
  unexpected reporter's observation for forensics but exclude it from the
  unconfigured fallback, and do not add assignment-cardinality precedence.
- [x] 4.4 Update missed-sweep payloads and operator summaries from `agent_id` to
  `agent_ids`; document/test that `last_run_at` is the latest report from any
  member and does not prove every member reported.
- [x] 4.5 Add result-ingestion tests for expected multi-agent reporting,
  recently deselected stale-config reporters, configured-source and fallback
  availability, unexpected reporters, and fail-closed missing group/execution
  identity.

## 5. Server-paginated agent picker

- [x] 5.1 Add a scoped `Agent.:agent_picker` Ash read with case-insensitive
  name/UID search, keyset default/max page size 50, and stable
  case-folded-name-plus-UID ordering; remove the sweep-group lifecycle's eager
  unpaginated `load_agents/1`/`@agents` path without breaking other Networks
  page consumers.
- [x] 5.2 Add focused picker state/events for open, search, next/previous page,
  Browse/Selected view changes, row toggle/removal, clear, Apply, and Cancel;
  retain a draft `MapSet`, bind opaque browse cursors to the normalized
  query/sort, maintain previous-cursor history, and reset stale cursors on
  query changes.
- [x] 5.3 Replace the scalar select with explicit All/Selected modes, a concise
  assignment summary, and canonical `form[agent_ids][]` inputs; enforce
  `All -> []` and `Selected -> nonempty` server-side so crafted/validation
  events cannot accidentally broaden a subset.
- [x] 5.4 Build the modal with `ui_modal`, stable debounced autofocus, checkbox
  rows, status/partition/capability metadata, bounded scrolling, pagination,
  retained-draft loading/no-match/error recovery, announced selection count,
  semantic labels, directional pagination labels, and trigger focus restoration.
- [x] 5.5 Bound summary loading: fetch one Agent only for a one-UID summary,
  render count-only summaries for larger sets, and page the Selected view in
  stable UID order with at most 50 resolved Agent or raw unavailable rows.
- [x] 5.6 Update sweep-group list/detail summaries and render grandfathered
  stale selected IDs as unavailable without blocking unrelated edits.
- [x] 5.7 Add LiveView/component tests for stable ordering, forward/back cursor
  navigation, stale-query cursor reset, selection retention, canonical form
  modes during validation, Apply versus every cancel path, focus restoration,
  `aria-live` updates, query failure recovery, advisory capability/status,
  individually removing stale selections, and fleets/selections with thousands
  of UIDs without executing or rendering the eager full-fleet Agent read.

## 6. Verification and documentation

- [x] 6.1 Run `mix format` and the focused `serviceradar_core` resource,
  compiler, command-bus, result-ingestion, and composite-check tests.
- [x] 6.2 Run the focused web-ng LiveView/component tests and verify each new
  test is actually selected by its Bazel shard.
- [x] 6.3 Run the affected Bazel test targets, then the repository-required
  `make test` unit sweep before opening a pull request.
- [x] 6.4 Verify expand/backfill, old-writer mirroring, and fail-narrow scalar
  projection against nil, single-agent, and multi-agent rows; leave scalar
  cleanup to the later deprecation release.
- [x] 6.5 Run `openspec validate add-sweep-group-agent-subsets --strict` and
  update `docs/docs/network-sweeps.md` with All/Selected assignment semantics
  and the scalable picker workflow.
