## ADDED Requirements

### Requirement: Native add-on fleet state records evidence and runtime expectation
The native add-on fleet read model SHALL retain, for each (agent, add-on), the desired
assignment source, observed status and timestamp, agent availability, observation
freshness, package delivery/supervision model, management origin, expected activity,
active rollout state, and stable diagnostic reason codes. Freshness SHALL be derived
from the agent heartbeat/status cadence with a configurable floor.

#### Scenario: Disconnected agent preserves stale evidence
- **GIVEN** an agent with a managed add-on assignment and a previously healthy status
- **WHEN** the agent disconnects and the observation exceeds its freshness window
- **THEN** the read model SHALL preserve the last observed status and timestamp
- **AND** SHALL mark the evidence unavailable/stale rather than claim the add-on is currently stopped

#### Scenario: Runtime model determines expected activity
- **GIVEN** an assigned `ephemeral-helper` that is verified, staged, and registered
- **AND** no invocation is active
- **WHEN** fleet state is classified
- **THEN** expected activity SHALL be inactive
- **AND** continuous runtime activity SHALL NOT be required for readiness

#### Scenario: Built-in runtime records observed-only origin
- **GIVEN** an agent reports a healthy built-in add-on runtime without a managed assignment
- **WHEN** the status is ingested
- **THEN** the row SHALL record an observed-only management origin
- **AND** absence of an assignment SHALL NOT by itself be recorded as a failure

### Requirement: Control-session evidence tolerates registry convergence
Control-plane nodes that do not host the Horde registry SHALL query all connected
trusted registry-bearing core and agent-gateway nodes for control-session evidence
and merge the results. A lagging replica SHALL NOT cause a live authenticated agent
to appear partitionless when another connected registry member has the session.

#### Scenario: First core replica has not observed a new session
- **GIVEN** web-ng does not host the registry mesh
- **AND** one connected core replica has not yet converged a newly authenticated agent session
- **AND** a connected gateway or another core replica has the session evidence
- **WHEN** an assignment resolves the agent's authenticated partition
- **THEN** the control plane SHALL resolve the partition from the available trusted evidence
- **AND** the operator SHALL NOT need to close and reopen the assignment modal

### Requirement: Native add-on fleet health categories are mutually exclusive
Each native add-on fleet row SHALL have exactly one summary category:
`action_required`, `updating`, `unavailable`, `expected_inactive`, `observed_only`, or
`healthy`. `action_required` SHALL be limited to known desired-state errors, explicit
fresh runtime/delivery/config failures, or managed persistent state that remains
unconverged beyond its rollout/convergence deadline.

#### Scenario: Fresh unhealthy managed runtime needs attention
- **GIVEN** a connected agent with a managed persistent add-on at its assigned version
- **AND** a fresh status reports the add-on unhealthy with a degradation reason
- **WHEN** fleet state is classified
- **THEN** the row SHALL be `action_required`
- **AND** SHALL expose the runtime failure reason and evidence timestamp

#### Scenario: Offline assignment is unavailable, not stopped
- **GIVEN** an enabled assignment whose agent is disconnected and whose status is stale or absent
- **WHEN** fleet state is classified
- **THEN** the row SHALL be `unavailable`
- **AND** SHALL NOT be counted as an active runtime failure solely because it is not reporting

#### Scenario: Rollout convergence is not premature failure
- **GIVEN** a target with an active rollout or recent desired-state change
- **AND** no explicit failure has occurred
- **WHEN** the target remains inside its convergence deadline
- **THEN** the row SHALL be `updating`
- **AND** SHALL NOT be counted as `action_required`

#### Scenario: Dormant helper is expected inactive
- **GIVEN** an assigned ephemeral helper that is staged and ready with no active invocation
- **WHEN** fleet state is classified
- **THEN** the row SHALL be `expected_inactive`
- **AND** SHALL NOT be counted as `action_required` or as a continuously running deployment

#### Scenario: Healthy observed-only runtime is informational
- **GIVEN** a fresh healthy built-in runtime status with no managed assignment
- **WHEN** fleet state is classified
- **THEN** the row SHALL be `observed_only`
- **AND** SHALL NOT be counted as `action_required`

#### Scenario: Explicit observed-only failure remains actionable
- **GIVEN** an observed-only runtime that reports a fresh explicit unhealthy state
- **WHEN** fleet state is classified
- **THEN** the row SHALL be `action_required`
- **AND** the reason SHALL state that the failing runtime is not managed by an assignment

#### Scenario: Incompatible desired assignment remains actionable
- **GIVEN** a desired add-on assignment known to be incompatible with the target platform or agent contract
- **WHEN** fleet state is classified, whether or not the agent is connected
- **THEN** the row SHALL be `action_required`
- **AND** the reason SHALL identify the compatibility violation rather than a runtime stop
