## ADDED Requirements

### Requirement: Core places each target on a bounded set of agents
The system SHALL decide which agents run a target-list workload by persisting placements per target, each owned by one agent chosen from the target's eligible agents. A target's desired owner count is `redundancy`, or every currently eligible agent when the workload replicates the target. After a placement pass, a target with its desired count of active owners is covered, a target with at least one active owner but fewer than its desired count is `under_replicated`, and only a target that ends the pass with no active owner is `uncovered`. A failure move that revokes an owner and places a new one in the same pass SHALL NOT mark the target `uncovered`.
While an agent's placement is `draining` during a planned move, core SHALL keep including the target in that agent's deliveries, snapshots included, and the agent keeps running it. Once a placement is revoked, core SHALL stop including the target in that agent's deliveries, and the agent SHALL stop running it when it applies the delivery that revokes it.
A workload is a kind of per-target polling: SNMP is the first. A target is a stable key within that workload, such as a device uid or an explicit target id. Agents never select their own targets.

#### Scenario: One owner by default
- **GIVEN** a workload target whose redundancy is 1
- **AND** three connected agents are eligible for it
- **WHEN** the placement pass runs
- **THEN** exactly one of the three agents holds an active placement for the target
- **AND** only that agent is delivered the target

#### Scenario: Redundancy places distinct owners
- **GIVEN** a workload target whose redundancy is 2
- **AND** three connected agents are eligible for it
- **WHEN** the placement pass runs
- **THEN** exactly two distinct agents hold active placements for the target

#### Scenario: Redundancy larger than the eligible set
- **GIVEN** a workload target whose redundancy is 3
- **AND** only two agents are eligible for it
- **WHEN** the placement pass runs
- **THEN** both agents hold active placements
- **AND** the target is reported as under-replicated with the shortfall of one

### Requirement: Eligibility follows pinning and partition
The system SHALL treat an agent as eligible for a target only when all of these hold:
- the agent is in the workload's pinned agent set, or, when the set is empty, its partition equals the target's partition;
- the agent is connected;
- the agent reports the capability the workload's delivery requires, or the workload's legacy delivery covers it.
An agent's partition is the partition of its own device, as for sweep leases.

#### Scenario: Unpinned target stays in its partition
- **GIVEN** an unpinned workload and a device in partition `SITE01`
- **AND** connected agents in partitions `SITE01` and `SITE02`
- **WHEN** the placement pass runs
- **THEN** only agents in `SITE01` are candidates for the device

#### Scenario: Pinned workload restricts candidates
- **GIVEN** a workload pinned to agents `agent-a` and `agent-b`
- **WHEN** the placement pass runs
- **THEN** only `agent-a` and `agent-b` are candidates for its targets, regardless of partition

#### Scenario: No eligible agent
- **GIVEN** a device whose partition has no connected eligible agent
- **WHEN** the placement pass runs
- **THEN** the target has no owner and is marked `uncovered` with reason `no_eligible_agent`

### Requirement: Placement is sticky and moves only for a stated reason
The system SHALL keep a target on its current owner unless one of these holds: the owner is no longer eligible, its liveness lease expired, its load exceeds its effective capacity, the target failed on it under the reachability rule, or a bounded rebalance selected it. A move for `over_capacity` or `rebalance` SHALL go only to an agent that stays within its effective capacity after the move. When no eligible agent has room, an `over_capacity` target SHALL stay on its owner and the agent SHALL be reported over capacity.
When an eligible agent with capacity becomes available, the system SHALL add owners to `under_replicated` targets that it can serve with the capacity left by the earlier steps of the order below, including replicated targets it has newly become eligible for, without moving any owner a target already has.
A placement pass SHALL assign free capacity in this order: first `uncovered` targets, which have no owner, including re-placement after `owner_lost` and `owner_ineligible`; then `unreachable_on_owner` moves; then `over_capacity` sheds; then `under_replicated` targets, including replicated targets missing an eligible agent; then bounded rebalance. A later step uses only the capacity the earlier steps left. An agent that cannot shed for lack of room SHALL stay reported over capacity.
Every move SHALL record its reason. Among eligible agents, a new owner SHALL be chosen by rendezvous hashing weighted by remaining capacity, so that the same inputs always choose the same owner.

#### Scenario: Agent joins a partition
- **GIVEN** a partition whose targets are placed on two agents below their capacity, with no target under-replicated
- **WHEN** a third eligible agent connects
- **THEN** no existing placement moves because of the join alone
- **AND** targets placed after the join may be placed on the new agent

#### Scenario: Agent join fills a redundancy shortfall
- **GIVEN** a target whose redundancy is 2, placed only on `agent-a` and reported `under_replicated`
- **WHEN** eligible `agent-b` connects below its capacity
- **THEN** the next placement pass adds an active placement on `agent-b`
- **AND** the placement on `agent-a` is unchanged

#### Scenario: Pinned agent joins a replicated target
- **GIVEN** a replicated target pinned to `agent-a` and `agent-b`, placed on `agent-a` while only `agent-a` was connected
- **WHEN** `agent-b` connects below its capacity
- **THEN** the next placement pass adds an active placement on `agent-b`
- **AND** the placement on `agent-a` is unchanged

#### Scenario: Uncovered targets come before shortfalls
- **GIVEN** 50 uncovered targets and 50 targets with redundancy 2 placed only on `agent-a`
- **WHEN** eligible `agent-b` connects with room for 50 targets
- **THEN** the next placement pass places the 50 uncovered targets on `agent-b`
- **AND** the 50 under-replicated targets stay under-replicated

#### Scenario: Shortfall fill comes before rebalance
- **GIVEN** targets with redundancy 2 placed only on `agent-a`, which is above the rebalance high watermark
- **WHEN** eligible `agent-b` connects with room for 100 targets
- **THEN** the next placement pass gives that room to the under-replicated targets first
- **AND** rebalance moves targets onto `agent-b` only with the room left after the shortfall fill

#### Scenario: Owner leaves
- **GIVEN** a target placed on `agent-a`
- **WHEN** `agent-a`'s liveness lease expires
- **THEN** the target is placed on another eligible agent with reason `owner_lost`
- **AND** the move happens within the liveness grace plus one placement pass

#### Scenario: Bounded rebalance
- **GIVEN** an agent whose load is above the rebalance high watermark while another eligible agent is below the low watermark
- **WHEN** the placement pass runs
- **THEN** at most the configured number of targets per pass move from the loaded agent, with reason `rebalance`
- **AND** no receiving agent exceeds its effective capacity

### Requirement: Ownership moves under a new authority generation
The system SHALL give each placement an authority generation and SHALL issue a new generation whenever ownership changes.
A planned move (`rebalance`, `over_capacity`, `unreachable_on_owner`) SHALL be make-before-break. The previous owner keeps its placement until the new owner acknowledges installing the target and reports a completed poll, or until one poll interval plus the handover grace elapses. A move for `owner_lost` or `owner_ineligible` SHALL revoke the previous placement immediately.

#### Scenario: Planned move overlaps by at most one interval
- **GIVEN** a target with a 60 second interval moving from `agent-a` to `agent-b` for rebalance
- **WHEN** `agent-b` acknowledges the target and reports its first completed poll
- **THEN** `agent-a`'s placement is revoked under a new generation
- **AND** both agents polled the target for at most one interval plus the handover grace

#### Scenario: Stale owner acknowledgement is ignored
- **GIVEN** a placement revoked from `agent-a` under generation 7
- **WHEN** `agent-a` later acknowledges a delivery made under generation 6
- **THEN** core does not reactivate `agent-a`'s placement

### Requirement: Capacity is an input to placement
The system SHALL place targets on an agent only within its effective capacity, which is two limits that SHALL both hold: the count of targets placed on the agent stays at or under its operator ceiling, and the summed cost of those targets stays at or under its measured capacity. The operator ceiling is a target count that resolves agent setting, then partition setting, then global setting, then the code default for the agent's delivery path. Measured capacity and cost are in the workload's cost unit, so a target polled every 10 seconds costs six times one polled every 60 seconds. Active and draining placements both count toward an agent's effective capacity until the draining placement is revoked. Until an agent first reports measurements, only the operator ceiling applies.

#### Scenario: Measured capacity below the ceiling
- **GIVEN** an agent whose operator ceiling allows 20,000 targets
- **AND** whose reported measurements sustain the cost of 8,000 targets of the current mix
- **WHEN** the placement pass runs
- **THEN** the agent is placed no more cost than its measured capacity, about 8,000 such targets

#### Scenario: Faster targets hit the cost limit first
- **GIVEN** an agent whose operator ceiling allows 20,000 targets and whose measured capacity is 26,000 points per second
- **WHEN** placement offers it targets that each cost about 7.8 points per second
- **THEN** it is placed no more than about 3,300 of them

#### Scenario: Agent without measurements
- **GIVEN** a newly connected agent that has not yet reported measurements
- **WHEN** the placement pass runs
- **THEN** it is placed no more targets than its operator ceiling, which falls back to the code default for its delivery path

### Requirement: Uncovered targets are counted, never dropped
The system SHALL mark a target `uncovered` when a placement pass ends with no active owner for it, and SHALL report it.
Each uncovered target SHALL carry a reason: `no_eligible_agent` or `fleet_capacity_exhausted`. An `under_replicated` target is polled and is not `uncovered`; it SHALL be counted and reported separately with its shortfall. The counts per workload, profile and partition SHALL be exposed through telemetry, alerts and an operator capacity view. A target that already has an owner SHALL NOT lose it to make room for another target.

#### Scenario: Fleet runs out of capacity
- **GIVEN** a partition whose eligible agents are at their effective capacity
- **WHEN** 500 new devices start matching an SNMP profile there
- **THEN** the 500 devices are marked `uncovered` with reason `fleet_capacity_exhausted`
- **AND** devices already placed keep their owners
- **AND** an alert reports the profile, the partition and the count

#### Scenario: Capacity returns
- **GIVEN** uncovered targets in a partition
- **WHEN** a new eligible agent connects
- **THEN** the next placement pass places them and clears their uncovered state

### Requirement: Placement reconciles in one pass, not per agent
The system SHALL compute desired placements by evaluating each workload's target selection once per pass, reading pages through a keyset cursor. It SHALL NOT compile the selection once per agent. A change to one device SHALL re-evaluate only that device's placement and deliveries.

#### Scenario: Device change touches one placement
- **GIVEN** an SNMP profile that selects 1,000,000 devices across 200 agents
- **WHEN** one device's polling address changes
- **THEN** only the agents owning that device receive a delta
- **AND** no other agent's SNMP delivery changes revision
