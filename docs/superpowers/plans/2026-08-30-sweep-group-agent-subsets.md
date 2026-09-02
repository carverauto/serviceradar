# Sweep-Group Agent Subsets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Make sweep groups target all eligible agents in their device partition or an explicit fixed subset of agents, with exact per-agent dispatch/results, a bounded server-paginated picker, and a mixed-version-safe rollout.

**Architecture:** `SweepGroup.agent_ids` becomes the canonical assignment value (`[]` means partition-wide; a non-empty normalized UID list means exactly those agents). A pure assignment module defines normalization, membership, stale-ID preservation, and a fail-narrow scalar bridge; Ash changes and validations enforce it at persistence. During the brief Helm rolling overlap, old readers see nil for All or the first normalized selected UID for any non-empty selection, so they can never broaden a subset. Every new compiler and coverage consumer reuses `SweepGroup.:for_agent_partition`. Run-now dispatch resolves each selected agent through the live canonical control registry and publishes structured per-member outcomes. Result ingestion keeps per-agent forensic observations while canonical availability uses the configured source or expected reporters only. The LiveView picker keeps bounded, server-side keyset pages and a draft `MapSet`; the form submits only canonical `agent_ids`.

**Tech Stack:** Elixir, Ash/AshPostgres, Ecto/PostgreSQL, Phoenix LiveView/HEEx, Oban, PubSub, ExUnit, Vitest, Bazel, OpenSpec.

**Spec:** `openspec/changes/add-sweep-group-agent-subsets/`

## Global Constraints

- This plan ships the additive migration and array-aware application behavior together. Multi-agent selection is enabled immediately; there is no manual cutover or feature flag.
- The hand-written expand migration is required because `priv/resource_snapshots/` is absent and gitignored; `mix ash.codegen` currently produces a whole-application migration.
- `agent_ids: []` is the only all-agent representation. A non-empty list is normalized by trim, blank removal, deduplication, and UID sort.
- Array-aware code accepts zero, one, or many UIDs. It mirrors scalar nil for `[]` and the first normalized UID for every non-empty array so any old reader fails narrow during the 10–30 second rolling overlap.
- Existing unresolved IDs survive unrelated edits. Only newly introduced UIDs are looked up and rejected when absent. Agent capability and liveness are advisory when saving, authoritative only for Run now.
- Explicit selections cross device partitions. Empty assignments remain restricted to the group's device partition. A nil/blank requesting agent never receives a non-empty selection.
- All metrics/results remain on the existing JetStream/event-writer path; this feature adds no direct metric database path.
- Do not add shell scripts, processes, or new dependencies.
- Do not load the entire Agent resource during NetworksLive mount, group edit, group validation, or group rendering. Browse and Selected pages are each capped at 50 rows.
- Keep mapper/discovery agent selection working through a separately named lazy loader on mapper/discovery routes only.
- Use strict TDD: add a behavior test, run it and read the expected failure, then add the minimum production change. Mutation-check at least one assertion per behavior slice.
- Database-backed tests must be registered in `test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` and run through the guarded scratch-CNPG workflow. Database-free tests must carry `@moduletag :db_free` and be proven selected by their Bazel shard.
- On a normal hooked Helm upgrade, the pre-upgrade migration MUST complete before array-aware pods start. An operator using `--no-hooks` or disabling core migrations MUST apply the migration externally before rolling application pods. Do not add the web wait-for-migrations init container to core blindly: the migration hook is `post-install` on a fresh install, so making core wait before that hook runs would deadlock installation. The compatibility trigger/scalar/index remain after rollout and are removed only by later deprecation releases after no supported rollback binary references them.

---

## Task 1: Canonical assignment model and expand migration

**Files:**

- Create: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/agent_assignment.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/changes/normalize_agent_assignment.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/validations/agent_assignment.ex`
- Create: `elixir/serviceradar_core/priv/repo/migrations/20260830120000_add_sweep_group_agent_ids.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/agent_assignment_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_group_assignment_integration_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_group_agent_ids_migration_db_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_group.ex`
- Delete after replacement: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/changes/blank_agent_id.ex`
- Modify: `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`
- Modify: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/dispatch_sweep_run_test.exs`
- Modify: `helm/serviceradar/values.yaml`
- Create: `helm/serviceradar/tests/core_migrations_hook_test.yaml`

**Stable interfaces:**

```elixir
@spec normalize(term()) :: [String.t()]
@spec member?([String.t()], term()) :: boolean()
@spec newly_added([String.t()], [String.t()]) :: [String.t()]
@spec scalar_mirror([String.t()]) :: String.t() | nil
```

### Step 1: Prove normalization and compatibility semantics red

- [ ] Add `@moduletag :db_free` tests covering nil, scalar strings, lists, whitespace, blanks, duplicates, deterministic UID sorting, membership with a nil requester, set difference, and scalar mirrors for zero/one/many members.
- [ ] Run and read the failure caused by the missing module:

```bash
bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_other
```

### Step 2: Implement the pure assignment contract

- [ ] Implement only the four interfaces above. Normalize with binary-safe `to_string/1` only for scalar/list values accepted by the form; reject maps and nested collections rather than serializing them.
- [ ] Re-run the focused test, then mutation-check sorting, nil membership, and the many-member scalar mirror.

### Step 3: Prove resource writes and stale-ID validation red

- [ ] Add integration tests that create/update `SweepGroup` through its Ash actions with a real authorized operator actor. Cover `[]`, one UID, multiple UIDs, scalar nil/first-member bridge values, unknown newly added UID rejection, and an existing unresolved UID surviving an unrelated update.
- [ ] Assert known agents are validated by authorized `Infrastructure.Agent` reads using the actor available in the Ash changeset/validation context; do not accept a system-actor bypass as the only tested path. Web call sites still pass `scope:` so their actor is propagated through the resource call.
- [ ] Assert capability/liveness do not block persistence.
- [ ] Register both new DB-backed test files in `test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` with their real ownership/isolation requirements before running them.
- [ ] Run the focused test through the scratch database and confirm the first failure is the missing `agent_ids` attribute/change, not missing database credentials.

### Step 4: Wire the Ash resource

- [ ] Add public, non-null `agent_ids :array, :string`, default `[]`, include it in create/update fields, and add a named GIN index `sweep_groups_agent_ids_gin_idx`.
- [ ] Replace `BlankAgentId` with `NormalizeAgentAssignment`. It must normalize changed array input, derive array input from legacy scalar input only when the array was not supplied, and change the scalar mirror in the same changeset only when the existing scalar is not already equivalent.
- [ ] Add `Validations.AgentAssignment` after normalization. It must compare incoming normalized IDs with the stored normalized list and query only newly added UIDs with the authorized actor carried by the Ash changeset/validation context. Keep `scope:` at web call sites so the correct actor reaches the changeset.
- [ ] Keep update non-atomic for original-record comparison; do not weaken `:run_now` atomicity or add opacity/apply workarounds.
- [ ] Re-run the resource integration tests and existing `dispatch_sweep_run_test.exs`.

### Step 5: Prove the migration's trigger behavior red

- [ ] Add a DB migration test that requires the migration module, creates a temporary scalar/array fixture table, and runs exported helper SQL against it.
- [ ] Cover legacy nil/blank/single backfill, old-writer INSERT/actual scalar-change mirroring, an unrelated old-writer update that resubmits the unchanged first-member scalar without collapsing a multi-member array, and a new-writer multi-member update whose changed `agent_ids` and first-member scalar are not overwritten by the trigger.
- [ ] Assert the production migration text contains a non-null text array default, the named GIN index, schema-qualified trigger/function names, and no scalar drop.
- [ ] Run and observe failure because migration helpers are absent.

### Step 6: Add only the expand migration

- [ ] Author the scoped Ecto migration with `@prefix "platform"`. Add nullable `agent_ids`, backfill in bounded SQL, set default/NOT NULL, create the GIN index, then install `BEFORE INSERT OR UPDATE OF agent_id` compatibility logic. On insert, mirror a nonblank scalar only when the array is empty/default. On update, mirror scalar to array only when `NEW.agent_id IS DISTINCT FROM OLD.agent_id` and `NEW.agent_ids IS NOT DISTINCT FROM OLD.agent_ids`; unchanged scalar resubmission and any array-aware change preserve the canonical array.
- [ ] For array-aware writes, persist scalar nil for `[]` and the first normalized UID for non-empty arrays. Prove an old scalar read of a multi-member row reaches one selected agent and never matches the All branch.
- [ ] Make `down/0` remove trigger/function/index/array only; leave the retained scalar untouched.
- [ ] Export small SQL helper functions used by the DB test so the test executes the same statements as production.
- [ ] Do not remove the compatibility trigger, scalar index, or scalar column in this release.
- [ ] Update `core.migrations.expectedVersion` in `helm/serviceradar/values.yaml` to `20260830120000`. Add a Helm unit contract for `core-migrations-job.yaml` that asserts `post-install,pre-upgrade`, hook weight `-1`, and the delete policy; preserve the existing CNPG extension hook's earlier `-5` ordering. Run `bazel test //helm/serviceradar:migrations_expected_version_test //helm/serviceradar:helm_unittest_suite_test` and confirm the rendered version/schema gate remains aligned.
- [ ] Run migration, resource, and compile tests. Commit Task 1 only.

---

## Task 2: One eligibility rule for compiler, coverage, and UID replacement

**Files:**

- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_group.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/sweep_compiler.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/composite_checks/validation/coverage.ex` only if documentation/logging needs the new terminology
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/composite_checks_live/sweep_context.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/composite_checks_live/components.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_targeting_integration_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/sweep_config_distribution_integration_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/agent_gateway_sync_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/composite_checks/validation/coverage_test.exs`
- Modify: `elixir/web-ng/test/serviceradar_web_ng_web/settings/composite_checks_sweep_context_test.exs`

**Read contract:**

```text
enabled AND (
  (agent_ids = [] AND group.partition = request.partition) OR
  (request.agent_id is nonblank AND request.agent_id is a member of agent_ids)
)
```

### Step 1: Add the eligibility matrix and observe scalar behavior fail

- [ ] Extend resource/compiler/coverage tests with empty, single, multiple, nil requesting UID, deselected UID, and explicitly selected cross-partition UID cases.
- [ ] Assert two selected agents independently compile identical group payloads and an unselected agent does not.
- [ ] Assert the compiled agent JSON schema has no new assignment field.
- [ ] Assert fleet-wide dependency invalidation fires for an old-membership to new-membership update; do not narrow the existing notifier.
- [ ] Add a representative-cardinality database plan test for explicit membership. Assert the generated membership predicate is GIN-supported and, with sequential scans disabled for the assertion, `EXPLAIN` names `sweep_groups_agent_ids_gin_idx`; this proves index usability without claiming PostgreSQL must choose it for tiny fixtures.
- [ ] Extend agent gateway synchronization tests for superseded UID replacement when the old UID is first, non-first, and when the replacement UID is already present. First observe the current scalar-only transfer miss or subset collapse.
- [ ] Run the three core integration suites and read the expected multi-member/nil-agent failures.

### Step 2: Make both reads canonical

- [ ] Rewrite `:by_agent` and `:for_agent_partition` with empty-array/membership semantics. The explicit membership clause must require a nonblank argument.
- [ ] Update group/resource/compiler logging and documentation from scalar pin language to fixed-subset language.
- [ ] Leave `SweepCompiler.load_sweep_groups/3` and `Coverage.load_groups/3` calling the shared read action; do not add a second filter.
- [ ] Special-case `SweepGroup` in `AgentGatewaySync.transfer_superseded_assignments/3`: find membership with the canonical array, replace the superseded UID wherever it occurs, preserve every other member, normalize/de-duplicate when the replacement is already present, and write `agent_ids` so the compatibility scalar is derived from the resulting canonical selection. Leave scalar `MapperJob` transfer behavior unchanged.
- [ ] Re-run the matrix and mutation-check cross-partition inclusion plus nil-requester exclusion.

### Step 3: Update composite-check presentation

- [ ] Change `SweepContext.group_view/2` assignment labeling to non-empty array membership.
- [ ] Update component copy that describes assignment/coverage; preserve all interval calculations.
- [ ] Add/adjust tests, run core and web-ng focused shards, and commit Task 2 only.

---

## Task 3: Bounded Agent picker query and pure picker state

**Files:**

- Create: `elixir/serviceradar_core/lib/serviceradar/infrastructure/preparations/agent_picker.ex`
- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/agent_picker.ex`
- Create: `elixir/web-ng/test/serviceradar_web_ng_web/settings/networks_live_agent_picker_state_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/infrastructure/agent.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/infrastructure/agent_test.exs`

**Query interface:**

```elixir
Agent
|> Ash.Query.for_read(:agent_picker, %{search: normalized_search})
|> Ash.read(scope: scope, page: [limit: 50, after: cursor])
# => {:ok, %Ash.Page.Keyset{results: agents, after: after_cursor, before: before_cursor}}
```

**Pure state interface:**

```elixir
new(initial_ids)
open(state)
search(state, text)
loaded(state, page)
toggle(state, uid)
remove(state, uid)
clear(state)
apply(state)
cancel(state)
```

### Step 1: Prove the database query contract red

- [ ] Extend the Agent resource test with case-insensitive name/UID search, trimmed empty search, name case ties resolved by UID, default/max 50, forward/back keyset paging, and viewer/operator scope authorization.
- [ ] Include more than 50 rows and assert page one never returns row 51.
- [ ] Run the Agent test through the DB workflow and confirm `:agent_picker` is missing.

### Step 2: Add the scoped picker action

- [ ] Add a private expression calculation for `lower(coalesce(name, uid))` and a preparation that trims search, applies parameterized `ILIKE` filters, and fixes sort to calculation then UID.
- [ ] Configure keyset pagination with default/max 50. Do not accept client-provided sort or arbitrary limits.
- [ ] Load each page's existing `gateway.partition_id` relationship for advisory partition display; do not query the live registry or load gateways/agents outside the bounded page.
- [ ] Preserve the existing viewer-plus policy and require callers to pass `scope:`.
- [ ] Re-run the database test and mutation-check the tie-break and cap.

### Step 3: Prove picker state red

- [ ] Add `@moduletag :db_free` tests for open/search/query normalization, cursor-history reset on a changed normalized query, forward/back navigation, Browse/Selected view, draft retention across pages, sorted 50-UID Selected slices, Apply, Cancel, and clear.
- [ ] Assert query failures preserve the draft/count and expose a retryable error.
- [ ] Run `//elixir/web-ng:unit_tests_serviceradar_web_ng_web` and read the missing-module failure.

### Step 4: Implement only pure state transitions

- [ ] Store selected UIDs in `MapSet`, committed UIDs separately, browse cursor/history separately from selected-page offset, and bind every browse cursor to normalized query plus the fixed sort version.
- [ ] Make Selected order raw UID ascending and slice no more than 50 before any Agent resolution.
- [ ] Re-run/mutation-check and commit Task 3 only.

---

## Task 4: LiveView picker and removal of eager full-fleet reads

**Files:**

- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/agent_picker_components.ex`
- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/event_handlers/agent_picker.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/actions.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/data.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/events.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/view.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/form_components.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/view/sweep_groups.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/components/ui_components.ex` only if the existing modal needs an explicit return-focus attribute
- Modify: `elixir/web-ng/assets/js/hooks/DialogTopLayer.js`
- Modify: `elixir/web-ng/assets/js/hooks/DialogTopLayer.test.js`
- Modify: `elixir/web-ng/test/phoenix/live/settings/networks_live_test.exs`

### Step 1: Prove route reads are bounded

- [ ] Add LiveView tests/instrumentation proving index, new-group, edit-group, validation, list, and detail do not call the old unpaginated Agent read or assign a full `@agents` fleet.
- [ ] Add a regression test proving discovery/new-mapper/edit-mapper still receive their separately loaded active-agent options only when those routes need them.
- [ ] Run `networks_live_test.exs` through the scratch-CNPG Mix workflow and observe the eager-load assertions fail. Do not claim `//elixir/web-ng:unit_tests_phoenix_live` covers this DB-backed file.

### Step 2: Remove the group lifecycle's eager Agent list

- [ ] Remove `load_agents/1` from NetworksLive mount and sweep-group new/edit actions.
- [ ] Rename the remaining helper/assign to `load_mapper_agents/1` / `mapper_agents`; invoke it only in discovery and mapper form routes, and update mapper rendering accordingly.
- [ ] Re-run the route tests before adding picker behavior.

### Step 3: Prove picker behavior and canonical form state red

- [ ] Add tests for open, debounced search, next/previous, retained selections across pages/search, Browse/Selected switching, individual stale-ID removal, clear, Apply, Cancel, Escape/backdrop/close-button preservation, and query error retry.
- [ ] Assert All submits `agent_ids: []`; Selected submits normalized hidden `form[agent_ids][]` values; Selected-empty is rejected server-side; crafted input is normalized and newly unknown UIDs are rejected by the resource.
- [ ] Assert many-member validation/save succeeds without a feature flag.
- [ ] Assert one-member summary performs one bounded lookup, many-member summary is count-only, and Selected detail resolves at most 50 known/raw-unavailable UID rows.
- [ ] Assert advisory offline/capability labels never prevent selection or stale-ID removal.

### Step 4: Implement the picker events and rendering

- [ ] Initialize picker state from `group.agent_ids` on new/edit and preserve it through unrelated `validate_group` events.
- [ ] Load `%Ash.Page.Keyset{}` only on open/search/page events. On query change, discard old cursors before requesting page one.
- [ ] Render with `<.ui_modal>`, stable trigger/search IDs, `data-dialog-autofocus`, bounded scrolling, labeled checkboxes/buttons, directional pagination labels, and `aria-live` selected count.
- [ ] Keep hidden inputs derived from committed picker state, never from browser-provided hidden values. Inject the canonical list into both validate and save params before AshPhoenix form calls.
- [ ] Render raw UID + “Unavailable” for unresolved retained IDs.

### Step 5: Restore focus on every modal close path

- [ ] First add a Vitest assertion that `DialogTopLayer` restores the captured/stable trigger after dialog destruction/close.
- [ ] Extend the hook or `ui_modal` contract minimally; do not add a second modal implementation.
- [ ] From `elixir/web-ng/assets`, run `sfw bunx vitest run js/hooks/DialogTopLayer.test.js`, then run the LiveView accessibility tests through the scratch DB and mutation-check trigger restoration.

### Step 6: Verify and commit

- [ ] Run the DB-backed LiveView file through the scratch-CNPG Mix workflow, the database-free component/state shards through Bazel, and the JS hook target; confirm each runner output names the new test paths.
- [ ] Commit Task 4 only.

---

## Task 5: Exact per-agent Run-now dispatch and independent status

**Files:**

- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/changes/dispatch_agent_command.ex` only if its accepted success typespec needs widening
- Modify: `elixir/serviceradar_core/lib/serviceradar/agent_commands/pubsub.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/agent_commands/status_handler.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/agent_command_bus_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/agent_command_bus_registry_test.exs`
- Create: `elixir/web-ng/test/serviceradar_web_ng_web/settings/networks_live_command_status_test.exs`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/event_handlers/groups.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/command_status.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/infos.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/view/sweep_groups.ex`
- Modify: `elixir/web-ng/test/phoenix/live/settings/networks_live_test.exs`

**Dispatch result:**

```elixir
{:ok,
 %{
   commands: [%{agent_id: uid, command_id: command_id}],
   failures: [%{agent_id: uid, reason: reason}]
 }}
```

Return `{:error, reason}` only when no member dispatch succeeds.

`DispatchSweepRun` returns the updated Ash record, so `AgentCommandBus` SHALL
also publish a public `{:sweep_dispatch, result}` event carrying the group ID,
successful command/agent pairs, and immediate failures. NetworksLive seeds its
sweep-specific reducer from that event; mapper-job status keeps its existing
map shape.

### Step 1: Prove exact subset dispatch red

- [ ] Add registry/bus tests for two selected online agents, mixed online/offline, missing sweep capability, all failures, explicit cross-partition sessions, ambiguous sessions, and a UID outside the list.
- [ ] Assert selected-agent resolution never falls back to the group device partition and never dispatches a noncanonical session.
- [ ] Update all-agent assertions to the structured result without changing its canonical partition enumeration.
- [ ] Run and read the scalar/single-dispatch failures.

### Step 2: Implement structured fanout

- [ ] Branch on canonical `group.agent_ids`: empty uses current partition listing; non-empty iterates exactly normalized UIDs.
- [ ] For each selected UID, require one canonical live control partition and live `sweep` capability, then dispatch with that session's gateway metadata.
- [ ] Preserve every success/failure with its UID. Do not reduce to bare command IDs or logs.
- [ ] Keep `DispatchAgentCommand.run/3` compatible with any `{:ok, result}`; update only documentation/typespec if runtime code already accepts it.
- [ ] Re-run and mutation-check “no fallback” and partial success.

### Step 3: Prove public per-command updates and reducer independence red

- [ ] Add status-handler/PubSub tests proving the initial sweep-dispatch event and persisted ACK/progress/result events are published to the public `agent:commands` topic after ingress handling, without looping back into ingress.
- [ ] Add `@moduletag :db_free` reducer tests for two commands in one group, out-of-order updates, member failure, aggregate pending/success/failure counts, and A updating without overwriting B.
- [ ] Run the focused core/web shards and observe the missing public-forward/reducer behavior.

### Step 4: Wire public status and LiveView rendering

- [ ] Add explicit public ACK/progress broadcasters invoked by `StatusHandler` after persistence; keep ingress and public topics distinct.
- [ ] Add sweep-specific `seed_sweep_dispatch/2` and `reduce_sweep_member_event/2` functions. Store group status as member maps keyed by command ID and carrying agent UID, plus immediate dispatch failures keyed by UID; do not change mapper status shape.
- [ ] On Run now, seed queued member states from structured successes and preserve failures. Render complete/partial/zero-success summaries and member details.
- [ ] Re-run reducer, PubSub, and LiveView tests. Commit Task 5 only.

---

## Task 6: Expected reporters, per-agent forensics, and canonical availability

**Files:**

- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_results_flow_e2e_test.exs`
- Modify only when necessary: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_availability_dedupe_test.exs`

**Reporter policy input:** resolve the persisted group (directly or through the
execution FK) and the authenticated reporter UID. For a non-empty assignment,
`expected?` is exact UID membership. For an empty assignment, any authenticated
reporter attached to that resolved group/execution is expected because the
canonical assignment itself is partition-wide and delayed ingestion has no
durable control-session partition evidence. Missing group/execution identity is
unknown and fails closed. Do not consult the live registry for historical
results.

### Step 1: Prove reporter ownership red

- [ ] Extend E2E ingestion tests so selected A and B report independently without conflict, deselected C emits an anomalous-assignment warning but still creates its `SweepGroupExecution` and `DeviceAgentAvailability`, and an unresolved/missing group identity fails closed.
- [ ] Assert empty assignments treat an authenticated reporter on a resolved group/execution as expected; assert missing group/execution identity is unknown and fails closed rather than guessing from a live registry session.
- [ ] Run and read the scalar conflict-detection failures.

### Step 2: Implement expected-assignment evaluation

- [ ] Replace `detect_multi_agent_conflict/2` and `all_agents_group?/2` scalar reads with one helper returning resolved group + `expected_reporter?` from canonical `agent_ids`; reuse that result in both conflict and availability decisions.
- [ ] Expected selected reporters do not warn. Unexpected reporters warn with group/agent context but their execution and per-agent observation remain intact.
- [ ] Missing group/execution identity must require a configured source for canonical writes; do not broaden the fallback.

### Step 3: Prove canonical availability precedence red

- [ ] Add tests where configured `availability_source_agent_id` wins regardless of assignment, expected reporters participate in unconfigured fallback, and unexpected reporters are excluded from that fallback while their per-agent row remains queryable.
- [ ] Assert no rule gives single-agent assignments an artificial precedence over multi-agent assignments.
- [ ] Run and observe the old `require_source_match?` behavior fail.

### Step 4: Integrate with existing per-agent availability

- [ ] Preserve the existing `(device_uid, agent_id)` upsert and dedupe paths.
- [ ] Replace the ambiguous `require_source_match?` boolean with one explicit policy value carrying configured-source authority, expected-reporter eligibility, and fail-closed unknown identity; pass it into both canonical available and unavailable SQL updates. Do not create a second availability table or detector.
- [ ] Re-run/mutation-check unexpected-reporter exclusion and configured-source precedence. Commit Task 6 only.

---

## Task 7: Missed-sweep diagnostics, summaries, and rollout docs

**Files:**

- Modify: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_monitor_worker.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_monitor_worker_test.exs`
- Modify: `docs/docs/network-sweeps.md`

### Step 1: Prove diagnostics red

- [ ] Add `@moduletag :db_free` tests for an extracted `missed_sweep_payload/3` helper with empty, one, and many `agent_ids`, plus copy asserting `last_run_at` means the latest report by any member, not complete member coverage.
- [ ] Run and read the scalar payload failure.

### Step 2: Remove remaining behavioral scalar reads

- [ ] Emit `agent_ids` arrays in missed-sweep payloads and update operator-facing details.
- [ ] Search all non-migration/non-archive source for scalar reads specifically tied to `SweepGroup`; classify every remaining hit as an intentional compatibility write or fix it. Do not alter unrelated `MapperJob.agent_id` routing.

### Step 3: Document operation and deferred phases

- [ ] Update network-sweeps docs with All/Selected semantics, fixed cross-partition subsets, advisory picker metadata, bounded search/pagination, stale-ID behavior, partial Run-now results, and any-member `last_run_at` meaning.
- [ ] Document the additive migration ordering, immediate subset availability, the 10–30 second fail-narrow rolling bridge, and that the scalar/trigger/index remain through the rollback window for later deprecation.
- [ ] Re-run focused tests and OpenSpec strict validation. Commit Task 7 only.

---

## Task 8: Verification and rolling-release handoff

**Files:**

- Modify only for verified omissions: `openspec/changes/add-sweep-group-agent-subsets/tasks.md`
- Review: every file changed since `origin/staging`

### Step 1: Format and static verification

- [ ] Run `mix format` from both `elixir/serviceradar_core` and `elixir/web-ng`, then inspect the diff.
- [ ] Run `make lint` and the focused `sfw bunx vitest run js/hooks/DialogTopLayer.test.js` asset test.
- [ ] Run `rg` checks proving there is no group-form eager full-fleet read, no behavioral scalar assignment reader in array-aware code, no scalar-cleanup migration, and no newly added shell script.

### Step 2: Focused test verification

- [ ] Run all new database-backed tests through the `srql-fixtures-db-tests` skill/workflow and read the selected test names and assertions.
- [ ] Run:

```bash
bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests
bazel test -c opt --config=remote //elixir/serviceradar_core:agent_command_bus_rpc_registry_test
bazel test -c opt --config=remote //elixir/web-ng:unit_tests
```

- [ ] Confirm each new test path is listed by the applicable Bazel runner; a green aggregate that skipped a new file is a failure.

### Step 3: Repository gate and proposal validation

- [ ] Run the required repository unit sweep and strict spec validation:

```bash
make test
openspec validate add-sweep-group-agent-subsets --strict
```

- [ ] Read the actual output and retain explicit failure branches; do not infer success from a queued BuildBuddy invocation.

### Step 4: Final review and handoff

- [ ] Compare the branch against the OpenSpec requirements and this plan. Leave the later scalar-write deprecation and cleanup-migration checklist item unchecked because it requires future release and rollback evidence.
- [ ] Run a dedicated final code review agent, resolve findings with test-first fix loops, then rerun affected verification.
- [ ] Report branch/worktree, commits, exact test outcomes, rolling-bridge behavior, and deferred scalar cleanup. Do not push or open a PR unless the user asks.
