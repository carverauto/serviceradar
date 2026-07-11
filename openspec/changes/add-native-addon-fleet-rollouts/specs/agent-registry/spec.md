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

### Requirement: Native add-on fleet queries page agents and batch their add-ons
The native add-on fleet read surface SHALL apply authorized search and health filters
on the server, select a deterministic bounded page of distinct agents, and batch-load
the matching add-on records for that agent page. It SHALL expose category counters for
the complete filtered result, independent of the current page, and SHALL NOT perform a
separate child query for each agent.

#### Scenario: Large fleet returns a bounded agent page
- **GIVEN** a fleet of 10,000 agents with multiple add-on records per agent
- **WHEN** an operator requests page size 50 with no row-level filter
- **THEN** the result SHALL contain at most 50 distinct parent agents and their add-on records
- **AND** the child records SHALL be loaded in a bounded batch rather than one query per parent agent
- **AND** the reported summary counters SHALL describe all 10,000 filtered agents and their add-on records rather than only the visible page

#### Scenario: Filters precede parent pagination
- **GIVEN** an add-on or health-category filter matching agents across multiple pages
- **WHEN** the first filtered page is requested
- **THEN** the server SHALL apply the row-level filter before selecting distinct parent agents
- **AND** each returned parent SHALL have at least one matching child record
- **AND** pagination metadata SHALL describe the filtered parent set

#### Scenario: Stable sort prevents page drift
- **GIVEN** multiple agents with equal values for the selected sort field
- **WHEN** an unchanged filtered result is traversed page by page
- **THEN** the server SHALL append a stable agent identifier as a tie-breaker
- **AND** no agent SHALL be duplicated or skipped between page boundaries

#### Scenario: Page size is bounded
- **GIVEN** a request with an unsupported or excessive page size
- **WHEN** the fleet query is evaluated
- **THEN** the server SHALL use a supported bounded page size
- **AND** SHALL NOT load the complete fleet into application memory
