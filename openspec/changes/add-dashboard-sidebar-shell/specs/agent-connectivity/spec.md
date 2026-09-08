## ADDED Requirements

### Requirement: Agent-Mediated Collector Liveness
ServiceRadar SHALL support collector liveness observations through agents that can reach those collectors, rather than requiring core or web-ng to poll collector gRPC endpoints directly. Collector liveness observations SHALL be transported over authenticated mTLS/NATS paths and materialized into queryable status for dashboards and operations views.

#### Scenario: Agent observes reachable collector
- **GIVEN** an agent is configured to monitor a collector reachable from its network location
- **WHEN** the agent performs the collector liveness check
- **THEN** it records the collector type, collector identity, agent identity, observed status, observed timestamp, and bounded diagnostic detail
- **AND** it publishes the observation over the existing authenticated NATS path

#### Scenario: Core materializes collector status
- **GIVEN** collector liveness observations are published through NATS JetStream or KV
- **WHEN** core consumes or reads the latest observations
- **THEN** it materializes current collector status into a queryable model for web-ng
- **AND** stale observations are distinguishable from healthy, unhealthy, and never-observed collectors

#### Scenario: Collector endpoint is not control-plane routable
- **GIVEN** a collector endpoint is only reachable from an edge network
- **WHEN** the dashboard needs collector status
- **THEN** web-ng uses materialized agent/NATS collector liveness state
- **AND** it does not attempt direct control-plane polling of the collector endpoint
