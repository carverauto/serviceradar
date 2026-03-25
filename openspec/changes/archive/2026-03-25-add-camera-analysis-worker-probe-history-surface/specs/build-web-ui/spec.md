## ADDED Requirements
### Requirement: Camera Analysis Worker Surface Shows Recent Probe Activity
The operator-facing camera analysis worker management surface SHALL show recent active probe outcomes for each worker.

#### Scenario: Operator inspects a worker with recent probe failures
- **WHEN** a worker has recent failed probes
- **THEN** the surface shows recent failure timestamps and normalized reasons

#### Scenario: Operator inspects a stable worker
- **WHEN** a worker has recent successful probes
- **THEN** the surface shows recent successful probe activity
