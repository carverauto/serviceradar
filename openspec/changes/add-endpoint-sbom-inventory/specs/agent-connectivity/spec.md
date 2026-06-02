## ADDED Requirements

### Requirement: Endpoint Inventory Commands Use Bounded Control-Stream Dispatch
The agent command bus SHALL support typed endpoint inventory commands over the existing agent-initiated control stream without requiring inbound connectivity to agents.

#### Scenario: Cache query command dispatched to connected capable agent
- **GIVEN** an agent is connected on the control stream and advertises endpoint inventory capability
- **WHEN** the control plane dispatches an endpoint inventory cache-query command
- **THEN** the gateway SHALL deliver the typed command over the control stream
- **AND** the agent SHALL return a bounded command result with freshness metadata

#### Scenario: Force-fresh authorization enforced before dispatch
- **GIVEN** an operator requests a force-fresh endpoint inventory scan
- **WHEN** the control plane evaluates the request
- **THEN** it SHALL require the requesting actor to hold `endpoint_inventory.force_fresh_scan`
- **AND** unauthorized requests SHALL be rejected before any command is sent to the agent

#### Scenario: Inventory command capacity is enforced
- **GIVEN** an endpoint inventory command is submitted
- **WHEN** dispatch capacity or per-partition force-fresh rate limits are exhausted
- **THEN** the command SHALL be rejected or deferred with a bounded error
- **AND** the command bus SHALL NOT default unknown inventory command types to accepted

#### Scenario: Cohort results use per-command topic
- **GIVEN** a cohort endpoint inventory query has query ID `Q`
- **WHEN** agents return results
- **THEN** results SHALL be published only to the per-command result topic for `Q`
- **AND** subscribers for other commands SHALL NOT receive those package-match results

#### Scenario: Command result payload is capped
- **GIVEN** an endpoint inventory command result would exceed the configured payload byte cap
- **WHEN** the result is serialized
- **THEN** the result SHALL be truncated or rejected with a bounded error
- **AND** SBOM artifact bytes SHALL NOT be sent as a command result
