# Change: Add scalable agent subset targeting to sweep groups

## Why

Sweep groups can currently target either every eligible agent in their device
partition or one agent stored in a nullable `agent_id` field. Operators cannot
assign a fixed subset, and the Settings form loads every recently active agent
into one native select. That interaction is both functionally incomplete and
unsafe for installations with hundreds or thousands of agents.

Issue [#4173](https://github.com/carverauto/serviceradar/issues/4173) requests a
searchable list experience modeled on the Devices view's Device Types modal.
The assignment model must change with the UI: configuration compilation,
on-demand dispatch, result ownership, and composite-check coverage all depend
on the current all-or-one semantics.

## What Changes

- **BREAKING (internal persistence, additive rollout):** introduce a canonical, non-null
  `SweepGroup.agent_ids` array. Backfill each existing scalar assignment into
  a one-element array; an empty array preserves the existing "all eligible
  agents in this partition" behavior. Retain `agent_id` as a fail-narrow
  rolling-compatibility bridge: new writes mirror nil for All and the first
  normalized selected UID for any non-empty selection, so an old reader can
  temporarily reach at most one selected agent and can never broaden a subset.
- Normalize custom selections to unique, non-blank agent UIDs and validate
  submitted UIDs through the scoped Infrastructure Agent resource.
- Compile a sweep group for every explicitly selected agent, including a
  selected agent whose control-session partition differs from the group's
  device partition. Do not include the group for unselected agents.
- Fan out `Run now` to the exact selected online agents and report partial
  success when some selected agents are offline or fail dispatch.
- Make result-ingestion conflict detection aware that an explicit subset may
  intentionally contain multiple reporters, while deferring canonical
  availability derivation to the active per-agent availability policy.
- Replace the sweep-group Agent select with an explicit All/Selected mode and
  a dedicated modal that uses server-side search, keyset pagination, selection
  retention across result pages, and concise assignment summaries.
- Keep the agent-facing compiled sweep JSON unchanged; assignment remains a
  server-side eligibility concern.

## Impact

- Affected specs: `sweep-jobs`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_group.ex`
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/sweep_compiler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_monitor_worker.ex`
  - `elixir/serviceradar_core/lib/serviceradar/infrastructure/agent.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/composite_checks_live/sweep_context.ex`
- Data migration: add/backfill/index `platform.sweep_groups.agent_ids`, retain
  scalar `agent_id` plus its old-writer trigger through the rolling/deprecation
  window, and remove them only in a later cleanup after no current or rollback
  binary references the scalar.
- Helm upgrade contract: normal hooked upgrades apply the schema before pods
  roll; operators who skip or disable migration hooks must apply it externally
  first. Update the chart's expected schema version with the migration.
- External compatibility: no protobuf, agent config JSON, or Go agent parser
  change is required.
- Coordination: `add-sweep-profile-mtr-mode` touches the same Settings form but
  not assignment semantics; implementation must preserve both changes.
- Coordination: `add-per-agent-availability` owns canonical availability
  derivation. Shared sweep assignments persist independent per-agent state and
  MUST use that proposal's configured-source/deterministic-fallback policy.
