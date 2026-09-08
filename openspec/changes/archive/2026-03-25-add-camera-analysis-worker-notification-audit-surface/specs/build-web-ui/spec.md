## ADDED Requirements
### Requirement: Worker ops surface shows notification audit state
The authenticated camera analysis worker management surface SHALL show bounded notification audit state for active routed worker alerts.

#### Scenario: Worker has active routed alert with notifications
- **WHEN** an operator views a worker with an active routed alert
- **THEN** the surface SHALL show current notification audit fields such as notification count and last notification time

#### Scenario: Worker has no active routed alert
- **WHEN** an operator views a worker without an active routed alert
- **THEN** the surface SHALL not imply that notification delivery has occurred
