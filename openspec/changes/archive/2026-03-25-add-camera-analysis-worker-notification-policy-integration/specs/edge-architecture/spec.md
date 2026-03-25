## ADDED Requirements
### Requirement: Worker notification policy integration reuses routed alerts
The platform SHALL integrate camera analysis worker notifications from the existing routed alert lifecycle rather than from direct worker health transitions.

#### Scenario: Notification input comes from routed alert lifecycle
- **WHEN** a camera analysis worker alert becomes active
- **THEN** the platform SHALL derive notification-policy input from the routed observability alert
- **AND** it SHALL NOT create a parallel worker-only notification record

#### Scenario: Unchanged worker state remains duplicate-suppressed
- **GIVEN** repeated probe or dispatch failures occur while a worker remains in the same derived alert state
- **WHEN** notification-policy input is evaluated
- **THEN** the platform SHALL keep routed worker alert transitions duplicate-suppressed
- **AND** any repeated notifications SHALL come from the standard re-notify path instead
