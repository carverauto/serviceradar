## ADDED Requirements

### Requirement: Per-agent Add-on State In The Registry
The agent registry SHALL track and expose, per agent, which add-ons (feature sets)
are assigned, installed, and active, including each add-on's version and health, so
operators can query and reconcile feature-set deployment across the fleet.

#### Scenario: Registry reflects active add-ons
- **GIVEN** an agent reporting active and unhealthy add-ons in its status
- **WHEN** the registry updates the agent's runtime metadata
- **THEN** the registry SHALL record the agent's active add-ons with versions
- **AND** SHALL record unhealthy add-ons with a bounded reason

#### Scenario: Operators can query feature-set deployment
- **GIVEN** add-on state recorded per agent
- **WHEN** an operator queries which agents run a given add-on
- **THEN** the registry read model SHALL return the agents with that add-on assigned and its observed state per agent

#### Scenario: Drift between assigned and observed is queryable
- **GIVEN** an add-on assigned to an agent that does not report it active
- **WHEN** the registry reconciles assigned versus observed add-on state
- **THEN** it SHALL expose the agent as having add-on drift
