## ADDED Requirements

### Requirement: Service availability dashboards use dashboard SDK packages
New first-party service availability dashboards SHALL be built as dashboard SDK packages rather than bespoke one-off dashboard surfaces, and SHALL be available by default in fresh ServiceRadar deployments.

#### Scenario: NOC dashboard package queries SRQL
- **GIVEN** the service monitoring model is enabled
- **WHEN** the first-party service availability dashboard is built
- **THEN** it SHALL be packaged through the dashboard SDK workflow
- **AND** it SHALL query SRQL for services, check instances, alerts, and availability rollups

#### Scenario: Fresh deployment includes the NOC dashboard
- **GIVEN** ServiceRadar starts with dashboard package storage tables available
- **WHEN** the web application bootstraps first-party dashboards
- **THEN** the Service Availability NOC package SHALL be imported from bundled product artifacts
- **AND** it SHALL be enabled at `/dashboards/service-availability-noc` without requiring an administrator import or enable action

### Requirement: Dashboard filters align with service monitoring tags and groups
Service availability dashboards SHALL expose filters for service tags, service groups, plugin capability, device tags, and agent/vantage point.

#### Scenario: Operator filters dashboard by device tag
- **GIVEN** services are associated with devices tagged `site:denver`
- **WHEN** a NOC operator filters the dashboard to `site:denver`
- **THEN** visuals SHALL update from SRQL results for services associated with those devices
- **AND** standalone services SHALL remain available through service tag or service group filters

### Requirement: SLO dashboards expose compliance and error-budget health
First-party NOC dashboards SHALL show SLO compliance, error-budget remaining, burn rate, and projected time to exhaustion using dashboard SDK packages.

#### Scenario: NOC operator reviews SLO burn rate
- **GIVEN** one SLO is currently compliant but burning budget too quickly
- **WHEN** the NOC dashboard loads
- **THEN** it SHALL show current compliance, budget remaining, short-window burn rate, long-window burn rate, and projected exhaustion time
- **AND** the visual state SHALL distinguish current service outage from fast budget burn

#### Scenario: Filter dashboard by SLO owner
- **GIVEN** SLOs have owner/team metadata
- **WHEN** an operator filters the dashboard to team `payments`
- **THEN** the dashboard SHALL show only services, checks, SLOs, and alerts associated with that team
