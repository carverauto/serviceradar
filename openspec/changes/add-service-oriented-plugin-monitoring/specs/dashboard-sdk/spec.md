## ADDED Requirements

### Requirement: Service availability dashboards use dashboard SDK packages
New first-party service availability dashboards SHALL be built as dashboard SDK packages rather than bespoke one-off dashboard surfaces.

#### Scenario: NOC dashboard package queries SRQL
- **GIVEN** the service monitoring model is enabled
- **WHEN** the first-party service availability dashboard is built
- **THEN** it SHALL be packaged through the dashboard SDK workflow
- **AND** it SHALL query SRQL for services, check instances, alerts, and availability rollups

### Requirement: Dashboard filters align with service monitoring tags and groups
Service availability dashboards SHALL expose filters for service tags, service groups, plugin capability, device tags, and agent/vantage point.

#### Scenario: Operator filters dashboard by device tag
- **GIVEN** services are associated with devices tagged `site:denver`
- **WHEN** a NOC operator filters the dashboard to `site:denver`
- **THEN** visuals SHALL update from SRQL results for services associated with those devices
- **AND** standalone services SHALL remain available through service tag or service group filters

