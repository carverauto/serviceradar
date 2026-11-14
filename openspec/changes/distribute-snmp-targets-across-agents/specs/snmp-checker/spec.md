## MODIFIED Requirements

### Requirement: SNMP Profile-Based Configuration
The SNMP monitoring system MUST support profile-based configuration where administrators define SNMP profiles that are assigned to devices via SRQL queries. A profile states what to poll; the platform decides which agent polls each target. An agent SHALL be delivered only the targets placed on it, across every profile those targets resolve to, and never a profile's whole target set because the profile applies to it.

#### Scenario: Device receives profile via SRQL match
- **GIVEN** an SNMP profile with `target_query: "in:devices tags.snmp:enabled"`
- **AND** a device with tag `snmp: enabled`
- **WHEN** the device is placed on an agent and that agent requests its SNMP targets
- **THEN** the agent receives the device as a target of that profile, including its resolved credentials

#### Scenario: Unplaced device is not delivered
- **GIVEN** an SNMP profile that selects a device placed on `agent-a`
- **WHEN** `agent-b`, which is also eligible for the profile, requests its SNMP targets
- **THEN** `agent-b` does not receive the device

#### Scenario: Agent polls targets of several profiles
- **GIVEN** devices resolving to two different SNMP profiles are both placed on `agent-a`
- **WHEN** `agent-a` requests its SNMP targets
- **THEN** it receives both devices, each with its own profile's OID set, interval, timeout and retries

## ADDED Requirements

### Requirement: Each device resolves to exactly one SNMP profile
The system SHALL resolve every device to exactly one SNMP profile: the highest-priority enabled targeting profile whose query selects it, or else the enabled default profile. The profile chosen for an agent's own host device SHALL NOT decide what that agent polls.

#### Scenario: Targeting profile wins over default
- **GIVEN** a targeting profile with priority 10 selecting `tags.role:core`
- **AND** an enabled default profile with `target_query: "in:devices"`
- **WHEN** placement resolves a device tagged `role: core`
- **THEN** the device is a target of the targeting profile only

#### Scenario: Agent host device does not select a profile
- **GIVEN** an agent whose own host device matches a targeting profile
- **WHEN** devices that match only the default profile are placed on that agent
- **THEN** the agent polls them with the default profile's OIDs

### Requirement: SNMP profile placement mode and redundancy
Each SNMP profile SHALL carry a `placement_mode` of `distribute` or `replicate`, and a `redundancy` of at least 1. A `distribute` profile SHALL place each target on `redundancy` eligible agents. The desired owners of a `replicate` profile's target SHALL be every currently eligible pinned agent, and an owner is added when a pinned agent becomes eligible later. For both modes, placement stays within each agent's effective capacity: a target with fewer owners than desired is `under_replicated`, and one with none is `uncovered`. A `replicate` profile SHALL be allowed only when the profile is pinned to a non-empty agent set.
Pinning (`agent_ids`) restricts which agents are eligible. Pinning SHALL NOT, by itself, make every pinned agent poll every target.

#### Scenario: Pinned distribute profile divides targets
- **GIVEN** a `distribute` profile with redundancy 1, pinned to three agents, selecting 3,000 devices
- **WHEN** placement runs with all three agents below capacity
- **THEN** every device is placed on exactly one of the three agents

#### Scenario: Replicate requires pinning
- **GIVEN** an unpinned SNMP profile
- **WHEN** an operator saves it with `placement_mode: replicate`
- **THEN** the save is refused with a message that `replicate` requires a pinned agent set

### Requirement: SNMP target ceiling per agent
The system SHALL bound the SNMP targets placed on one agent, summed across all profiles, by `snmp_max_targets` resolved agent, then partition, then global `edge_pipeline_settings`, then the code default. The code default SHALL be derived from the measured per-agent poller capacity recorded in this change's design. Agents served through legacy monolithic delivery SHALL use a separate, lower code default for the same setting.
The ceiling is a placement input. A profile SHALL NOT be refused at save or compile time because it selects more targets than one agent's ceiling.

#### Scenario: Large profile is spread rather than refused
- **GIVEN** a profile selecting 50,000 devices in one partition
- **AND** six eligible agents, each with a ceiling of 10,000
- **WHEN** the operator saves the profile
- **THEN** the save succeeds
- **AND** placement spreads the 50,000 devices across the agents without exceeding any agent's ceiling

#### Scenario: Partition cannot cover the profile
- **GIVEN** the same profile with only four eligible agents, each with a ceiling of 10,000
- **WHEN** placement runs
- **THEN** 40,000 devices are placed and 10,000 are marked `uncovered` with reason `fleet_capacity_exhausted`
- **AND** the profile's settings row shows the uncovered count and the partition it belongs to

### Requirement: SNMP target deltas apply without restarting the poller
The agent SHALL apply an SNMP target delta by starting collectors for added targets, replacing collectors whose compiled target changed, and stopping collectors for removed targets. Collectors for unchanged targets SHALL keep polling with their counter-delta state.

#### Scenario: One device added
- **GIVEN** an agent polling 10,000 SNMP targets
- **WHEN** it applies a delta that adds one target
- **THEN** one collector starts
- **AND** the other 10,000 collectors are not stopped and their next counter samples still produce deltas

### Requirement: Agent SNMP poller resources scale with load, not target count
The agent SHALL hold per-series sample buffers sized to the samples expected between drains rather than a fixed preallocated capacity. It SHALL bound concurrent SNMP requests by a worker limit, so the sockets held follow in-flight requests rather than the number of targets. It SHALL spread poll start times across each interval.

#### Scenario: Idle series costs no preallocated buffer
- **GIVEN** a target with 77 polled series and a 60 second interval drained every 30 seconds
- **WHEN** the collector is created
- **THEN** no series preallocates more samples than one drain period holds

#### Scenario: Targets beyond the ephemeral port range
- **GIVEN** an agent placed more targets than its host's ephemeral UDP port range
- **WHEN** the SNMP service starts
- **THEN** every target starts polling
- **AND** the number of open SNMP sockets stays at or below the worker limit

### Requirement: Agent reports measured SNMP poller capacity
The agent SHALL report, for each reporting window: the targets it holds, the polls due, the polls that completed within their interval, the data points produced, the SNMP requests sent, and the poll scheduling lag. Core SHALL derive the agent's measured capacity, in data points per second, from those reports. The on-time threshold and the consecutive-window count are configured. Before comparing, core SHALL recompute the agent's placed cost with the actual series counts from the same report. While the share of polls completed within their interval stays at or above the on-time threshold, measured capacity SHALL only rise, to the highest sustained point rate seen. When that share stays below the threshold for the configured number of consecutive windows, measured capacity SHALL be set to the achieved on-time point rate, which is below that recomputed placed cost.

#### Scenario: Agent falls behind
- **GIVEN** an on-time threshold of 99 percent and a window count of three
- **AND** an agent completing 80 percent of due polls within their interval for three consecutive windows
- **AND** its targets report more walk rows than their template estimate
- **WHEN** core computes its measured capacity
- **THEN** the measured capacity is below its placed cost recomputed from the reported walk rows
- **AND** the next placement pass moves load off the agent with reason `over_capacity`, only onto agents that stay within their effective capacity

#### Scenario: Agent falls behind with no room elsewhere
- **GIVEN** an agent whose measured capacity has fallen below its placed cost
- **AND** no other eligible agent has room for its targets
- **WHEN** the placement pass runs
- **THEN** its targets stay placed on it
- **AND** the agent is reported over capacity

### Requirement: SNMP targets move away from an owner that cannot reach them
The system SHALL move an SNMP target to another eligible agent when its owner reports the target unreachable for the configured number of consecutive polls, and SHALL exclude that agent for the target for a backoff period. After the configured number of agents, counting the original owner, have failed the target, the system SHALL keep the target on the owner that reached the candidate limit and report it unreachable rather than continue moving it.

#### Scenario: Another agent can reach the device
- **GIVEN** a device placed on `agent-a` that fails the configured number of consecutive polls
- **AND** an eligible `agent-b` that has not failed it
- **WHEN** the placement pass runs
- **THEN** the device moves to `agent-b` with reason `unreachable_on_owner`

#### Scenario: Device is down for everyone
- **GIVEN** a device that failed on each of the configured number of candidates the rule allows
- **WHEN** the placement pass runs
- **THEN** the device stays placed and is reported unreachable
- **AND** it is not moved again until an agent reports a successful poll or the backoff expires
