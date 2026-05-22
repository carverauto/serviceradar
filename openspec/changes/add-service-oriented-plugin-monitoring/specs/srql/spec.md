## ADDED Requirements

### Requirement: SRQL service monitoring entities
SRQL SHALL expose monitored services, check instances, service groups, and service check events as queryable entities.

#### Scenario: Query services by tag and kind
- **GIVEN** monitored services have tags and service kinds
- **WHEN** a client queries `in:services tags.team:noc service_kind:http`
- **THEN** SRQL SHALL return matching service records with latest availability fields

#### Scenario: Query check instances by plugin capability
- **GIVEN** check instances were created from plugin descriptors
- **WHEN** a client queries `in:service_checks capability:http.url.availability`
- **THEN** SRQL SHALL return check instances using that descriptor

### Requirement: SRQL service availability rollups support dashboard filters
SRQL SHALL support service availability rollups filtered by service group, tags, device association, plugin capability, and agent/vantage point.

#### Scenario: Dashboard queries availability for tagged NOC services
- **GIVEN** service availability rollups exist
- **WHEN** a dashboard queries `in:services tags.noc:true rollup_stats:availability`
- **THEN** SRQL SHALL return availability totals for the matching service set

#### Scenario: Dashboard filters by vantage point
- **GIVEN** the same service is checked from multiple agents
- **WHEN** a dashboard includes an agent/vantage filter
- **THEN** SRQL SHALL compute availability using only matching vantage-point observations

### Requirement: SRQL can join service and device context
SRQL SHALL expose associated device context for services that are linked to canonical devices while preserving standalone services.

#### Scenario: Query services for devices with inventory tag
- **GIVEN** services are associated with devices tagged `site:denver`
- **WHEN** a client queries services using the device tag filter
- **THEN** SRQL SHALL return services whose associated device matches that tag
- **AND** standalone services SHALL be excluded unless explicitly selected by service tags or groups

### Requirement: SRQL exposes SLI, SLO, compliance, and error-budget entities
SRQL SHALL expose SLI definitions, SLO objectives, SLO evaluations, compliance windows, and error-budget/burn-rate rollups as queryable entities.

#### Scenario: Query noncompliant SLOs by owner
- **GIVEN** SLO evaluation state exists for several service groups
- **WHEN** a client queries `in:slos owner:payments compliance:noncompliant`
- **THEN** SRQL SHALL return matching SLO records with current compliance, goal, period, budget remaining, and burn-rate fields

#### Scenario: Dashboard queries SLO error-budget rollup
- **GIVEN** SLO budget evaluations exist over a rolling 30-day period
- **WHEN** a dashboard queries `in:slo_evaluations rollup_stats:slo_error_budget`
- **THEN** SRQL SHALL return budget consumed, budget remaining, burn rate, and projected exhaustion fields for the selected SLO set

#### Scenario: Join SLOs to monitored services
- **GIVEN** an SLO targets a service group
- **WHEN** a client queries affected services for that SLO
- **THEN** SRQL SHALL return the monitored services and latest check state contributing to the current SLO evaluation
