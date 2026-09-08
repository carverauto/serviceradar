## ADDED Requirements
### Requirement: Demo CNPG provides repeatable slow-query observability
The CNPG deployment in the `demo` namespace SHALL provide a repeatable slow-query observability path that supports detection, triage, and regression tracking of web-ng latency incidents.

#### Scenario: Operators can collect top slow-query evidence
- **GIVEN** operators investigate slow pages reported by web-ng
- **WHEN** they follow the documented demo triage workflow
- **THEN** they can retrieve top slow-query evidence from CNPG observability mechanisms
- **AND** they can correlate findings with application time windows.

### Requirement: Demo slow-query logging thresholds are configurable and documented
The CNPG deployment in `demo` SHALL enforce configurable query-duration logging thresholds and SHALL document tuning guidance to balance detection quality with log volume.

#### Scenario: Threshold tuning avoids excessive log noise
- **GIVEN** query-duration logging is enabled in demo
- **WHEN** operators adjust the configured threshold
- **THEN** slow-query events remain visible for triage
- **AND** log volume stays within acceptable operational limits.

### Requirement: Slow-query metrics are available for alerting in demo
The system SHALL expose low-cardinality slow-query metrics derived from existing telemetry/log data so operators can monitor latency trends and configure alerts in `demo`.

#### Scenario: Slow-query metrics are queryable
- **GIVEN** slow-query telemetry is flowing in demo
- **WHEN** operators query slow-query metrics
- **THEN** they can view latency distribution and slow-query rates over time
- **AND** metric labels remain low cardinality and suitable for alerting.
