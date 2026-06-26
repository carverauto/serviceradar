## ADDED Requirements

### Requirement: Device metric charts show anomaly finding overlays

The device detail UI SHALL project device-scoped anomaly findings onto matching sysmon metric charts when the finding includes enough time and metric context to do so.

#### Scenario: Anomaly marker appears on matching CPU chart
- **GIVEN** a device has a CPU anomaly finding with a timestamp and CPU metric identity
- **WHEN** an operator views that device's metric charts
- **THEN** the CPU chart SHALL show an anomaly marker at the finding time
- **AND** the marker tooltip SHALL include the finding title and effective severity or disposition when available

#### Scenario: Anomaly window appears when the finding includes a window
- **GIVEN** a device has an anomaly finding with `window_started_at` and `window_ended_at`
- **WHEN** the matching metric chart renders
- **THEN** the chart SHALL show a bounded anomaly window across that time range
- **AND** the chart SHALL still preserve normal point hover behavior

#### Scenario: Sparse finding remains listed without misleading chart overlay
- **GIVEN** a device has an anomaly finding without usable chart time or metric identity
- **WHEN** the device detail page renders
- **THEN** the finding SHALL remain visible in the anomaly findings panel
- **AND** the metric charts SHALL NOT invent an overlay for that finding

### Requirement: Device metric charts show capacity forecast overlays

The device detail UI SHALL project device-scoped capacity forecast rows onto matching capacity-relevant metric charts when forecast fields are unit-compatible with the chart.

#### Scenario: Disk forecast shows threshold and runway
- **GIVEN** a device has a disk capacity forecast with current value, projected value, and exhaustion threshold
- **WHEN** the disk metric chart renders
- **THEN** the chart SHALL show the exhaustion threshold as a reference line
- **AND** it SHALL show projected runway context for the forecast when it fits the visible chart domain

#### Scenario: Out-of-window exhaustion does not distort the chart
- **GIVEN** a capacity forecast projects exhaustion outside the current chart time window
- **WHEN** the metric chart renders
- **THEN** the chart SHALL NOT stretch or compress the metric time axis solely to include that future timestamp
- **AND** the forecast details SHALL remain available in the capacity panel

#### Scenario: Confidence bounds render only when compatible
- **GIVEN** a capacity forecast includes lower and upper bounds in the same unit as the chart
- **WHEN** the matching metric chart renders
- **THEN** the chart MAY show a confidence band
- **AND** if bounds are missing or unit-incompatible, the chart SHALL omit the band without error
