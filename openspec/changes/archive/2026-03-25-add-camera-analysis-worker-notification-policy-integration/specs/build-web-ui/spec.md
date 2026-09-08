## ADDED Requirements
### Requirement: Worker ops surface shows notification-policy context
The authenticated camera analysis worker management surface SHALL show whether an active routed worker alert is participating in the standard notification-policy path.

#### Scenario: Worker alert is notification-eligible
- **WHEN** an operator views a worker with an active routed alert that is eligible for standard notification handling
- **THEN** the surface SHALL show normalized notification-policy context for that worker alert

#### Scenario: Worker has no active routed alert
- **WHEN** an operator views a worker without an active routed alert
- **THEN** the surface SHALL not imply that notification-policy routing is active
