## ADDED Requirements

### Requirement: Core places each target on a bounded set of agents
The system SHALL decide which agents run a target-list workload by persisting one placement per target. Each placement has between 1 and `redundancy` active owners chosen from the target's eligible agents. A target SHALL NOT be run by an agent that holds no active placement for it.
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
The system SHALL keep a target on its current owner unless one of these holds: the owner is no longer eligible, its liveness lease expired, its load exceeds its effective capacity, the target failed on it under the reachability rule, or a bounded rebalance selected it.
Every move SHALL record its reason. Among eligible agents, a new owner SHALL be chosen by rendezvous hashing weighted by remaining capacity, so that the same inputs always choose the same owner.

#### Scenario: Agent joins a partition
- **GIVEN** a partition whose targets are placed on two agents below their capacity
- **WHEN** a third eligible agent connects
- **THEN** no existing placement moves because of the join alone
- **AND** targets placed after the join may be placed on the new agent

#### Scenario: Owner leaves
- **GIVEN** a target placed on `agent-a`
- **WHEN** `agent-a`'s liveness lease expires
- **THEN** the target is placed on another eligible agent with reason `owner_lost`
- **AND** the move happens within the liveness grace plus one placement pass

#### Scenario: Bounded rebalance
- **GIVEN** an agent whose load is above the rebalance high watermark while another eligible agent is below the low watermark
- **WHEN** the placement pass runs
- **THEN** at most the configured number of targets per pass move from the loaded agent, with reason `rebalance`

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
The system SHALL place targets on an agent only up to its effective capacity. That is the lower of the agent's measured capacity and its operator ceiling, which resolves agent setting, then partition setting, then global setting, then code default. Load SHALL be counted in the workload's cost unit, so a target polled every 10 seconds costs six times one polled every 60 seconds.

#### Scenario: Measured capacity below the ceiling
- **GIVEN** an agent whose operator ceiling allows 20,000 targets
- **AND** whose reported measurements sustain the load of 8,000 targets of the current mix
- **WHEN** the placement pass runs
- **THEN** the agent is placed no more load than 8,000 such targets represent

#### Scenario: Agent without measurements
- **GIVEN** a newly connected agent that has not yet reported measurements
- **WHEN** the placement pass runs
- **THEN** its capacity is the workload's code default for its delivery path, capped by its operator ceiling

### Requirement: Uncovered targets are counted, never dropped
The system SHALL mark a target `uncovered` when no eligible agent has capacity for it, and SHALL report it.
Each uncovered target SHALL carry a reason: `no_eligible_agent`, `fleet_capacity_exhausted` or `under_replicated`. The counts per workload, profile and partition SHALL be exposed through telemetry, alerts and an operator capacity view. A target that already has an owner SHALL NOT lose it to make room for another target.

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
