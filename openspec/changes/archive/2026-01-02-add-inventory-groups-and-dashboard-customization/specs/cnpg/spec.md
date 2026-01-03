# cnpg Specification (Delta): Group health rollups

## ADDED Requirements

### Requirement: Rollups support group-level health widgets
The system SHALL provide Timescale-backed rollups that enable fast group-level health widgets (utilization and availability) without requiring per-group DDL at runtime.

#### Scenario: Group utilization rollup exists
- **GIVEN** the rollups migrations for group health have been applied
- **WHEN** an operator inspects `timescaledb_information.continuous_aggregates`
- **THEN** a rollup exists that can answer utilization queries grouped by `group_id` over time buckets.

#### Scenario: Rollups have refresh policies
- **GIVEN** group rollups exist
- **WHEN** an operator inspects `timescaledb_information.jobs`
- **THEN** refresh policies are configured for each rollup and run on a predictable cadence.

### Requirement: On-demand sweep results are retained with predictable TTL
The system SHALL persist on-demand sweep results in a way that supports a default 30-day retention (configurable within bounds) and provides predictable cleanup.

#### Scenario: Sweep results retention policy exists
- **GIVEN** on-demand sweep result storage has been deployed
- **WHEN** an operator inspects Timescale retention policies (or the documented cleanup job)
- **THEN** a cleanup mechanism exists that removes sweep results after the configured retention window.
