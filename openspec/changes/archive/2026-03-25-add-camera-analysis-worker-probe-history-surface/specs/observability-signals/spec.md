## ADDED Requirements
### Requirement: Probe History Mirrors Emitted Probe Outcomes
The operator-visible recent probe history SHALL align with the platform’s active probe outcomes.

#### Scenario: Probe failure is visible through management surface
- **WHEN** the platform emits a failed active probe outcome for a worker
- **THEN** the worker management surface can show a recent failed probe entry with the same normalized reason
