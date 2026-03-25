## ADDED Requirements
### Requirement: Camera Analysis Worker Recent Probe History
The platform SHALL keep a bounded recent history of active probe outcomes for registered camera analysis workers.

#### Scenario: Successful probe is recorded
- **WHEN** the platform successfully probes a registered worker
- **THEN** it records a recent probe history item with success status and timestamp

#### Scenario: Failed probe is recorded
- **WHEN** the platform fails to probe a registered worker
- **THEN** it records a recent probe history item with failure status, timestamp, and normalized reason

#### Scenario: Probe history stays bounded
- **WHEN** probe outcomes exceed the configured recent-history capacity
- **THEN** the platform drops the oldest items and keeps the newest items only
