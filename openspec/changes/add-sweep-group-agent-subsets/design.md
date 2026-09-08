# Design: Scalable sweep-group agent subset targeting

## Context

`ServiceRadar.SweepJobs.SweepGroup` stores one nullable `agent_id`. Nil or a
blank value means that every eligible agent in the group's device partition
receives the group; a value pins the group to that agent even when the agent's
control-session partition differs from the group's device partition. The
cross-partition case supports isolation scans and must remain valid.

The same scalar assumption appears in the `:for_agent_partition` Ash read,
sweep config compilation, `Run now`, result conflict detection, canonical
availability ownership, missed-sweep diagnostics, the composite-check coverage
view, and Settings summaries. The current form also calls an unpaginated
`Ash.read(Agent)` and renders the resulting active-agent list in a select.

The Devices view's Device Types modal provides the intended visual language,
native dialog behavior, stable autofocus, and bounded scrolling. Its data is a
small, already-loaded facet list and its filtering is in memory, so its data
strategy cannot be reused for a fleet-sized selectable agent list.

## Goals

- Let an operator assign a sweep group to all eligible partition agents or an
  exact fixed subset of known agents.
- Preserve existing single-agent and cross-partition isolation behavior.
- Keep the picker responsive without loading or rendering the whole fleet.
- Preserve draft selections while the operator searches and pages.
- Keep scheduled config delivery, on-demand dispatch, result ingestion, and
  coverage views consistent with the same assignment definition.
- Preserve the current agent-facing sweep config contract.

## Non-Goals

- Dynamic agent assignment expressions, agent tags, or saved agent cohorts.
- Selecting every agent matching an arbitrary search query.
- Changing device targeting, sweep profiles, schedules, or scan modes.
- Redesigning per-agent sweep health or replacing the existing group-level
  `last_run_at` latest-report marker.
- Turning the Device Types facet browser into a generic selection component.

## Decisions

### D1: Store one canonical `agent_ids` array

`SweepGroup` SHALL expose `agent_ids` as a public, non-null
`{:array, :string}` attribute with a default of `[]`:

- `[]` means every sweep-eligible agent whose agent partition matches the
  group's device partition.
- `[uid, ...]` means exactly those agents, regardless of their current agent
  partition. This preserves the existing isolation-scan behavior of a scalar
  pin.
- Writes trim values, remove nil/blank entries, de-duplicate UIDs, and sort the
  result so equality, config hashes, and form round trips are deterministic.
- A one-element array is behaviorally equivalent to today's scalar assignment.

The create and update actions validate every newly introduced UID with a scoped
read of `ServiceRadar.Infrastructure.Agent`; form parameters are not trusted.
Offline, degraded, disconnected, and unavailable agents remain valid fixed
assignments because scheduled config must reach them when they reconnect.
Capability is advisory at persistence time: the stored Agent capability list
can be stale while an agent is offline, and the former scalar field did not
require a capability. The UI displays the persisted capability snapshot, while
`Run now` uses the live control session's canonical `"sweep"` capability.

An unresolved UID already stored on a legacy or existing group remains visible
as unavailable and may survive unrelated edits. A create or update MUST reject
only an unknown UID newly added by that request. This prevents stale historic
assignments from silently broadening to all agents without blocking an
operator from changing a description or schedule before cleaning them up.

When agent gateway synchronization replaces a superseded agent UID after
re-enrollment, it replaces that UID wherever it appears in `agent_ids`,
preserves every other selected member, and normalizes/de-duplicates the result.
It writes the canonical array rather than the scalar bridge, so replacing a
first or non-first member cannot collapse the rest of the subset.

An array matches the established `SNMPProfile.agent_ids` convention and keeps
the membership check local to the sweep-group row. A GIN index supports
agent-membership reads. A join table would provide stronger referential
modeling and per-assignment metadata, but neither is required by this feature.
A dynamic query would make membership change without an explicit group edit
and is outside the fixed-subset request.

### D2: Use additive expansion with a fail-narrow scalar bridge

On a normal hooked Helm upgrade, the Helm pre-upgrade migration job finishes
before core and web-ng Deployments roll, so old and new application pods can
overlap briefly. An upgrade that uses `--no-hooks` or disables core migrations
must apply the migration externally before application pods roll. Removing
`agent_id` in that release would break the old pods, while mirroring a
multi-member array to nil would make
an old reader mistake the subset for an All assignment. The rollout therefore
retains a conservative scalar bridge.

**Expand:** author a narrowly scoped `add_sweep_group_agent_ids` Ecto migration
by hand, matching the established migration convention in this repository.
`priv/resource_snapshots/` is intentionally absent and gitignored, so
`mix ash.codegen` currently emits an unsafe whole-application migration rather
than a reviewable resource-local diff. The scoped migration will:

1. Add `agent_ids TEXT[] NOT NULL DEFAULT '{}'` while retaining `agent_id` and
   its partial index.
2. Backfill a non-blank `agent_id` as `ARRAY[agent_id]`; leave nil/blank rows as
   an empty array.
3. Add a GIN index on `agent_ids`.
4. Install a database compatibility trigger that mirrors an old writer's
   `agent_id` insert or actual scalar-value change into `agent_ids`. An update
   that resubmits the unchanged scalar while changing unrelated fields must
   preserve an existing multi-member array.

Deploy array-aware code after the expand migration. New code reads only
`agent_ids` for behavior and enables multi-agent selection immediately. Every
array-aware write also maintains a deterministic scalar bridge:

- `[]` stores scalar nil;
- any non-empty normalized array stores its first UID in scalar `agent_id`.

During the brief rolling overlap, an old reader therefore treats a multi-agent
group as assigned to one agent that is actually in the selection. That is a
temporary fail-narrow result, never an accidental expansion to every partition
agent. An old writer still supports only All/one-agent edits; the trigger
mirrors those writes into the canonical array for new readers.

Keep the trigger, scalar column, and partial scalar index through the rollback
window. A rollback binary can temporarily execute only the mirrored first
member of a multi-agent selection, but the complete array remains stored for
the next array-aware deployment. In a later ordinary deprecation, first ship
code that no longer writes the bridge; only a subsequent scoped Ecto migration
may remove the trigger, scalar index, and column. Its down path restores nil or
the first normalized UID from the retained array.

### D3: Use the same membership rule for config and coverage

The `:for_agent_partition` read returns an enabled group when either:

1. `agent_ids` is empty and the requesting agent's partition equals the
   group's device partition; or
2. the requesting agent UID is non-blank and is a member of `agent_ids`.

The second branch intentionally ignores partition. `SweepCompiler` continues
to call this read and emits the same group JSON it emits today. An unselected
agent never receives the group, and an absent requesting UID never receives a
group with a non-empty selection. Existing fleet-wide sweep dependency
invalidation remains unchanged so a membership edit removes stale config from
agents that were deselected as well as adding it to newly selected agents.

Composite-check sweep coverage uses the same read. Its `assigned?` flag becomes
an array membership check so an explicitly selected vantage point is distinct
from partition-wide coverage.

### D4: Use a dedicated server-paginated selection modal

The sweep-group form exposes two deliberate modes:

- **All eligible agents in this partition** stores `agent_ids: []`.
- **Selected agents** requires at least one UID and opens the picker.

The closed control displays `All agents`, one agent's display name, or
`N agents selected`. The picker is a dedicated component built with
`ui_modal`, token-styled fields/buttons/badges, and checkbox rows. It follows
the Device Types modal's native-dialog behavior, stable input ID,
`data-dialog-autofocus`, Escape/backdrop cancellation, and bounded list height.

`ServiceRadar.Infrastructure.Agent` gains a scoped `:agent_picker` Ash read
action with keyset pagination, a default and maximum page size of 50, and one
stable total order: case-folded `coalesce(name, uid)` ascending, then immutable
`uid` ascending. A trimmed case-insensitive search argument matches name or
UID. The opaque keyset cursor is valid only for the normalized search and that
fixed sort. Changing search clears the next/previous cursor history and starts
at page one; a stale cursor from another query is rejected and reset instead
of being reused. The LiveView keeps an explicit previous-cursor stack because
the generic pagination component does not own cursor history.

The sweep-group new/edit lifecycle removes the existing eager, unpaginated
`load_agents/1` call and does not assign a fleet-wide `@agents` collection.
Any other Networks page feature that still needs agent data uses a separate
lazy or bounded path, so merely opening a sweep-group form performs only the
bounded one-record/count summary work described below.

Rows show name, UID, partition, connection status, and the persisted sweep
capability snapshot. Known agents remain selectable when offline or when their
reported capabilities change; those facts are advisory operator context and
never cause an existing assignment to disappear silently. Scheduled config
eligibility uses stored UID membership. `Run now` separately requires the live
session's canonical `"sweep"` capability and reports a capability failure for
an online selected session that lacks it.

The parent LiveView owns one canonical pending form value. Assignment mode is
derived and enforced server-side: `:all` maps only to `agent_ids: []`, while
`:selected` maps only to a non-empty normalized list. Hidden
`form[agent_ids][]` inputs are rendered from this canonical value and are never
authoritative by themselves. Switching Selected to All clears stale IDs.
Opening the modal copies the canonical form selection into a separate draft
`MapSet`; form validation while the modal is open continues to use the prior
canonical selection. Apply commits the normalized draft, while Cancel, Escape,
or backdrop dismissal discards it. A submitted Selected mode with an empty
list is a validation error and never broadens to All.

Only the current 50-row result page is assigned/rendered. The draft `MapSet`
is the necessary membership footprint and is never pruned by search or
pagination. The closed control fetches one record only for a one-UID summary;
for multiple UIDs it renders the count without loading every selected Agent.
Missing selections are summarized by count and resolved only in bounded pages
when the operator browses them. A fleet or selection containing thousands of
UIDs therefore does not create thousands of Agent structs in LiveView assigns.

The modal has separate Browse and Selected views. The Selected view pages the
draft UIDs in stable UID order with at most 50 rows and resolves Agent details
only for that current UID page. A UID that no longer resolves renders as an
Unavailable placeholder carrying its raw UID. Every Selected row has an
individual remove action, so an operator can remove one unresolved assignment
without clearing or loading all other members.

The picker supports individual row toggles and clearing the full draft; it
does not implement ambiguous "all search results" selection. Query loading,
no-match, and recoverable error states retain the draft. A retry or new search
can recover without altering membership. The selected-count update is
announced through an `aria-live` region; checkbox labels include agent name,
UID, and status; pagination controls have directional labels; and every close
path restores focus to the stable picker trigger.

### D5: Fan out on-demand runs to the selected online subset

For `agent_ids: []`, `Run now` retains the current behavior: enumerate online
sweep-capable sessions in the group's device partition and dispatch to each.

For a non-empty array, the command bus dispatches once to every selected agent
that has an online sweep-capable control session. Each dispatch resolves the
agent's live control-session partition, preserving cross-partition isolation
assignments. Resolution reuses canonical-session filtering and requires one
unambiguous live partition; an ambiguous or non-canonical session is a
per-agent failure and never falls back to the group's device partition.
Dispatch is best effort:

- no successful dispatch returns an error;
- one or more successes returns success with successful command IDs and the
  per-agent failures;
- the UI reports the successful count and names offline/failed selections
  instead of presenting partial dispatch as complete success.

Offline assignment is not removed. The agent still receives scheduled config
when it reconnects.

The LiveView command-status model is keyed by group and reporting agent (or its
command ID), not only by `sweep_group_id`. ACK, progress, completion, and error
events update one member entry without overwriting another selected agent's
state. A derived group summary reports queued/running/succeeded/failed counts
and preserves the per-agent failure details returned by initial dispatch.

### D6: Separate expected multi-agent reporting from availability authority

Multiple reporters are expected when `agent_ids` is empty or contains more
than one UID. Result ingestion SHALL not emit the existing assigned-group
multi-agent conflict warning when every reporter is a member of the expected
assignment. A reporter outside a non-empty assignment is anomalous and is
logged with the group and agent IDs. This includes a recently deselected agent
finishing work from stale cached config.

Expected or anomalous assignment is separate from availability authority.
Every authenticated reporter continues to produce its per-agent execution and
latest availability observation for forensics. A stale/deselected reporter
does not gain implicit canonical authority merely by naming the group, but its
observation is not discarded.

The active `add-per-agent-availability` change remains the single owner of
canonical `is_available` derivation:

- when `availability_source_agent_id` is configured, the latest fresh
  observation from that agent drives canonical availability;
- without an explicit source, the deterministic consolidated fallback
  preserves existing single-agent behavior and considers only observations
  from reporters expected by the effective sweep assignment at ingestion;
- an unexpected reporter's observation is retained for forensics but excluded
  from that no-source fallback; an explicitly configured source remains
  authoritative because that authority is explicit rather than inferred from
  the group report;
- assignment cardinality does not introduce a second, conflicting canonical
  derivation rule.

If this change lands before `add-per-agent-availability`, implementation keeps
the current fail-closed source-pin guard for shared groups until the configured
source/fallback policy replaces it. Tests must cover the composed final policy,
not permanently encode two definitions.

`last_run_at` remains a group-level timestamp for the latest reported
execution by any effective member; it is not a schedule or dispatch marker.
One member's report can therefore keep the existing group-level missed-sweep
check current. Per-member missed-sweep health is explicitly not added here and
must be read from the independent execution rows. Missed-sweep events replace
the scalar assignment field with `agent_ids` and do not claim that every
selected member reported.

### D7: Preserve authorization and bound memory

The existing `settings.networks.manage` route/resource authorization remains
the gate for editing sweep groups. Agent search and save-time validation use
the current scope. Submitted UIDs are never accepted solely because they were
present in hidden fields.

The LiveView holds at most one 50-row page plus the selected UID set and a
bounded one-record/count summary. Search is debounced by 200 ms and stale page
cursors are reset when the query changes.

## Risks / Trade-offs

- **Array membership query regressions.** Verify the generated SQL uses the GIN
  index for non-empty membership and add compiler tests for empty, one, and
  many assignments.
- **Selection becomes stale while editing.** Save-time scoped validation is
  authoritative for newly added UIDs; pre-existing unresolved UIDs remain
  visible and survive unrelated edits instead of being silently dropped.
- **Partial `Run now` dispatch.** Returning per-agent failures makes the
  best-effort behavior explicit while allowing reachable selected agents to
  run immediately.
- **Multi-agent availability flapping.** Persist each reporter independently
  and use the configured-source/deterministic-fallback policy owned by
  `add-per-agent-availability`; do not invent assignment-specific precedence.
- **Rolling-version incompatibility.** Expand/backfill plus the first-selected
  scalar bridge keep old pods fail-narrow: they may temporarily deliver a
  multi-agent group to one selected member, but never to an unselected member
  or the whole partition. The canonical array remains intact across rollback.
- **Concurrent sweep-profile UI work.** Keep picker state/events in focused
  modules and rebase around `add-sweep-profile-mtr-mode` rather than rewriting
  unrelated profile controls.

## Migration Plan

1. Author/review the scoped Ecto migration that adds and backfills
   `agent_ids`, creates its GIN index, retains `agent_id`, and installs the
   old-writer compatibility trigger.
   On a normal Helm upgrade this is the pre-upgrade hook; a no-hooks or
   migrations-disabled upgrade must apply it externally before the rollout.
2. Deploy array-aware core and web-ng code that reads `agent_ids`, enables
   subsets immediately, and mirrors nil for All or the first normalized UID for
   every non-empty assignment.
3. Verify representative legacy rows: nil becomes `[]`, one UID becomes a
   one-element array, and compiled eligibility is unchanged.
4. During a mixed-version test, verify an old scalar reader sees only the first
   selected UID for a multi-member row and never interprets it as All; verify an
   old scalar writer is mirrored into the array.
5. Verify a multi-agent row reaches exactly its selected agents under new code, maintains
   independent command status, and is removed from a deselected agent after
   config invalidation.
6. Keep the bridge through the rollback window. Deprecate scalar writes in one
   later release, then remove the trigger/index/column in a subsequent cleanup.
