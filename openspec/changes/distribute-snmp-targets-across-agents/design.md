# Design: Distribute SNMP polling targets across agents

## Context

### How SNMP targets reach an agent today

1. On every config poll (default every 300 s,
   `agent_config_generator.ex:88`), and on every control-stream push,
   `AgentConfigGenerator.load_snmp_config!/2`
   (`elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex:3883`)
   asks `ConfigServer` for the agent's `:snmp` config. It passes the agent's own
   host device uid.
2. `SNMPCompiler.do_compile/3` (`agent_config/compilers/snmp_compiler.ex:126`)
   resolves one profile through `fetch_profile/3` (`:212`). That is the
   highest-priority targeting profile matching the **agent's own host device**,
   or else the default profile, gated by `agent_ids`. Exactly one profile is
   compiled per agent.
3. `compile_profile/3` (`:330`) runs `TargetLimit.check/3` (`:343`) and then
   compiles every device the profile's `target_query` selects, in pages of 250
   (`:103`), plus the explicit `SNMPTarget` rows. Credentials are resolved per
   page.
4. The result becomes `Monitoring.SNMPConfig.targets`
   (`agent_config_generator.ex:4213`) inside the one `AgentConfigResponse`.
   Its `config_hash` is folded into the agent config version (`:3147`,
   `:3190`), so any target change re-versions and re-sends the whole response,
   sweeps and plugins included.
5. The gateway fetches that response from core with a 60 s call
   (`serviceradar_agent_gateway/agent_gateway_server.ex:68`). It streams the
   response in 1 MiB chunks up to a 64 MiB window
   (`config_chunks.ex:12-14`; agent side `go/pkg/agentgateway/gateway_client.go:79-80`).
   The agent's whole-fetch deadline is 90 s (`gateway_client.go:76`).
6. Invalidation: the `device_snmp_config` catalog entry
   (`agent_config/dependency_catalog.ex:266`) fires on every `Device` action.
   `SNMPCompiler.affected_agents_for_device/1` (`snmp_compiler.ex:229`) returns
   `:all_online` whenever an unpinned profile consumes the device. It also
   returns it when no profile and no reporting agent claim the device: the
   empty list maps to `:all_online`. So one device change recompiles every
   online agent's SNMP config. Invalidations
   coalesce on a 1 s debounce (`config_invalidator.ex:26`). Under steady
   inventory churn, core therefore recompiles the full target query once per
   agent about every second: O(agents x inventory) work.
7. On the agent, `SNMPAgentService.ApplyProtoConfig`
   (`go/pkg/agent/snmp_service.go:653`) hashes the new config, `Stop()`s the
   whole `SNMPService` and `Start()`s a new one (`:693-717`). Every collector is
   rebuilt and its counter-delta state is lost. This contradicts the existing
   `snmp-checker` scenario "Dynamic reconfiguration" ("existing targets
   continue polling without interruption").
8. Per target, `SNMPService.initializeTarget` (`go/pkg/agent/snmp/service.go:388`)
   creates:
   - a collector with its own connected `gosnmp` UDP socket, held for its
     lifetime (`client.go:51-109`);
   - a ticker goroutine started at the same instant as every other target's
     (`collector.go:140`);
   - an error goroutine and a results goroutine;
   - an aggregator that preallocates a `MaxPoints`-sample (1,000) ring buffer
     per series (`go/pkg/agent/core/ring.go:36`, `snmp/config.go:53`,
     `snmp_service.go:792`).
   One target's init failure aborts `Start` for all targets (`service.go:163`).
9. Samples are drained into the edge spool under the metrics grant
   (`go/pkg/agent/push_loop_snmp.go:58`). From there they reach the gateway,
   JetStream and EventWriter. That path is JetStream-first and is not changed
   here.

`TargetLimit` (`snmp_profiles/target_limit.ex`, commit `2a49504458`) refuses a
profile whose target count for one agent exceeds `snmp_max_targets`
(`edge/pipeline_settings.ex:25`, default 10,000, resolved agent, then partition,
then global, then code). The refusal applies on save
(`Changes.CheckTargetLimit`), on compile, and in the settings UI. The default
was chosen to keep one profile's config near 3 MB, not from measurement.

### Existing machinery this builds on

- `ServiceRadar.SweepJobs.ProducerAssignments` and `SweepProducerAssignment`:
  one assignment per (group, agent) with an atomic authority epoch;
  `ensure/3`, `bump_group/2` and `revoke_agents/2`.
- `LeaseAgents`: an agent's partition is its device's partition. An agent must
  report a capability to be leased.
- `LeasePass` (idempotent, stateless pass; bounded mints per pass) and
  `LeaseDelivery` (FULL versus TAIL pushes, a cursor plus high water,
  acknowledgement-gated cleanup).
- `ConfigChunks`: chunk budgets and digest validation, reused as is.
- `PipelineSettings`: resolution agent, then partition, then global, then code
  default. `snmp_max_targets` already lives there.
- `PolicyAssignmentPlanner` (plugin target policies): groups rows by the row's
  own agent. `AddonProfileReconciler`: targets are the agents' own hosts.

Sweeps do not divide targets either. A sweep group runs whole on every agent
it applies to. The epoch fencing and lease delivery are the reusable parts. The
target division is new.

## Goals / Non-Goals

Goals:
- Each SNMP target of a `distribute` profile is polled by `redundancy` agents
  (default 1), and each target of a `replicate` profile by every currently
  eligible pinned agent, as far as effective capacity allows. A shortfall is
  reported as `under_replicated` or `uncovered`.
- The bytes delivered to an agent, and the core work done for it, grow with the
  size of a change, not with the inventory.
- Per-agent capacity is measured and is a placement input. Shortfall is
  visible and is never a silent drop.
- One placement seam that other target-list workloads can adopt.

Non-Goals:
- Changing the telemetry path, the metric contract, or StarRocks/CNPG storage.
- Changing the credential model (unified CNPG credentials stay authoritative).
- Moving add-on, plugin-policy, or sweep workloads onto placement in this
  change. They are named follow-ups.
- Multitenancy. Placement is scoped to the deployment.

## Measurements

Method and results are recorded here so the defaults are traceable.
All figures come from a synthetic responder on loopback, not from any
deployment.

### Method

- Harness: a scratch `go_test` in `//go/pkg/agent/snmp`, never merged. It drives
  the production `SNMPService` (`NewSNMPServiceForAgent`, `Start`,
  `DrainMetrics`) unchanged.
- The responder is a child process of the test binary: an SNMP v2c responder
  built on `gosnmp`'s own decoder and encoder. It listens on 16 loopback UDP
  sockets with 4 readers each, with an injected 2 ms response delay standing in
  for RTT. It answers GET, GETNEXT and GETBULK over a synthetic MIB-II system
  group and 24-row `ifTable`/`ifXTable` columns. Poller CPU is measured with
  `getrusage(RUSAGE_SELF)`, which excludes the child.
- Run under Bazel on BuildBuddy RBE (`bazel test -c opt --config=remote`),
  `GOMAXPROCS=4` to approximate a modest agent host. The executor reported 64
  CPUs, `nofile` 1,048,576, and `ip_local_port_range` 32768-60999.
- Two target shapes:
  - `get`: 12 scalar OIDs in one GET PDU (5 system plus 7 `ifEntry` instance
    OIDs).
  - `walk`: 5 scalar OIDs plus 3 walked columns of 24 rows (one GETBULK each);
    4 requests and 77 series per poll.
- Targets use a 10 s interval, a 6x compression of the 60 s default, so the
  per-second load is the variable. Timeout 5 s, retries 3.
- Each size is warmed for 1.5 intervals, then measured over 3 intervals,
  draining every second. A poll counts when its `snmp_target_available` point
  is drained.
- Config bytes: `proto.Marshal` of a `Monitoring.SNMPConfig` of 10,000 targets
  shaped as the compiler emits them: a `sr:`-prefixed uid, a hostname, an IPv4
  host, port, version and interval fields, and the 17 OIDs of the built-in
  Standard templates. Communities and SNMPv3 secrets are placeholders of
  realistic length.

### Results: poller as shipped (default `MaxPoints` 1,000), 1,000 targets, 5 s interval

| Shape | Polls/s due | Polls/s done | Heap in use | Heap per target |
| --- | --- | --- | --- | --- |
| `get` (12 OIDs, 13 series) | 200 | 198 | 2,506 MB | about 2.5 MB |
| `walk` (77 rows plus availability) | 200 | 196 | 15,505 MB | about 15.5 MB |

Memory, not CPU, is the first ceiling. `NewRingBuffer` allocates `make([]T, capacity)`
eagerly, and a `DataPoint` is about 200 bytes. So every series holds about 200 KB
whether or not it ever fills, and each walked row is its own series. An 8 GB agent
host fits about 3,000 targets of the 12-OID shape, or about 500 of the walk shape.
Larger runs were not attempted with the default, because they would only measure
the executor's memory.

### Results: poller with `MaxPoints` 4 (approximating task 0.1), 10 s interval, `GOMAXPROCS=4`

| Shape | Targets | Polls/s due | Polls/s done | Done/due | Data points/s | CPU cores | CPU ms/poll | Heap MB | Longest drain |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| get | 5,000 | 500 | 488 | 0.98 | 5,856 | 0.30 | 0.62 | 594 | 0.3 s |
| get | 10,000 | 1,000 | 991 | 0.99 | 11,895 | 0.66 | 0.67 | 1,105 | 0.4 s |
| get | 20,000 | 2,000 | 1,985 | 0.99 | 23,816 | 1.33 | 0.67 | 2,309 | 0.7 s |
| get | 27,000 | 2,700 | 2,696 | 1.00 | 32,350 | 1.24 | 0.46 | 3,903 | 2.1 s |
| get | 35,000 | - | start failed at target 28,216 | - | - | - | - | - | - |
| walk | 5,000 | 500 | 522 | 1.04 | 38,352 | 1.38 | 2.64 | 2,178 | 1.3 s |
| walk | 10,000 | 1,000 | 532 | 0.53 | 43,624 | 2.13 | 4.02 | 3,314 | 1.3 s |
| walk | 20,000 | 2,000 | 335 | 0.17 | 41,036 | 2.68 | 8.01 | 5,316 | 4.8 s |
| walk | 27,000 | 2,700 | 295 | 0.11 | 41,030 | 2.75 | 9.31 | 9,170 | 3.8 s |
| walk | 35,000 | - | start failed at target 28,216 | - | - | - | - | - | - |

What the numbers show:

1. **Hard socket ceiling.** `SNMPService.Start` failed at target 28,216, the size
   of the executor's ephemeral port range (32768-60999) less the ports already in
   use. Each collector holds a connected UDP socket for its lifetime. The failure
   aborts `Start` for every target, not only the ones past the limit. One agent
   therefore cannot hold more than about 28,000 targets on a stock Linux host,
   however much CPU or memory it has.
2. **Throughput ceiling of about 40,000 data points per second.** The walk shape
   flattens at 41,000-44,000 points/s while CPU stays at 2.1-2.75 of 4 cores, and
   completed polls then fall as targets are added. `handleDataPoint` takes the
   service-wide `s.mu` for every point (`snmp/service.go:486`), and
   `DrainMetrics` holds the read side of that lock across every aggregator
   (`:296`). Drains reached 4.8 s, stalling every writer. The ceiling is lock
   contention, not CPU or the network.
3. **Residual memory of about 140 KB per target**, even with 4-point buffers.
   Each `gosnmp.GoSNMP` allocates a 65,535-byte receive buffer per connection
   (`gosnmp.go:376`, `rxBufSize`), and there is one connection per target. The
   three goroutines per target add stack on top: 81,004 goroutines at 27,000
   targets.
4. **CPU cost is small.** About 0.5-0.7 ms of CPU per 12-OID GET poll, and
   2.6 ms per 4-request walk poll before contention. One core sustains roughly
   1,500-2,000 GET polls/s.
5. **Phase alignment.** Every ticker starts within the start loop, so each
   interval begins with a burst of every target at once. Polls still completed
   on loopback; on a real network the burst lands on the agent's UDP receive
   buffer.

Caveats: loopback with a 2 ms injected delay understates real RTT and loss.
The responder is a separate process on the same executor and inherits
`GOMAXPROCS=4`. The `walk` saturation could include responder limits, although
`ok_ratio` stayed at 1.0 (no timeouts) and the poller's lock profile explains
it alone. SNMPv3 was not benchmarked. It adds HMAC and AES per message and
should be expected to raise CPU per poll. Its cost is bounded by the CPU
column, because the lock ceiling is per data point, not per message.

### Results: compiled `SNMPConfig` bytes per target (10,000 targets, 17 OIDs)

| Format | Bytes/target | 10,000 targets |
| --- | --- | --- |
| legacy, v2c | 952 | 9.5 MB |
| legacy, v3 authPriv | 1,005 | 10.1 MB |
| `shared-oids/v1`, v2c | 132 | 1.3 MB |
| `shared-oids/v1`, v3 authPriv | 185 | 1.9 MB |

The 10,000-target default was set to keep one profile near 3 MB at about 300
bytes per target. The legacy format, which most agents receive, is about three
times that.

### Delivery limits, from code

| Limit | Value | Source | Targets it admits (legacy / shared-oids, v3) |
| --- | --- | --- | --- |
| Unary `GetConfig` and legacy single-message push | 4 MiB agent receive default | `add-streamed-agent-config` design; gateway refuses larger legacy pushes | about 4,170 / 22,600 |
| Streamed config window | 64 MiB | `config_chunks.ex:14`, `gateway_client.go:80` | about 66,700 / 362,000 |
| Chunk payload | 1 MiB (2 MiB encoded chunk cap) | `config_chunks.ex:12-13` | n/a |
| Core call for a config | 60 s | `agent_gateway_server.ex:68` | compile time bound |
| Agent fetch deadline | 90 s | `gateway_client.go:76` | compile plus transfer |

A one-million-device inventory cannot be delivered to one agent in either
format. Under this design, a one-target delta is one entry of about 130-190
bytes plus framing.

### Defaults derived from the measurements

- **Delta-capable agents: `snmp_max_targets` code default 20,000.** At a 60 s
  interval, 20,000 targets of the 24-port walk shape produce about 26,000 data
  points/s. That is about 35 percent under the measured 40,000 points/s lock
  ceiling on 4 cores, before the Phase 0 fixes raise it. 20,000 of the 12-OID
  shape is about 333 polls/s, under a fifth of one core. It also stays under the
  28,000 socket ceiling even before task 0.3 removes that ceiling. Measured
  capacity (D10) replaces the default per agent once reports arrive. At this
  default, one million devices need at least 50 agents with redundancy 1.
- **Legacy agents: legacy ceiling code default 4,000.** A legacy agent may lack
  `config_push_chunks`. Then its whole config must fit the 4 MiB single-message
  limit: 4,000 legacy-format SNMPv3 targets are about 3.8 MiB, leaving about
  0.2 MiB for the rest of the config. An operator with a large plugin config
  lowers it per agent. On pre-Phase-0 agents, 4,000 targets of the 12-OID shape
  still preallocate about 10 GB. That is less than the 10,000 targets those
  agents can be sent today, but Phase 0 should reach the fleet before placement
  does (open question 7).

### Core-side bounds (derived, not measured)

- One placement row per (target, owner). One million devices at redundancy 1 is
  about one million rows. At roughly 200 bytes a row plus a per-agent revision
  index, that is a few hundred MB in CNPG, comparable to the device table.
- A placement pass reads each enabled profile's query in 250-device keyset
  pages: about 4,000 pages for one million devices, once per pass instead of
  once per agent. Pass duration at that size is measured by task 8.4.

## Decisions

### D1. Core owns placement, persisted per target

Placement is computed by core and stored as one row per (workload, target key,
agent). Each row has a state (`active`, `draining`, `revoked`), an authority
generation, a reason, the agent's revision at which it changed, a credential
reference digest, and the last poll outcome the agent reported.

Rejected:
- **Agents self-select by consistent hashing over a membership list.** This
  needs a membership view every agent agrees on, which partitions and restarts
  break. It gives no audit trail, no capacity view and no handover state.
- **Hashing at compile time without persistence.** Every recompile could move
  targets as membership or weights change. There is nowhere to record why a
  target moved or which generation an acknowledgement belongs to.
- **Extending `SweepProducerAssignment` directly.** Its key is (group, agent),
  one row per agent for the whole group. Per-target ownership is a different
  cardinality. The epoch semantics, the `ensure`/`bump`/`revoke` vocabulary and
  the system-actor-only writes are reused in the new table rather than
  overloading that one.

### D2. A device belongs to exactly one profile

The placement pass resolves each device to its highest-priority matching
profile, or the default. It walks each enabled targeting profile's query in
priority order with the interface-aware page walk
(`SNMPCompiler.reduce_target_pages/4`), so an `in:interfaces` query selects
only devices that have a matching interface. A device takes the first profile
whose walk selects it, and devices no walk selects take the default profile.
The single-device fast path (D12) applies the same rule to one device and
admits it to a profile only when that walk would, including its in-service
filter, so an inactive device is not placed; it does not use
the any-device-in-service shortcut that
`SrqlTargetResolver.resolve_for_devices/3` applies to interface queries. No
agent id filters which profiles compete: pinned profiles compete on priority
like any other, and pins apply only when choosing owners (D3). This is what
the existing "Profile priority ordering" requirement states.

Today the choice is made once per agent from the agent's own device, so the
same device can be polled under the default profile by some agents and under a
targeting profile by others. After this change it is polled once, under one
profile. That is a visible behavior change: the migration notes call it out.

### D3. Eligibility: pinning, then partition

Pinned profiles (`agent_ids`) restrict eligibility to the listed agents. Pins
no longer mean "each listed agent polls everything". Unpinned profiles make the
agents in the device's partition eligible, with the agent's partition defined
as for `LeaseAgents`. An agent must hold an unexpired liveness lease and either advertise
`snmp-target-deltas:v1` or be served through legacy delivery (D9).

Rejected: **inferring reachability from `Device.agent_id`.** That field
identifies the agent that runs on a device. On a sampled deployment it is set
almost only for agents' own host devices, so it says nothing about who can
reach an arbitrary device. Reachability is learned from poll outcomes (D6).

### D4. Sticky, weighted rendezvous selection

A new or displaced target is assigned to the top-`redundancy` eligible agents
by highest-random-weight hashing, or to every eligible agent for a `replicate`
profile, in both cases only on agents with room under their effective capacity. The weight is the agent's remaining
capacity. A target keeps its owner unless one of these holds:

- the owner is ineligible (`owner_ineligible`);
- its liveness lease expired (`owner_lost`);
- it is over its effective capacity (`over_capacity`);
- the target failed on it (`unreachable_on_owner`);
- a bounded rebalance chose it (`rebalance`).

A rebalance moves at most a configured number of targets per pass, from agents
above a high watermark to agents below a low watermark. It only moves load
between agents within their effective capacity: a receiving agent never ends
the pass above it. An `over_capacity` move obeys the same rule. When no
eligible agent has room, the targets stay and the agent is reported over
capacity.

Rendezvous hashing moves only about 1/n of targets when an agent leaves. With
stickiness, an agent joining moves no existing owner. It does fill
shortfalls: an `under_replicated` target, including a `replicate` target the
agent is newly eligible for, gains the joining agent as an additional owner.
A pass assigns free capacity in a fixed order: (1) `uncovered` targets,
including re-placement after `owner_lost` and `owner_ineligible`; (2)
`unreachable_on_owner` moves; (3) `over_capacity` sheds; (4)
`under_replicated` and `replicate` shortfalls; (5) bounded rebalance. Each
step uses only the capacity the earlier ones left. An agent that cannot shed
for lack of room stays reported over capacity.

Rejected:
- **Least-loaded at arrival.** It depends on arrival order, is not
  reproducible, and every recomputation churns.
- **A consistent-hash ring without stickiness.** A capacity weight change
  rehashes a slice of the fleet.
- **Pure stickiness.** The fleet never rebalances after growth.

### D5. Handover: generations, make-before-break for planned moves

Every ownership change issues a new authority generation through an atomic
update, never repeated or lowered, as with `ProducerAssignments`.

- **Planned moves** (`rebalance`, `over_capacity`, `unreachable_on_owner`):
  the new owner is placed `active` and the old row becomes `draining`. The old
  row is revoked when the new owner acknowledges the generation and reports a
  completed poll, or after one interval plus the handover grace. The overlap is
  at most one interval plus grace. During it, both agents may produce a sample
  for the same interval.
- **Failure moves** (`owner_lost`, `owner_ineligible`): the old row is revoked
  at once. A lost session becomes `owner_lost` only when the liveness lease
  expires, so the gap is the liveness grace plus one placement pass plus
  delivery. `owner_ineligible` is only for pin, partition and capability
  changes.
- A planned move goes only to an agent with room; with none, the target stays
  on its owner. A target with a draining row is not moved again until that
  handover completes.
- An acknowledgement carries the generation. One for a superseded generation
  is ignored.

Samples are not fenced by generation in this change. A duplicate sample within
one interval is bounded and attributable, because every sample already carries
its agent id. Adding a generation to the edge record contract and refusing late
samples at the gateway is possible but adds contract and gateway work for a
narrow race. See open question 4.

### D6. Reachability is learned from poll outcomes

Agents report per-target outcomes (last success, consecutive failures) in
their acknowledgement path. These are control-plane facts on the placement
row, not metrics.

After `F` consecutive failures, the target moves to the next candidate that
stays within its effective capacity, and the failing agent is excluded for
that target for a backoff period. When no candidate has room, or the target
already has a draining row, the target stays on its owner. After `C`
candidates fail, the target stays on the owner that reached the limit and is
reported unreachable. Without that limit, a device
that is down for everyone would rotate through the fleet forever.

The `C` limit bounds how many agents try a dead device in one cycle: at most
`C` agents, `F` consecutive failed polls each, then the target holds on the
agent that reached the limit. The holding agent keeps polling at the target's
ordinary interval, and its continued failures do not restart the backoff. When
the backoff expires without a successful poll, a new cycle of at most `C`
agents may run, so a permanently down device gets at most one cycle of
candidate trials per backoff period. The code defaults are `F` = 3, `C` = 3
and a 1 hour backoff (open question 6).

### D7. Delivery: profile definitions in config, targets as revisioned deltas

For a delta-capable agent, the compiled `SNMPConfig` keeps profile-level
definitions for the profiles the agent's targets reference, and its config
version changes when that set of profiles or one of their definitions changes.
Applying a changed definition updates that profile's collectors in place.
A config version that adds a profile is published no later than the target
revision that first references it, and a profile leaves the config only after
the agent acknowledges the revision that revokes its last target. The agent
starts a collector only when both the target and its profile are applied. The
definitions are a new `profiles` list with OID sets, intervals,
timeouts and retries. Targets move to a new server-streaming
`SyncSNMPTargets(agent_id, from_revision)` RPC. Pages carry entries
(`upsert`/`revoke`, compiled target, generation), each page within the
`ConfigChunks` budgets. The final page carries the new revision, a snapshot
flag and a payload digest. A control-stream `SNMPTargetRevisionHint` carries
only a revision, and the config poll response also reports it.

Per-agent revisions come from the placement rows themselves: each row records
the agent revision at which it last changed. Revoked rows are kept as
tombstones until the agent acknowledges a later revision. A delta is therefore
a keyset read ordered by revision. When `from_revision` is below the
compaction floor, the response is a snapshot of the agent's active and draining rows. This
is the FULL/TAIL split of `LeaseDelivery`, applied per target.

The agent applies a delivery only after the final page validates. A partial
delivery leaves the last applied revision in place.

Rejected:
- **Keep targets in the monolithic config and rely on chunking.** Chunking
  (`add-streamed-agent-config`) fixed the message-size failure but not the
  cost. Every target change re-versions the whole response and re-sends
  everything. Generating the version still compiles the full target query per
  agent per poll.
- **NATS KV or the object store per agent.** That is a second config transport
  with its own ACLs. KV values default to a 1 MiB maximum. It would put
  credential-bearing payloads in the bus, and it bypasses the gateway's mTLS
  identity checks.
- **Push the delta itself on the control stream.** A push is lost when the
  stream drops. A hint plus pull makes the agent's revision the single source
  of truth and makes recovery after reconnect the normal path.

### D8. Credentials resolve at serve time

Placement rows hold the credential reference (profile credential, device
override, or explicit target binding) and a digest of the resolved
credential's version. Secrets are resolved by `CredentialResolver` when a page
is served, as the compiler does now. Rotation advances the revision only for
targets whose resolved digest changed. Inline legacy target credentials keep
resolving (`fix-default-snmp-profile-preview`). Nothing secret lands in a new
table.

### D9. Legacy agents participate through the monolithic path

An agent without `snmp-target-deltas:v1` is still eligible. Its placed share is
compiled into the existing `SNMPConfig.targets`, bounded by a lower legacy
ceiling, because that agent still has the restart-on-change and preallocation
costs. Its config version changes when its placement changes, as it does
today, and also when a referenced profile definition or a placed target's
resolved credential digest changes. This retires the per-profile refusal immediately, without waiting for a
fleet upgrade, and avoids double polling in mixed partitions.

Rejected: **exclude legacy agents from placement and leave them on the old
compile.** That keeps double polling in any partition with one legacy agent and
keeps `TargetLimit` alive.

### D10. Capacity model and the fate of `snmp_max_targets`

- **Cost unit:** data points per second, the unit the measured ceiling is in
  (Measurements, finding 2). A target costs `(scalar_oids + sum of walk rows + 1) / interval`.
  Request count is tracked alongside for network pacing, but the measured
  bottleneck is per point. Walk rows start from a per-template estimate and are
  corrected by agent-reported actuals.
- **Measured capacity:** an agent reports per window the targets held, polls
  due, polls completed within their interval, data points produced, requests
  sent and scheduling lag. Core first recomputes the placed cost with the
  actual series counts in that report. While on-time polls stay at or above a
  configured threshold (recommended 99 percent), measured capacity only rises,
  to the highest sustained point rate seen. When on-time polls stay below it
  for a configured number of consecutive windows (recommended 3), measured
  capacity is set to the achieved on-time point rate, which is below the
  recomputed placed cost, so the next pass sheds load with `over_capacity`. Until the first report, only
  the target-count ceiling applies.
- **Effective capacity:** two limits that must both hold. When admitting new
  work, active and draining placements both count until the draining row is
  revoked. Over-capacity excess is computed from active placements only, so a
  target already draining away counts as shed and a pass stops at the true
  excess or when no receiver has room. The count of targets
  placed on the agent stays at or under its resolved `snmp_max_targets`, and
  the summed point-rate cost of those targets stays at or under its measured
  point rate. The two are in different units and are not compared with each
  other.
- **`snmp_max_targets` is repurposed, not retired.** The column, its
  resolution order and its admin surfaces stay. Its meaning changes from "per
  (profile, agent) refusal threshold" to "most SNMP targets placed on one
  agent, summed across profiles". The name already says that. An operator
  still needs a hard cap, for example a small appliance agent, in the unit
  operators think in. The code default changes to the measured value (see
  Measurements). A second code default, the legacy ceiling, applies to agents
  without delta delivery. No Helm value is added. Both defaults live in code,
  and overrides live in `edge_pipeline_settings`.
- **Retired:** `ServiceRadar.SNMPProfiles.TargetLimit`,
  `Changes.CheckTargetLimit`, the compile-time refusal in
  `SNMPCompiler.do_compile_profile/3`, the
  `[:serviceradar, :snmp, :target_limit_exceeded]` event and its warning
  ledger subject, and the settings-list refusal message. No caller remains.

### D11. Coverage instead of refusal

A target that no eligible agent can take is `uncovered`, with reason
`no_eligible_agent` or `fleet_capacity_exhausted`. A target that ends a pass
with no owner is uncovered; one with fewer owners than desired is
`under_replicated`, still polled, and counted separately. Counts
per profile and partition go to telemetry, an alert rule and the capacity view.
Placed targets are never evicted to make room. When capacity runs out, the
newest arrivals stay uncovered. That order is deterministic and is not a
choice about which devices matter.

Save-time behavior (open question 5): the form shows projected coverage and
the save is not refused, because a saved profile
with partial coverage is visible and fixable by adding agents, while a refused
profile polls nothing.

### D12. One reconcile pass instead of per-agent compiles

A periodic placement pass (Oban, idempotent, stateless, like `LeasePass`)
walks each enabled targeting profile's query once in keyset pages, in priority
order, skips devices already claimed by a higher-priority profile in the same
pass, gives devices no walk claims to the default profile, and diffs the result
against the placement rows. A `Device` change re-evaluates that device only:
its profile resolution, eligibility and compiled-target digest. This replaces
`affected_agents_for_device/1` and the `:all_online` fleet invalidation. The
cost moves from O(agents x inventory) per invalidation to O(inventory) per pass
plus O(1) per device event.

### D13. Shared seam

`ServiceRadar.Edge.TargetPlacement` is a behaviour with callbacks for:
targets of a workload (paged), eligible agents for a target, cost of a target,
agent capacity, redundancy, and delivery capability. The placement table is
keyed by workload. SNMP is the only implementation in this change.

Named follow-ups (each a separate change):
1. **Query-driven plugin target policies.** `PolicyAssignmentPlanner` groups
   rows by the row's own agent. Policies that poll remote endpoints, rather
   than agent hosts, could place through the seam.
2. **Sweep groups with static CIDRs.** They run whole on every agent today.
   Range splitting across agents would use the same placement plus the existing
   lease delivery.
3. **Add-on profile target truncation.** `AddonProfileReconciler.extract_targets/2`
   applies `Enum.take(max_targets)` (default 10,000) after resolution, which
   silently drops targets beyond the cap. It should count and report them, or
   place them. This is a defect independent of this change.
4. **Per-target SNMP status at scale.** `SNMPService.GetStatus` builds a map of
   every target's status per request. With deltas and capacity reports, the
   health payload should carry aggregates only.

### D14. Telemetry path unchanged

Samples keep the edge spool, metrics grant, gateway, JetStream and EventWriter
path. Placement adds control-plane rows in CNPG (current state, as for
`SweepProducerAssignment`) and capacity reports on the control stream. No
metric is written to a database directly.

## Migration

1. **Schema, additive:** create the placement table, add
   `snmp_profiles.placement_mode` and `snmp_profiles.redundancy`, and record
   the revision floor.
2. **Profiles:**
   - Unpinned profiles become `distribute` with the redundancy open question 2
     settles.
   - Pinned profiles become `distribute` among their pinned agents (open
     question 1).
   - The seeded default profile (`in:devices`) is unchanged.
   - No credential is re-entered. Explicit `SNMPTarget` rows keep their ids and
     credentials and are placed per open question 3.
3. **First pass:** the placement pass seeds placements by D4 within each
   partition. No per-agent poll history exists in CNPG today
   (`device_snmp_facts` has no agent column), so the seed cannot prefer
   last-successful pollers. Reachability failover (D6) corrects misplacements
   within `F` intervals.
4. **Delivery switch:** delta-capable agents receive a snapshot, then deltas.
   Legacy agents receive their placed share monolithically on their next
   config generation. In both cases the profile's whole target set stops being
   sent, so the duplicate polls end.
5. **Retirement:** `TargetLimit` and `CheckTargetLimit` are deleted in the same
   release as the switch. `snmp_max_targets` changes meaning in that release,
   and its docs in `docs/docs/snmp.md` change with it.

Behavior changes operators will see:
- A device is polled once instead of by every agent.
- Under one profile instead of a mix.
- Sample cadence per device is unchanged, but the reporting agent may differ
  from before.

## Rollout

- Phase 0 (agent prerequisites, tasks 0.x) ships first and stands alone. It
  fixes measured defects (buffer preallocation, restart-on-change, socket per
  target) that cap any agent, distributed or not.
- Phase 1: placement, coverage, legacy-path delivery of placed shares, and
  retirement of `TargetLimit`. All agents work. Capacity defaults are
  conservative for legacy agents.
- Phase 2: delta delivery and capacity reports for upgraded agents. The
  ceiling default rises to the measured value for agents that advertise
  `snmp-target-deltas:v1`.
- Verification per phase on a scratch install with a synthetic inventory. The
  1M-device check is a placement-pass and delivery-bytes test with synthetic
  agents, not a live fleet.

## Failure modes

| Failure | Effect | Bound |
| --- | --- | --- |
| Core unavailable | Agents keep polling their last applied set | Until core returns |
| Placement pass errors on a profile | That profile's placements stay as they were; error reported | One pass |
| Agent dies | `owner_lost` after the liveness grace; targets re-placed | Grace + pass + delivery |
| Agent reconnects after a move | Pulls from its revision; revokes arrive as tombstones or a snapshot | One delivery |
| Partial delivery | Nothing applied; retried | Next hint or poll |
| Hint lost | Config poll reports the revision | One poll interval (300 s) |
| Revision history compacted | Snapshot | One snapshot |
| Credential store read fails at serve time | Page refused, delivery fails, agent keeps its set | Until store recovers |
| All candidates fail a device | Stays placed, reported unreachable, no rotation | One cycle of at most `C` agents x `F` failures per backoff period; the holder keeps its ordinary interval |
| Fleet out of capacity | Newest targets `uncovered`, alerted | Until capacity added |
| Planned move | Duplicate samples for at most one interval plus grace | Per move |
| Thundering herd after restart | Jittered phases, bounded workers | Worker limit |

## Open Questions (for the user)

1. **Pinned profiles at migration.** Today a profile pinned to agents A, B and
   C makes each of them poll every target. Migrate pinned profiles to
   `distribute` (divide among A, B, C; recommended, consistent with "each
   device polled once"), or to `replicate` (preserve today's behavior exactly)?
   **Recommended answer, accepted by the user on 2026-11-14:** `distribute`
   among the pinned agents.
2. **Default redundancy.** 1 (recommended) or 2 for production deployments?
   With 2, the fleet does double the polling. A single agent loss becomes
   gap-free at the cost of steady duplicate samples.
   **Recommended answer, accepted by the user on 2026-11-14:** 1.
3. **Explicit `SNMPTarget` rows have no partition.** Place them among pinned
   agents when pinned. When unpinned, use (a) the partition of an inventory
   device whose IP equals the target host (recommended), else the default
   partition, or (b) every connected eligible agent.
   **Recommended answer, accepted by the user on 2026-11-14:** (a), the
   partition of the inventory device with the same IP.
4. **Sample fencing.** Accept duplicate samples during planned handover
   (recommended for now), or add the authority generation to the SNMP edge
   record contract and drop superseded-generation samples at the gateway?
   **Recommended answer, accepted by the user on 2026-11-14:** accept duplicate
   samples during planned handover.
5. **Save-time behavior when the fleet cannot cover a profile.** Accept and
   report coverage (recommended), or refuse the save when projected demand
   exceeds the eligible fleet's remaining capacity?
   **Recommended answer, accepted by the user on 2026-11-14:** accept the save
   and report coverage.
6. **Reachability parameters.** `F` = 3 consecutive failures, `C` = 3
   candidates, backoff 1 hour: acceptable as code defaults, with overrides in
   `edge_pipeline_settings`?
   **Recommended answer, accepted by the user on 2026-11-14:** move after 3
   consecutive failures, try at most 3 agents, back off for 1 hour.
7. **Legacy ceiling and Phase 0 ordering.** Ship the Phase 0 agent fixes in a
   release before placement (recommended), and keep the legacy ceiling at
   4,000? Or lower it further for agents that predate Phase 0, given about
   2.5 MB per 12-OID target of preallocated buffers on those agents?
   **Recommended answer, accepted by the user on 2026-11-14:** ship the Phase 0
   agent fixes first and keep the legacy ceiling at 4,000.
