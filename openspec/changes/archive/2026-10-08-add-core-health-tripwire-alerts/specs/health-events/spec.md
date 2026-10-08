## ADDED Requirements
### Requirement: Core health transitions are promoted and alert
The internal health log SHALL carry a structured `health` attribute block (entity type, entity id, old state, new state, reason). A seeded event rule SHALL promote every core health transition into a `health.core.state_change` event, and a seeded managed stateful rule SHALL open one critical incident per core check when it becomes unhealthy and SHALL recover it when the check becomes healthy again.

#### Scenario: A dead baseline producer pages
- **GIVEN** the seasonal-baseline freshness check records unhealthy
- **WHEN** the health log is promoted
- **THEN** a critical alert opens for the check id `seasonal-baseline-freshness`

#### Scenario: Recovery resolves the incident
- **GIVEN** an open incident for a core check
- **WHEN** the check records healthy
- **THEN** the incident recovers and no new incident opens

#### Scenario: Checks are independent incidents
- **GIVEN** two core checks unhealthy at once
- **WHEN** the rule evaluates both transitions
- **THEN** two incidents exist, one per check id
