## ADDED Requirements

### Requirement: Percentage-Based Interface Thresholds
The system SHALL support threshold configuration as a percentage of interface capacity using `ifSpeed` as the baseline.

#### Scenario: Configure percentage threshold
- **WHEN** an operator sets an interface metric threshold with type "percentage" and value 50
- **THEN** the threshold is evaluated as 50% of the interface's speed in bytes/second

#### Scenario: Threshold evaluation with interface speed
- **WHEN** an interface has `ifSpeed` of 1 Gbps (1,000,000,000 bps) and threshold is 50%
- **THEN** the effective threshold is 62,500,000 bytes/second (1Gbps / 8 * 0.50)

#### Scenario: Missing interface speed gracefully handled
- **WHEN** an interface has no `ifSpeed` data and a percentage threshold is configured
- **THEN** the threshold evaluation is skipped with a warning log
- **AND** no event is generated for that metric

### Requirement: Interface Speed Storage
The system SHALL store interface speed (`ifSpeed`) from SNMP discovery for utilization calculations.

#### Scenario: Interface speed captured during discovery
- **WHEN** SNMP discovery retrieves interface data including `ifSpeed` OID
- **THEN** the speed value is stored with the interface record in bytes per second

#### Scenario: Interface speed returned in queries
- **WHEN** querying interfaces via SRQL
- **THEN** the `speed_bps` or `if_speed` field is included in the response

### Requirement: Utilization Event Metadata
The system SHALL include utilization percentage and threshold details in generated events.

#### Scenario: Event payload includes utilization context
- **WHEN** a metric threshold breach generates an event
- **THEN** the event payload includes `utilization_percent`, `threshold_percent`, and `if_speed_bps`
