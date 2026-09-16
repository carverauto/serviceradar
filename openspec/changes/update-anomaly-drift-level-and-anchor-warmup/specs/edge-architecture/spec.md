## ADDED Requirements

### Requirement: Native add-on exits promptly on the host shutdown signal
A native add-on built on the Rust add-on SDK SHALL, on SIGINT or SIGTERM, call
the add-on's shutdown hook, ask its RPC server to drain, and terminate within a
bounded grace period even while the host holds long-lived streams open. The
process SHALL NOT outlive its RPC server.

#### Scenario: SIGTERM with an open telemetry stream
- **GIVEN** the host holds the add-on's telemetry stream open
- **WHEN** the add-on receives SIGTERM
- **THEN** it SHALL run its shutdown hook (the anomaly add-on flushes its checkpoint)
- **AND** the process SHALL exit within the grace period so the supervisor can restart it
