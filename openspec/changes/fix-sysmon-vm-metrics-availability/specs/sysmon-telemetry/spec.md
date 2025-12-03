## ADDED Requirements
### Requirement: Sysmon metrics availability for enrolled devices
The system SHALL deliver sysmon CPU/memory/time-series metrics from enrolled sysmon-vm collectors to the device's telemetry endpoints within one polling interval when the collector is healthy.

#### Scenario: Connected sysmon-vm metrics are queryable
- **WHEN** a sysmon-vm collector is enrolled via mTLS, connected to poller/core, and producing host metrics for its target device
- **THEN** the system SHALL persist those metrics to CNPG and make them available via `/api/sysmon` (and UI charts) for that device within one polling interval.

#### Scenario: Metrics stay attributed to the target device
- **WHEN** the sysmon-vm restarts or reconnects with the same target device identity
- **THEN** sysmon metrics remain keyed to the target device (not the collector host) and continue to display without manual reassociation.

### Requirement: Sysmon pipeline degradation visibility
The system SHALL detect and surface when sysmon metrics stop arriving even though the sysmon-vm collector remains registered/connected.

#### Scenario: Alert on stalled sysmon metrics stream
- **WHEN** a sysmon-vm collector stays connected but no sysmon metric batches are stored for more than five polling intervals
- **THEN** the system SHALL emit an actionable signal (e.g., event/log/health marker) tied to the collector/device and mark sysmon metrics as unavailable instead of serving empty graphs.

#### Scenario: Query or write errors surface diagnostics
- **WHEN** sysmon metrics cannot be written to or read from CNPG due to validation/schema/query errors
- **THEN** the system SHALL record the error context and expose it for troubleshooting, avoiding silent empty responses.
