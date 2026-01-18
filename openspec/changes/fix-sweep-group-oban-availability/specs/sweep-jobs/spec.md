## MODIFIED Requirements
### Requirement: Sweep Group Management

The system SHALL provide Ash resources and UI for creating sweep groups that combine scheduling, targeting, and scan configuration. Sweep group creation and updates MUST succeed even if the background scheduler is unavailable, and the user MUST be informed that scheduling is deferred until the scheduler is healthy.

#### Scenario: Create sweep group with custom schedule
- **GIVEN** an admin in Settings > Networks
- **WHEN** they create a new sweep group named "Network Infrastructure - Every 2 Hours"
- **AND** configure schedule to run every 2 hours
- **AND** configure ports [80, 443, 8080] with modes ["tcp", "icmp"]
- **THEN** the sweep group SHALL be saved with its unique schedule
- **AND** be available for targeting device selections

#### Scenario: Create sweep group when scheduler is unavailable
- **GIVEN** an admin in Settings > Networks
- **AND** the Oban scheduler is not running in the core process
- **WHEN** they create or update a sweep group
- **THEN** the sweep group SHALL be saved successfully
- **AND** the UI SHALL display a warning that scheduling is deferred
- **AND** the sweep group SHALL be scheduled once the scheduler is available

#### Scenario: Sweep group with tag-based targeting
- **GIVEN** a sweep group configuration form
- **WHEN** the user configures targeting with:
  - tags has_any ["critical", "prod"]
  - tags.env = "prod"
- **THEN** the filter SHALL be saved as part of the sweep group
- **AND** the query SHALL be evaluated at sweep execution time

#### Scenario: Multiple sweep groups with different schedules
- **GIVEN** two sweep groups:
  - "Critical Servers - Every 5 Minutes" targeting servers
  - "Network Devices - Every 2 Hours" targeting routers/switches
- **WHEN** sweep schedules are evaluated
- **THEN** each group SHALL run on its own schedule independently
- **AND** device overlap SHALL be handled gracefully (no duplicate scans within interval)

#### Scenario: Sweep group combines multiple scan configurations
- **GIVEN** a sweep group configuration
- **WHEN** the user adds multiple scan specifications:
  - TCP ports [80, 443] with 30s timeout
  - ICMP with high-performance mode
- **THEN** both scan types SHALL be executed as part of the group sweep
- **AND** results SHALL be aggregated per device
