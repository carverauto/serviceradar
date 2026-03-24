## ADDED Requirements
### Requirement: Worker ops surface can correlate routed alerts
The authenticated camera analysis worker management surface SHALL expose enough alert-routing context to correlate a worker's current derived alert state with standard observability alerts.

#### Scenario: Worker has a routed alert
- **WHEN** an operator views a worker with an active routed worker alert
- **THEN** the surface SHALL show enough normalized alert context to explain that routed alert state
- **AND** it SHALL allow the operator to recognize that the worker alert is also present in the standard observability flow

#### Scenario: Worker has no routed alert
- **WHEN** an operator views a worker without an active routed worker alert
- **THEN** the surface SHALL not claim that a routed alert is active
