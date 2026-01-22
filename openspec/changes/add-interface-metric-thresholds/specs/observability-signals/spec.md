## ADDED Requirements
### Requirement: Per-metric threshold evaluation
The system SHALL evaluate interface metric thresholds per metric and emit events/alerts when configured thresholds are exceeded.

#### Scenario: Threshold violation emits alert
- **GIVEN** metric `ifInOctets` is enabled with a threshold
- **WHEN** the observed value exceeds the threshold for the configured duration
- **THEN** the system SHALL emit an event or alert for that metric
- **AND** the event SHALL include metric name, value, comparison, and severity metadata

#### Scenario: Disabled metric thresholds are ignored
- **GIVEN** a metric threshold is configured but the metric is disabled
- **WHEN** metric samples are processed
- **THEN** no threshold evaluation or alerting SHALL occur for that metric
