## ADDED Requirements

### Requirement: Agent disconnections are promoted and alert
A seeded event rule SHALL promote every agent health transition into a `health.agent.state_change` event, and a seeded managed stateful rule SHALL open one critical incident per agent when it becomes `disconnected` and SHALL recover it when that agent becomes `connected`, `superseded` or `unavailable`. Every agent state-machine transition SHALL be recorded as a health event, including transitions applied by an atomic update, and a check-in that returns a disconnected agent to service SHALL record the transition to `connected` with the agent's previous state.

#### Scenario: A lost connection is recorded
- **GIVEN** a connected agent whose last check-in is older than the stale-agent timeout
- **WHEN** the state monitor marks it `disconnected`
- **THEN** a health event from `connected` to `disconnected` SHALL be recorded for that agent

#### Scenario: A silent agent pages
- **GIVEN** an agent that stopped checking in and was marked `disconnected`
- **WHEN** the health log is promoted
- **THEN** a critical alert opens for that agent id

#### Scenario: Reconnection resolves the incident
- **GIVEN** an open incident for a disconnected agent
- **WHEN** the agent checks in again
- **THEN** a `connected` transition from `disconnected` is recorded
- **AND** the incident recovers and no new incident opens

#### Scenario: Agents are independent incidents
- **GIVEN** two agents disconnected at once
- **WHEN** the rule evaluates both transitions
- **THEN** two incidents exist, one per agent id

#### Scenario: A retired or superseded agent does not keep paging
- **GIVEN** an open incident for a disconnected agent
- **WHEN** that agent is superseded or retired as unavailable
- **THEN** the incident recovers
