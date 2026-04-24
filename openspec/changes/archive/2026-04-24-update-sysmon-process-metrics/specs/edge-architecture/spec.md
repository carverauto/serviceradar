## ADDED Requirements
### Requirement: Sysmon process metrics persistence
The system SHALL persist sysmon process metrics into the `process_metrics` hypertable when `collect_processes` is enabled.

#### Scenario: Process metrics ingested from sysmon payload
- **GIVEN** an agent sends a `sysmon-metrics` status payload containing process metrics
- **WHEN** the gateway forwards the payload to core
- **THEN** core SHALL insert rows into `process_metrics`
- **AND** each row includes device identifier, timestamp, PID, process name, CPU%, and memory%

#### Scenario: Process metrics disabled
- **GIVEN** an agent configuration with `collect_processes: false`
- **WHEN** sysmon metrics are ingested
- **THEN** no process metrics rows are inserted
