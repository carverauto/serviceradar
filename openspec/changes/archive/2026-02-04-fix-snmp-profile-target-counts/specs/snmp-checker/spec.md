## ADDED Requirements
### Requirement: SNMP profile target query normalization
SNMP profiles SHALL treat an empty or missing `target_query` as `in:devices` when computing targets or reporting counts.

#### Scenario: Default profile uses device targeting
- **GIVEN** a default SNMP profile with no `target_query`
- **WHEN** the system computes targets or target counts
- **THEN** it evaluates the query as `in:devices`
- **AND** all matching devices are included

### Requirement: SNMP profile target counts use SRQL evaluation
The system SHALL compute SNMP profile target counts by executing the normalized SRQL `target_query` and returning a distinct device count.

#### Scenario: Device query count
- **GIVEN** a profile with `target_query: "in:devices tags.role:core"`
- **WHEN** the target count is evaluated
- **THEN** the count equals the number of devices that match the SRQL query

#### Scenario: Interface query reduces to distinct devices
- **GIVEN** a profile with `target_query: "in:interfaces type:ethernet"`
- **WHEN** the target count is evaluated
- **THEN** the count equals the number of distinct devices that have matching interfaces
