# Change: Distribute SNMP polling targets across agents

## Why

SNMP polling does not divide work between agents, so it cannot reach large
inventories. An agent's SNMP config holds the whole target set of one profile.
That profile is the one whose query matches the agent's own host device, or the
default profile (`SNMPCompiler.do_compile/3`, `fetch_profile/3`). Every agent the
profile applies to compiles the same targets, and that is every agent when the
profile is pinned to none. With N agents, a device is polled N times.

Commit `2a49504458` added `ServiceRadar.SNMPProfiles.TargetLimit`. It refuses a
whole profile that selects more than `snmp_max_targets` (default 10,000) targets
for one agent. That limit is a guardrail around the design, not a fix. A
deployment of moderate size already selects several times the limit with the
seeded default profile, and some customers have more than a million devices.

Measurement (design.md, "Measurements") shows that the per-profile limit is not
even the binding constraint today:

- The agent preallocates a 1,000-point ring buffer for every polled series,
  about 200 KB per series. A target with 12 scalar OIDs holds about 2.5 MB. A
  switch with three walked interface columns over 24 ports holds about 15 MB.
- Each target has its own connected UDP socket for its lifetime, so one agent
  cannot hold more targets than its ephemeral port range (28,232 on a stock
  Linux host).
- Any change to the target list, including one device added, stops and
  rebuilds every collector. This also loses the counter-delta state of every
  target.
- Every device change invalidates the SNMP config of every online agent that
  uses an unpinned profile. Each invalidation recompiles the whole target query
  once per agent.

## What Changes

- **Core decides who polls.** A profile states what to poll. A placement
  service assigns each target to exactly one agent, or to `redundancy` agents
  when the profile asks for more, or to every currently eligible pinned agent
  for a `replicate` profile, always within each agent's effective capacity. The candidates come from profile pinning and
  the device's partition. Placement is sticky, weighted by capacity, and moves a
  target only for a stated reason: the owner left, failed, is over capacity, or
  cannot reach the target, or a bounded rebalance moves load between agents
  without taking any agent past its effective capacity. A target short of its
  redundancy or `replicate` owners gains owners when an eligible agent joins, with the room left
  after uncovered targets, reachability moves and over-capacity sheds. Assignments are persisted with an authority
  generation that follows the sweep producer-assignment fencing pattern.
- **Each device resolves to one profile.** That is its highest-priority matching
  profile, or the default profile when none matches, as the existing "Profile
  priority ordering" requirement already states. The profile chosen by the
  agent's own host device no longer decides anything. An agent may poll targets
  of several profiles.
- **Targets are delivered incrementally.** For an upgraded agent, the agent
  config keeps only profile definitions: OID sets, intervals, timeouts and
  retries. Target assignments go
  over a revisioned, paged delta channel, so the bytes sent grow with the size
  of the change, not the inventory. A control-stream hint replaces pushing the
  whole config. Credentials resolve at serve time through the unified credential
  model, and assignment rows never hold secret material.
- **Agents apply deltas in place.** They add, update or remove collectors
  without restarting the SNMP service, and keep counter state for targets that
  did not change, as the existing "Dynamic reconfiguration" scenario already
  requires. Ring buffers are sized to the drain cadence. Socket count follows
  in-flight polls, not targets. Poll phases are jittered.
- **Capacity feeds placement instead of refusing.** Agents report measured
  poll throughput and lateness. Placement keeps each agent within both its
  measured point rate and its operator ceiling on target count. `snmp_max_targets` stays in
  `edge_pipeline_settings` (agent, then partition, then global, then code
  default) with a new meaning: the most targets placed on one agent across all
  profiles. Its code default comes from the measurements.
- **Coverage replaces the target limit.** `TargetLimit`, `CheckTargetLimit` and
  the `[:serviceradar, :snmp, :target_limit_exceeded]` event are retired. A
  target the eligible agents cannot cover is marked `uncovered`, counted per
  profile and partition, alerted and shown in a capacity view. It is never
  dropped silently, and already-placed targets are never evicted to make room.
- **Shared seam.** Placement is built as a workload-neutral
  `target-placement` capability, with SNMP as its first consumer. Follow-ups
  are named in design.md.
- Telemetry is unchanged. Samples still leave through the edge spool, then the
  gateway, then JetStream, then EventWriter.

## Impact

- Affected specs: `snmp-checker`, `agent-config`, a new `target-placement`
  capability.
- Related changes: `add-streamed-agent-config` (its chunked transport stays for
  the remaining monolithic config) and `fix-default-snmp-profile-preview`. That
  change's ADDED "Seeded default SNMP profile targets all devices" requirement
  cites the per-agent limit refusals this change retires. Its wording must be
  reconciled at archive time (tasks.md 9.3).
- Affected code (implementation is a later change, not this one):
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/snmp_compiler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/{target_limit.ex,changes/check_target_limit.ex,snmp_profile.ex,srql_target_resolver.ex}`
  - `elixir/serviceradar_core/lib/serviceradar/edge/{agent_config_generator.ex,pipeline_settings.ex,pipeline_setting.ex}`
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/dependency_catalog.ex`
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/{agent_gateway_server.ex,control_stream_session.ex}`
  - `proto/monitoring.proto`
  - `go/pkg/agent/{snmp_service.go,push_loop_snmp.go}`, `go/pkg/agent/snmp/*`
  - `elixir/web-ng` SNMP profile settings and a capacity view
- Data: new `platform.snmp_target_assignments` (via the shared placement
  table) and profile columns `placement_mode` and `redundancy`. Existing
  profiles and explicit targets migrate without operator re-entry.
- Mixed-version fleets are supported. An agent without the new capability
  still gets its placed share through the monolithic `SNMPConfig`, capped by a
  lower legacy ceiling.
