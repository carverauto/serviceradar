## ADDED Requirements
### Requirement: Camera Analysis Worker Degradation SHALL Emit Thresholded Alert Signals
The platform SHALL emit explicit observability signals when a registered camera analysis worker crosses bounded degradation thresholds.

#### Scenario: Worker alert activates
- **WHEN** a worker meets a configured degradation threshold such as sustained unhealthy state, flapping, or failover exhaustion
- **THEN** the platform SHALL emit an alert activation signal for that worker
- **AND** the signal SHALL include worker identity and normalized alert metadata

#### Scenario: Worker alert clears
- **WHEN** a worker no longer meets an active degradation threshold
- **THEN** the platform SHALL emit an alert clear signal for that worker

### Requirement: Camera Analysis Worker Alerts SHALL Be Transition-Based
The platform SHALL emit worker alert signals on state transitions instead of on every repeated probe or dispatch event.

#### Scenario: Worker remains in the same alert state
- **WHEN** repeated worker events occur without changing the derived alert state
- **THEN** the platform SHALL NOT emit a new worker alert transition signal for each repeated event
