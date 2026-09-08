## MODIFIED Requirements
### Requirement: Device Targeting DSL

The system SHALL provide SRQL-based device targeting for sweep groups using device attributes.

#### Scenario: Target by tag key
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies SRQL `tags:critical`
- **THEN** the sweep SHALL target all devices with the "critical" tag key

#### Scenario: Target by tag key/value
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies SRQL `tags.env:prod`
- **THEN** the sweep SHALL target devices with `tags.env` set to "prod"

#### Scenario: Target by IP range
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies SRQL `ip:10.0.0.0/8`
- **THEN** the sweep SHALL target devices with IPs in the 10.x.x.x range

#### Scenario: Target by static targets
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user provides static targets `["10.0.0.10", "10.0.2.0/24"]`
- **THEN** the sweep SHALL always include those targets
- **AND** merge them with SRQL query results

#### Scenario: Combined targeting criteria
- **GIVEN** a sweep group with multiple targeting criteria
- **WHEN** the SRQL query is `tags:critical tags.env:prod ip:10.0.0.0/8 partition:datacenter-1`
- **THEN** the criteria SHALL be combined with implicit AND logic
- **AND** only devices matching the configured query SHALL be targeted

---

### Requirement: Sweep Job Configuration

The system SHALL provide Ash resources for defining sweep jobs that target specific devices or device selections.

#### Scenario: Create sweep job by device query
- **GIVEN** an admin in Settings > Networks
- **WHEN** they create a sweep job with an SRQL device query
- **THEN** they SHALL be able to filter by:
  - Tags (keys or key/value pairs)
  - IPs/CIDRs/ranges
  - Partition
- **AND** the SRQL query SHALL be saved and re-evaluated on each sweep

#### Scenario: Assign sweep job to partition
- **GIVEN** a sweep job configuration
- **WHEN** the user selects a partition
- **THEN** the job SHALL be assigned to that partition
- **AND** any agent in that partition MAY execute the job if no specific agent is selected

#### Scenario: Assign sweep job to specific agent
- **GIVEN** a sweep job configuration
- **WHEN** the user selects a specific agent
- **THEN** only that agent SHALL execute the job
- **AND** the agent SHALL receive the config via its next poll
