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

