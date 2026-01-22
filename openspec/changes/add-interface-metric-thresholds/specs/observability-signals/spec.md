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

### Requirement: Unified event rules with source types
The system SHALL store event creation rules in a unified resource that supports multiple source types (at least logs and metrics).

#### Scenario: Log promotion rule migration
- **GIVEN** existing log promotion rules are configured
- **WHEN** the event rule resource is introduced
- **THEN** the system SHALL migrate log promotion rules into event rules with `source_type = log`
- **AND** the log promotion pipeline SHALL evaluate the migrated event rules

#### Scenario: Metric event rule creation
- **GIVEN** a user configures event settings for an interface metric
- **WHEN** the settings are saved
- **THEN** the system SHALL create or update an event rule with `source_type = metric`
- **AND** events emitted for that metric SHALL include metadata sufficient to match alert rules

#### Scenario: Metric alert rule creation
- **GIVEN** per-metric alert settings are enabled
- **WHEN** the settings are saved
- **THEN** the system SHALL create or update a stateful alert rule targeting the metric events
