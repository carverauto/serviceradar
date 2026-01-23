## ADDED Requirements

### Requirement: Combined Multi-Series Traffic Charts
The system SHALL support rendering multiple traffic metrics (inbound and outbound) on a single chart for easier comparison.

#### Scenario: Combined inbound/outbound traffic chart
- **WHEN** an operator enables "combined view" for interface traffic metrics
- **THEN** both ifInOctets and ifOutOctets are rendered on the same chart
- **AND** each series has a distinct color with legend labels

#### Scenario: Y-axis scaling to interface speed
- **WHEN** a combined traffic chart is rendered and interface speed is known
- **THEN** the Y-axis scales to the interface speed (bytes/second)
- **AND** the chart shows 0-100% of capacity as the vertical range

#### Scenario: Separate charts remain available
- **WHEN** an operator disables "combined view"
- **THEN** inbound and outbound metrics are shown as separate charts (default behavior)

### Requirement: Percentage Threshold Configuration UI
The system SHALL provide UI controls for configuring percentage-based utilization thresholds.

#### Scenario: Threshold type selection
- **WHEN** an operator configures an interface metric threshold
- **THEN** they can choose between "absolute" (bytes/sec) and "percentage" (% of capacity) types

#### Scenario: Percentage slider input
- **WHEN** percentage threshold type is selected
- **THEN** a slider or numeric input allows setting 0-100% threshold value
- **AND** the calculated bytes/second equivalent is displayed for reference

### Requirement: Utilization Badge Display
The system SHALL display interface utilization percentage as a visual badge on traffic charts.

#### Scenario: Utilization badge color coding
- **WHEN** interface traffic metrics are displayed
- **THEN** a utilization badge shows the current percentage of interface capacity
- **AND** badge color indicates severity: green (<50%), blue (50-74%), warning (75-89%), error (>=90%)

#### Scenario: Interface speed limit shown in chart footer
- **WHEN** interface speed is known
- **THEN** the chart footer displays the interface speed limit (e.g., "limit: 125 MB/s")
