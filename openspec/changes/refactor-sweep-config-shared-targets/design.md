# Design: Shared device targets in compiled sweep config

## Context

### Current compile path (legacy format)

- `SweepCompiler.compile/3` (`sweep_compiler.ex:57`) loads the groups the
  agent is eligible for, compiles each one with `compile_group/3`
  (`sweep_compiler.ex:221`), and hashes the list of compiled groups
  (`sweep_compiler.ex:88`, `compute_config_hash/1` at `sweep_compiler.ex:152`).
  The hash input is the compiled group list, sorted by `"id"` and encoded with
  `Jason.encode!/1`. That list includes the embedded `device_targets`.
- `compile_targets/3` (`sweep_compiler.ex:283`) runs the group's
  `target_query` through `get_device_targets_from_query/4`
  (`sweep_compiler.ex:299`). That function pages through SRQL with
  `fetch_srql_device_targets/5` (`sweep_compiler.ex:330`), deduplicates by IP
  within the group (`Map.put_new`, `sweep_compiler.ex:370`), and sorts by
  `"network"` (`sweep_compiler.ex:305`). Each group runs its own query, even
  when another group uses the identical query.
- `device_target_from_row/4` (`sweep_compiler.ex:380`) builds one entry per
  device IP per group. The entry contains:
  - group-derived fields: `sweep_modes` (the group's modes,
    `sweep_compiler.ex:392`), `query_label` (the group name, `:393`), `source`
    (always `"srql"`, `:394`), `metadata.sweep_group_id` and
    `metadata.target_query` (`:383-384`);
  - device-derived fields: `metadata.device_uid`, `metadata.hostname`,
    `metadata.discovery_sources`.

  Every group-derived field repeats once per device. Every device-derived field
  repeats once per group that selects the device.
- `SweepGroup :for_agent_partition` (`sweep_jobs/sweep_group.ex:190-208`) has
  no sort. `config_hash` sorts groups by id, but the emitted `groups` list keeps
  database row order, and `Compiler.content_hash/1`
  (`agent_config/compiler.ex:104-110`) hashes lists order-sensitively. A change
  in row order may therefore change the config version with no real change.
  Not yet observed at runtime.

### Caching and freshness

- `ConfigCache` keys are `{config_type, partition, agent_id, scope}`
  (`agent_config/config_cache.ex:194-196`) with a 5-minute default TTL
  (`config_cache.ex:27`), and `cache_scope/2` returns `nil` for `:sweep`
  (`config_server.ex:229`). The compiled result is cached per agent, and
  every agent in a partition runs the same SRQL queries on its own compile.
- Core tells agents how often to poll through `config_poll_interval_sec`
  (`proto/monitoring.proto:328`), which defaults to 300 seconds
  (`agent_config_generator.ex:71`); the agent's 60-second constant is only a
  fallback. A poll interval equal to the cache TTL means an agent's entry has
  usually expired by its next poll, so most polls recompile.
- The sweep compiler's source resources are `SweepGroup` and `SweepProfile`
  only (`sweep_compiler.ex:52-54`). Device inventory changes never invalidate
  `:sweep`, so the device membership of a query-based group is refreshed only
  when the cache entry expires. The TTL is the de-facto staleness bound today.

### Delivery

- `AgentConfigGenerator.load_sweep_config/2` (`agent_config_generator.ex:2981`)
  fetches the compiled sweep config through
  `ConfigServer.get_config(:sweep, partition, agent_id)`
  (`agent_config_generator.ex:2986`) and embeds it as `config_json["sweep"]`
  (`agent_config_generator.ex:2236`).
- The poll path streams `config_json` in 1 MiB chunks, with a 2 MiB per-chunk
  cap and a 64 MiB window (`agent_gateway_server.ex:74-76`). The push path
  sent it as one message until `fix/agent-config-push-chunks`. Both paths
  generate independently, so one invalidation costs a full generation per
  online agent.

### Current agent path

- `parseGatewaySweepConfig/2` (`go/pkg/agent/sweep_config_gateway.go:87`)
  decodes `config_json["sweep"]` into `gatewaySweepConfig`
  (`sweep_config_gateway.go:34`) with `gatewaySweepGroup` entries
  (`sweep_config_gateway.go:39`). `convertDeviceTargets/2`
  (`sweep_config_gateway.go:420`) copies `network`, `sweep_modes`,
  `query_label`, `source` and the metadata map into `[]models.DeviceTarget`
  (`go/pkg/models/sweep.go:330`). Metadata is a free-form map, so a missing
  key is not an error. An empty `groups` list clears sweep targets
  (`sweep_config_gateway.go:107-110`).
- The agent skips applying a sweep config whose `config_hash` matches the
  running one (`go/pkg/agent/push_loop_config.go:938`).

### Who consumes per-target metadata

- Sweep results do not carry it. `HostResult` has no metadata field
  (`go/pkg/models/sweep.go:143-154`), and the results envelope carries
  network, totals, hosts, `execution_id` and `sweep_group_id` taken from the
  service, not the target (`go/pkg/agent/sweep_service.go:401-410`). The
  sweeper's device-registry path, the only code that copies target metadata
  into a device update, is unreachable: the only production constructor passes
  a nil registry (`go/pkg/agent/sweep_service.go:65`).
- The sweeper reads only keys it sets itself (`network`, `total_hosts`) or keys
  the sweep compiler never emits (`armis_device_id`, `integration_id`,
  `agent_id`, `gateway_id`, `partition`). No Go code reads `sweep_group_id`,
  `target_query`, `device_uid`, `hostname` or `discovery_sources` from target
  metadata.
- Core ingests results by IP (`sweep_results_ingestor.ex`) and takes the group
  from the ingest options.
- The one reader is the `platform.device_sweep_overlap` view
  (`priv/repo/migrations/20260904120000_add_device_sweep_overlap_view.exs`).
  It reads `groups[].device_targets[].network` and
  `groups[].device_targets[].metadata.device_uid` from
  `platform.agent_config_instances.compiled_config`, falling back to an IP
  lookup when `device_uid` is absent. No production code path appears to
  write sweep rows into `agent_config_instances`; the sweep compiler returns a
  map that is cached, not persisted. Task 1.1 verifies this. Either way the
  view defines the persisted-shape contract this change must keep.

### Capability negotiation today

- Agents send capabilities in `AgentHelloRequest.capabilities` and
  `ControlStreamHello.capabilities` (`proto/monitoring.proto:287`, `:435`),
  built by `agentCapabilities/1`
  (`go/pkg/agent/push_loop_capabilities.go:343`).
- `AgentConfigRequest` carries only `agent_id` and `config_version`
  (`proto/monitoring.proto:315-318`).
  `get_config_if_changed(agent_id, partition_id, config_version)` receives no
  capabilities, so a config request cannot negotiate a format by itself.
- The generator already resolves the requesting agent's persisted
  capabilities from the `Infrastructure.Agent` record, for add-on gating:
  `resolve_agent_addon_profile/2` (`agent_config_generator.ex:1002`) reads
  `agent.capabilities` through `Agent.get_by_uid/2`.
- `plugin-result-retained:v1` is a different mechanism: a per-request delivery
  capability carried in status metadata. It is not a precedent for config
  negotiation.

## Goals / Non-Goals

- Goals: stop sending metadata nothing reads; state each device once per agent
  config; state each distinct target query's result once; run each distinct
  target query once per compile and share its result across agents; make the
  config version independent of row order; keep sweeper behavior and sweep
  results identical; support mixed fleets.
- Non-goals: see proposal.md.

## Decisions

### Decision 1: Trim unconsumed metadata from the legacy format

`device_target_from_row/4` stops emitting `metadata.sweep_group_id`,
`metadata.target_query`, `metadata.hostname` and
`metadata.discovery_sources`. It keeps `network`, `sweep_modes`,
`query_label`, `source` and `metadata.device_uid`.

- Safe for deployed agents: the metadata map is free-form, and none of these
  keys is read (see "Who consumes per-target metadata").
- `device_uid` stays because the overlap view resolves declared targets with
  it, and because a later change may attribute sweep results by device rather
  than by IP.
- Cost: every agent's sweep `config_hash` changes once, so each agent applies
  one new sweep config after core is upgraded. This is a one-time, expected
  change, not churn. Roll it out after `fix/agent-config-push-chunks`, so the
  resulting pushes are chunked.
- This decision is independent of the new format and ships first, because it
  benefits agents that cannot be upgraded soon.

### Target query normalization contract

`normalize_target_query/1` is defined by `ServiceRadar.SRQLQuery.ensure_target(query, :devices)`
(`elixir/serviceradar_core/lib/serviceradar/srql_query.ex:5`). The contract is:

1. Trim leading and trailing whitespace from the raw query string.
2. If the result does not start with `"in:"`, prepend `"in:devices "`. An empty
   string after trimming becomes `"in:devices"`.
3. Return the resulting byte string unchanged. No case folding, no internal
   whitespace collapsing, no AST canonicalization.

The normalized string is the cache key and the `target_set` key. Identical
byte strings therefore guarantee identical SRQL input; two groups can never
share a wrong result. Queries that are semantically equivalent but textually
different (differing only in internal whitespace, for example) produce distinct
keys and are evaluated separately, costing one extra cache miss, never
correctness. AST-level canonicalization would require an SRQL parser in core
and is out of scope.

### Decision 2: Compile each distinct target query once, share across agents

- Per compile: `SweepCompiler.compile/3` normalizes every group's
  `target_query` (`normalize_target_query/1`; see "Target query normalization
  contract" above), runs each distinct query once through the existing
  paginated SRQL path, and reuses the rows for every group with that query.
- Across agents: query results are cached in a
  `{:sweep_query, normalized_query}` entry with an explicit TTL, shared by
  every agent's compile. The query text alone determines the result, so the
  key needs no agent or partition. The default TTL equals today's
  `ConfigCache` TTL, so device-membership lag is no worse than today; it is
  configurable. The cache stores only the fields the compiler uses from each
  row (`ip`, `uid`), not whole rows.
- TTL sizing is judged against the deployment's `config_poll_interval_sec`,
  not the agent's fallback constant. Because the entry is shared, it stays
  warm as long as any agent polls within the TTL, so its hit rate no longer
  depends on one agent's own poll timing.
- Invalidation: an existing `SweepGroup`/`SweepProfile` dependency-catalog
  dispatch also drops the query entries of the changed group, so editing a
  group's query takes effect on the next compile. Device inventory changes
  still do not invalidate; the TTL bounds staleness, as it does today.
- Error semantics stay per group. If a shared query raises, every group using
  it compiles with no device targets and logs the group id and query, as
  `get_device_targets_from_query/4` does today. A failed query is not cached.

### Decision 3: Wire format `shared-targets/v1`

The sweep section gains a `format` field. If `format` is absent, the payload is
the legacy format.

```json
{
  "format": "shared-targets/v1",
  "config_hash": "0123456789abcdef",
  "compiled_at": "2026-01-01T00:00:00Z",
  "device_table": [
    {"ref": "sr:dev-0001", "ip": "192.0.2.10", "device_uid": "sr:dev-0001"},
    {"ref": "sr:dev-0002", "ip": "192.0.2.11", "device_uid": "sr:dev-0002"}
  ],
  "target_sets": [
    {"key": "q-5f1c2e9a0b7d4c33", "target_query": "in:devices tags.env:\"lab\"",
     "refs": ["sr:dev-0001", "sr:dev-0002"]}
  ],
  "groups": [
    {"id": "g-1", "sweep_group_id": "g-1", "name": "lab-icmp",
     "targets": [], "ports": [], "modes": ["icmp"],
     "schedule": {"type": "interval", "interval": "15m"},
     "settings": {"concurrency": 50, "timeout": "3s"},
     "banner_grab": {"enabled": false},
     "target_query": "in:devices tags.env:\"lab\"",
     "device_target_set": "q-5f1c2e9a0b7d4c33"},
    {"id": "g-2", "sweep_group_id": "g-2", "name": "lab-icmp-tcp",
     "targets": [], "ports": [80, 443], "modes": ["icmp", "tcp"],
     "schedule": {"type": "interval", "interval": "15m"},
     "settings": {"concurrency": 50, "timeout": "3s"},
     "banner_grab": {"enabled": false},
     "target_query": "in:devices tags.env:\"lab\"",
     "device_target_set": "q-5f1c2e9a0b7d4c33"}
  ]
}
```

- `device_table` is keyed by device, not by IP. `ref` is the row's
  `device_uid`, or `"ip:" <> ip` for a row without one. Two distinct devices
  that share an IP (for example a stale record and a live one) stay two
  entries, so neither group is forced onto the other's `device_uid`.
- Each target set's `refs` is the per-query result after the same IP
  de-duplication the legacy path applies within a group (first row seen per
  IP wins, `sweep_compiler.ex:370`), in the legacy order (sorted by IP).
  Groups sharing a query shared that de-duplication in the legacy format too,
  so rehydrating a set reproduces each group's legacy `device_targets`
  exactly, including which device wins a shared IP.
- Every `ref` in a target set appears in `device_table` exactly once, however
  many sets reference it.
- `device_table`, `target_sets` and `groups` are arrays sorted by `ref`, `key`
  and `id`. They are not JSON objects, because Jason does not guarantee key
  order for large maps and the encoded document is the hash input
  (Decision 6).
- The set `key` is `"q-"` plus the first 16 hex characters of the SHA-256 of
  the normalized `target_query` (see "Target query normalization contract"). It
  is stable across compiles and agents.
- The per-entry group fields are not emitted. The agent derives them from the
  group: `sweep_modes` from `modes`, `query_label` from `name`, and `source`
  as `"srql"`.
- Alternative considered: each group carries its own IP list. Simpler, but
  the common case (several groups over the same query) would still repeat the
  whole list once per group.
- Alternative considered: integer indexes instead of string refs. Smaller,
  but harder to diff and debug, and fragile across compiles. Rejected.
- Alternative considered: keying `device_table` by IP. Rejected because it
  silently merges distinct devices that share an IP.
- Alternative considered: dropping `device_table` and sending bare IP lists,
  since sweep results never carry `device_uid`. Rejected because the overlap
  view needs `device_uid`, and because it would close off device-based result
  attribution. The table costs one small entry per device.

### Decision 4: Capability-gated format selection

- The Go agent adds `sweep-config-shared-targets:v1` to `agentCapabilities/1`.
- `AgentConfigGenerator.load_sweep_config/2` resolves the agent's persisted
  capabilities, using the same `Agent.get_by_uid/2` lookup as
  `resolve_agent_addon_profile/2`, and passes
  `sweep_format: :shared_targets_v1 | :legacy` to `ConfigServer.get_config/4`.
- `cache_scope(:sweep, opts)` returns `{:sweep_format, format}`. A capability
  change then produces a different cache key rather than serving a cached
  document in the wrong format. No extra invalidation hook is needed.
- A legacy agent must never receive the new format. Its parser would silently
  ignore `device_target_set`, so its groups would run with static targets
  only: silent coverage loss, not an error. Gating is therefore the safety
  boundary, not an optimization.
- An upgraded agent must accept both formats. Its capability can be persisted
  after its first config request, and core can be rolled back. Either way it
  may still receive the legacy format, which is correct.
- An agent that receives a `format` value it does not know rejects the sweep
  section and keeps its current sweep config, logging the value. This differs
  from the empty-groups path, which clears targets.

### Decision 5: Agent rehydrates into the existing model

`parseGatewaySweepConfig/2` dispatches on `format`. For `shared-targets/v1` it
builds, for each group, a `[]models.DeviceTarget` in the order of the set's
`refs`. Each entry has `Network` = the table entry's `ip`,
`SweepModes` = group modes, `QueryLabel` = group name, `Source` = `"srql"`,
and `Metadata` = `{device_uid}` when present. This matches the trimmed legacy
output of Decision 1 field for field, so sweeper behavior and sweep results do
not change.

Tradeoff: after rehydration the agent still holds one `DeviceTarget` per
(group, device), each group runs its own sweep service with its own target
copy (`multi_sweep_service.go:43`, `:293`), and every expanded target
(device x port) gets its own metadata map in target generation
(`sweeper_target_cidr.go`). This change reduces wire size, core compile time
and core cache memory, but not the agent's post-parse footprint. Two
follow-ups are cheap once this parser exists: a per-group hash so a change to
one group does not re-run `UpdateConfig` on every group
(`multi_sweep_service.go:278-291`), and sharing per-device state across
groups in the sweeper.

### Decision 6: Hashing and ordering

- Legacy format: `compute_config_hash/1` and its input stay unchanged; only
  the entries shrink (Decision 1). The emitted `groups` list is sorted by `id`,
  the same order `config_hash` already uses, so the config version no longer
  depends on database row order.
- `shared-targets/v1`: the hash covers the encoded `groups`, `device_table`
  and `target_sets`, all sorted as in Decision 3. It excludes `compiled_at`,
  as today.
- The two formats hash differently for the same groups. An agent that
  switches format therefore receives one full config, which is intended.

### Decision 7: Persisted-shape contract

The overlap view is the only reader of a compiled sweep config outside the
agent. Before any `shared-targets/v1` document is persisted in
`agent_config_instances`, the view gains a third arm that joins `groups` to
`target_sets` and `device_table` and yields the same
`(agent_id, sweep_group_id, target, declared_device_uid)` rows. Until then,
only the legacy shape may be persisted. If task 1.1 confirms that nothing
persists sweep configs, the view's declared arm is empty in production today;
that is reported as a separate defect, not fixed here.

## Risks / Trade-offs

- Silent coverage loss if gating is wrong. Mitigation: a behavioral test that
  a legacy-capability agent receives a document with no `format` key and with
  embedded `device_targets`, plus a Go parser parity test.
- Divergence between the formats over time. Mitigation: one shared
  row-to-target builder on the core side, and a Go test asserting that both
  parsers produce equal `SweepGroupsConfig` for equivalent inputs.
- A hidden consumer of a trimmed metadata key. Mitigation: the consumer audit
  above, plus a results-payload parity test before and after trimming.
- Shared-IP collisions: when two devices share an IP, which one a query keeps
  follows SRQL row order, exactly as the legacy `Map.put_new` does today. Both
  formats preserve that; making the winner deterministic (for example
  preferring a live record over a stale one) is a separate change.
- Stale cross-agent query results. Bounded by the same TTL that bounds the
  per-agent cache today; group edits invalidate explicitly.

## Migration Plan

1. Core: per-compile and cross-agent query sharing (Decision 2), sorted group
   emission (Decision 6), and metadata trimming (Decision 1). Legacy format
   only. Ship after chunked config pushes.
2. Agent release: dual-format parser and the capability (Decisions 4, 5).
3. Core: overlap-view arm (Decision 7), then enable format selection. Agents
   move to the new format as they upgrade.
4. Rollback: removing format selection returns every agent to the legacy
   format, which upgraded agents accept.

## Open Questions

- Should core log the per-agent sweep section size and format at generation,
  so the reduction can be verified without decoding `config_json`?
- Should the operator UI show which format an agent receives, or is a
  diagnostics field enough?
