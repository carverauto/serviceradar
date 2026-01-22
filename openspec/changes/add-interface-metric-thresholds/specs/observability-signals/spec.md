## ADDED Requirements
### Requirement: Per-metric threshold evaluation
The system SHALL evaluate interface metric thresholds per metric and emit events/alerts when configured thresholds are exceeded, without requiring a log-promotion step.

#### Scenario: Threshold violation emits alert
- **GIVEN** metric `ifInOctets` is enabled with a threshold
- **WHEN** the observed value exceeds the threshold for the configured duration
- **THEN** the system SHALL emit an event for that metric
- **AND** the event SHALL include metric name, value, comparison, severity, and event configuration metadata
- **AND** the system SHALL promote the event into an alert when the per-metric alert configuration is satisfied

#### Scenario: Disabled metric thresholds are ignored
- **GIVEN** a metric threshold is configured but the metric is disabled
- **WHEN** metric samples are processed
- **THEN** no threshold evaluation or alerting SHALL occur for that metric
