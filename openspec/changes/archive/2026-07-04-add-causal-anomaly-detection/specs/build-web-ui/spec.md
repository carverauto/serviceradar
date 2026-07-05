## ADDED Requirements

### Requirement: Capacity Forecast Visualization
The web UI SHALL provide a capacity-forecast visualization that shows a resource's historical utilization alongside its projected trend and projected exhaustion time, rendered through the authored-dashboards panel system (an extended line/area visual or a dedicated capacity-forecast visual type). Projections SHALL be presented as estimates with their confidence.

#### Scenario: Operator views a disk capacity forecast
- **WHEN** an operator opens a capacity-forecast panel for a disk resource with a stored projection
- **THEN** the UI SHALL render the historical series, the projected trend, and the projected exhaustion time
- **AND** SHALL indicate the projection's confidence

### Requirement: Anomaly Findings and At-Risk Surfacing
The web UI SHALL surface confirmed anomaly findings in the events view and SHALL provide a summary indicator of current anomaly / at-risk-capacity counts. Anomaly and capacity alerts SHALL appear in the existing alerts view via the standard alert pipeline.

#### Scenario: Anomaly finding visible to operator
- **WHEN** an anomaly finding has been raised for a device
- **THEN** it SHALL appear in the events view and SHALL be reflected in the anomaly/at-risk summary indicator

### Requirement: Consolidate Bespoke Capacity and Anomaly Placeholders
The web UI SHALL consolidate the previous bespoke NetFlow "Capacity Planning" section (instantaneous utilization, no projection) and the NetFlow "Anomaly Detection" feature-flag placeholder (no detector or visualization) into the capacity-forecast and anomaly surfaces defined by this capability.

#### Scenario: Bespoke placeholders replaced
- **WHEN** the capacity-forecast and anomaly surfaces are live
- **THEN** the bespoke NetFlow capacity-planning and anomaly-detection placeholders SHALL be removed or redirected to the consolidated surfaces
