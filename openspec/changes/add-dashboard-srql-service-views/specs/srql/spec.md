## ADDED Requirements

### Requirement: Dashboard service availability entity
The SRQL service SHALL support `in:service_availability` as a dashboard-facing service availability entity backed by ServiceRadar service status data.

#### Scenario: Latest availability rows query succeeds
- **GIVEN** service status rows exist for monitored services
- **WHEN** a client sends `in:service_availability sort:last_observed_at:desc limit:50`
- **THEN** SRQL SHALL return service availability rows
- **AND** each row SHALL include `uid`, `service_name`, `service_key`, `service_kind`, `status`, `available`, `summary`, and `last_observed_at`.

#### Scenario: Availability status filters are supported
- **GIVEN** service status rows contain available and unavailable services
- **WHEN** a client sends `in:service_availability status:(critical,unknown,warning) sort:last_observed_at:desc limit:50`
- **THEN** SRQL SHALL return only rows whose normalized dashboard status is critical, unknown, or warning.

#### Scenario: Availability rows respect time filters
- **GIVEN** service status rows span more than one hour
- **WHEN** a client sends `in:service_availability time:last_1h`
- **THEN** SRQL SHALL only consider service status rows observed inside the requested time window.

### Requirement: Dashboard monitored services entity
The SRQL service SHALL support `in:monitored_services` as a dashboard-facing service inventory entity backed by the latest known service identities.

#### Scenario: Monitored services inventory query succeeds
- **GIVEN** service status rows exist for multiple service identities
- **WHEN** a client sends `in:monitored_services sort:display_name:asc limit:200`
- **THEN** SRQL SHALL return one inventory row per service identity
- **AND** each row SHALL include `uid`, `display_name`, `service_key`, `service_kind`, `status`, `available`, and `last_observed_at`.

#### Scenario: Monitored services filters are supported
- **GIVEN** monitored services exist for multiple service kinds and agents
- **WHEN** a client sends `in:monitored_services service_kind:http agent_id:agent-a`
- **THEN** SRQL SHALL return only monitored HTTP services associated with `agent-a`.

#### Scenario: Monitored services exposes dashboard-safe route fields
- **GIVEN** a service identity can be parsed into protocol, host, and port
- **WHEN** a client queries `in:monitored_services`
- **THEN** SRQL SHALL populate `protocol`, `host`, and `port` when those values are known
- **AND** missing parsed values SHALL be returned as null rather than encoded raw JSON.

### Requirement: Dashboard SLO evaluations entity
The SRQL service SHALL support `in:slo_evaluations` as a dashboard-facing SLO pressure entity for service availability dashboards.

#### Scenario: SLO evaluation query succeeds
- **GIVEN** service availability data exists for the configured evaluation window
- **WHEN** a client sends `in:slo_evaluations severity:(warning,critical) sort:evaluated_at:desc limit:25`
- **THEN** SRQL SHALL return SLO evaluation rows
- **AND** each row SHALL include `uid`, `slo_key`, `slo_name`, `compliance_state`, `severity`, `budget_remaining_basis_points`, `burn_rate_short`, and `evaluated_at`.

#### Scenario: SLO error budget rollup succeeds
- **GIVEN** SLO evaluation rows exist
- **WHEN** a client sends `in:slo_evaluations rollup_stats:slo_error_budget`
- **THEN** SRQL SHALL return one rollup row with `total`, `critical`, `warning`, `error_budget_remaining`, `avg_budget_remaining_basis_points`, `max_burn_rate_short`, and `next_projected_exhaustion_at`.

#### Scenario: SLO evaluations are deterministic
- **GIVEN** the same service availability inputs and evaluation time
- **WHEN** SRQL executes the same `in:slo_evaluations` query twice
- **THEN** both responses SHALL produce the same SLO keys, severities, and budget values.

### Requirement: First-party dashboard frame compatibility
First-party dashboard package manifests SHALL only declare required SRQL frames that the current SRQL backend can parse and execute.

#### Scenario: Service Availability NOC frames execute
- **GIVEN** the Service Availability NOC package manifest is bundled with the app
- **WHEN** required package frames are validated
- **THEN** `availability_rollup`, `attention_services`, `service_inventory`, `slo_evaluations`, and `slo_budget_rollup` SHALL parse through SRQL successfully
- **AND** unsupported entities SHALL fail validation before the package is seeded as the system default.

#### Scenario: Dashboard package uses rich service entities
- **GIVEN** SRQL supports the dashboard service entities
- **WHEN** the Service Availability NOC dashboard is opened
- **THEN** its required frames SHALL use `in:service_availability`, `in:monitored_services`, and `in:slo_evaluations`
- **AND** the dashboard SHALL render data frames without substituting generic `in:services` fallback queries.
