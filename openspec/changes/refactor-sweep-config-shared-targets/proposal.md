# Change: Share device targets across sweep groups in compiled agent config

## Why

The compiled sweep config repeats data for every device a group targets.
Each `device_targets` entry carries its own copy of group-level fields
(`sweep_modes`, `query_label`, `source`, `metadata.sweep_group_id`,
`metadata.target_query`), and the per-device fields (`device_uid`, `hostname`,
`discovery_sources`) are copied again for every group that selects that
device. An operator who sweeps one device population with several scanner
profiles (for example ICMP only; ICMP plus a few TCP ports; TCP on other ports)
gets one complete copy of that population per group. Core also re-runs each
group's paginated SRQL target query on every compile, for every agent, even
when several groups share the same query.

The result is a multi-megabyte `config_json` that keeps growing with every
overlapping group, and it broke both delivery paths at once when a large group
was added:

- Poll path: generation exceeded the gateway-to-core RPC timeout, which the
  gateway reports as `not_modified`, so the agent kept its previous config.
  Mitigated by raising the timeouts (PR #4949).
- Push path: the invalidation push sent the whole config as one control-stream
  message larger than the agent's receive limit, so the agent rejected it and
  its control stream reset. Fixed by chunked config pushes (branch
  `fix/agent-config-push-chunks`, extending `add-streamed-agent-config`).

Either way the newly created group failed with "sweep group not found". Both
fixes treat the symptom. This change reduces the size and generation cost
that caused it.

## What Changes

- Trim per-target metadata that nothing consumes from the legacy format:
  `sweep_group_id`, `target_query`, `hostname` and `discovery_sources`.
  `device_uid` stays. Deployed agents already ignore missing metadata keys, so
  this shrinks every agent's config without an agent upgrade, at the cost of
  one config version change per agent.
- Evaluate each distinct normalized `target_query` once per compile, and cache
  query results across agents for an explicit TTL, so partition-wide groups
  stop re-running the same SRQL for every agent.
- Add a normalized sweep config format, `shared-targets/v1`:
  - `device_table`: one entry per device, keyed by device (`device_uid`), not
    by IP, holding `ip` and `device_uid`, stated once.
  - `target_sets`: one device reference list per distinct normalized
    `target_query`, stated once.
  - Groups carry their own settings once (modes, ports, schedule, settings,
    banner grab, name, `target_query`, group id) and reference a target set by
    key instead of embedding `device_targets`. Static `targets` are unchanged.
  - Groups are emitted in a defined order, so row order in the database can
    never change the config version.
- The Go agent parses both formats and rehydrates `shared-targets/v1` into the
  same per-group `DeviceTargets` model the trimmed legacy format produces, so
  sweeper behavior and sweep results are identical.
- Rollout is gated by capability. Upgraded agents advertise
  `sweep-config-shared-targets:v1`. Core emits the new format only to agents
  whose persisted capabilities include it, and the legacy format otherwise.
  Mixed fleets are supported.

No breaking changes. The legacy format stays the default for agents that do
not advertise the capability.

## Non-Goals

- Gateway-to-core RPC timeouts, the agent config fetch deadline, and chunked
  config pushes (handled by the PRs above).
- The gateway answering `not_modified` when core errors or times out.
- SRQL language or engine changes.
- Reducing the Go agent's in-memory representation after rehydration. Each
  group keeps its own target list and every expanded target gets its own
  metadata map; sharing per-device state inside the sweeper is a follow-up
  (see design.md, Decision 5).
- SNMP config has the same shape problem (one typed target per device, each
  repeating its OID list, and an empty target query compiling to every
  device). Plugin params are also sent twice. Both are follow-ups.
- Removing the legacy format (a later change, once every supported agent
  release advertises the capability).

## Impact

- Affected specs: `sweep-jobs`, `agent-config`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/sweep_compiler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/config_server.ex`
    (sweep cache scope)
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex`
    (format selection from agent capabilities)
  - `platform.device_sweep_overlap` view (reads compiled sweep configs; must
    understand the new format before any sweep config is persisted in it)
  - `go/pkg/agent/sweep_config_gateway.go` (dual-format parser)
  - `go/pkg/agent/push_loop_capabilities.go` (advertise capability)
- Related changes:
  - PR #4949 and `fix/agent-config-push-chunks` (the two delivery-path fixes).
  - `add-sweep-group-agent-subsets` modifies the "Sweep Job Compiled Config
    Output" requirement. This change adds new requirements instead of
    modifying that one, so the two do not conflict.
  - `add-sweep-profile-mtr-mode` adds `mtr` to per-target `sweep_modes`, one
    of the fields this change hoists to the group. Sequence the two: land
    whichever is first, then rebase the other onto it.
  - `add-sweep-diagnostics-srql-entities` projects group-level compiled
    fields (ports, modes, interval), which stay on the group in both formats.
