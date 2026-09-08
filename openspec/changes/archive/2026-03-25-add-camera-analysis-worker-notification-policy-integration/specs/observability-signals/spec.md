## ADDED Requirements
### Requirement: Camera analysis worker alerts participate in notification policy
The platform SHALL evaluate routed camera analysis worker alerts through the standard notification-policy path used by existing observability alerts.

#### Scenario: Routed worker alert is notification-eligible
- **GIVEN** a camera analysis worker enters a derived routed alert state
- **WHEN** the corresponding observability alert is created or activated
- **THEN** the alert SHALL be eligible for standard notification-policy evaluation
- **AND** the platform SHALL NOT require a worker-specific notification subsystem

#### Scenario: Routed worker alert clears through the standard path
- **GIVEN** a routed camera analysis worker alert is active
- **WHEN** the worker leaves the derived alert state and the routed alert clears
- **THEN** the notification-policy path SHALL observe the clear through the standard alert lifecycle

### Requirement: Long-lived worker alerts use bounded re-notify semantics
The platform SHALL rely on the existing alert cooldown and re-notify behavior for sustained routed camera analysis worker alerts.

#### Scenario: Sustained worker degradation re-notifies without duplicate transitions
- **GIVEN** a routed camera analysis worker alert remains active without changing alert state
- **WHEN** the standard alert re-notify interval elapses
- **THEN** the platform SHALL re-notify through the standard alert path
- **AND** it SHALL NOT emit duplicate routed worker alert transitions for the unchanged worker state
