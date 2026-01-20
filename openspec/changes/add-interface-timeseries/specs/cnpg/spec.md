## ADDED Requirements

### Requirement: Interface observations hypertable with retention
The system SHALL store interface observations in a TimescaleDB hypertable with a 3-day retention policy.

#### Scenario: Hypertable exists
- **GIVEN** a fresh CNPG cluster with TimescaleDB enabled
- **WHEN** migrations run
- **THEN** the interface observations table is converted to a hypertable

#### Scenario: Retention policy enforces 3-day TTL
- **GIVEN** interface observations older than 3 days
- **WHEN** the retention policy runs
- **THEN** observations older than 3 days are removed
