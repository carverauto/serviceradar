## ADDED Requirements
### Requirement: Replicated core nodes preserve singleton scheduling
The system MUST preserve singleton scheduling and other recurring singleton background work when `core` runs with multiple replicas.

#### Scenario: Only one replicated core pod schedules recurring work
- **GIVEN** multiple `core` replicas are running
- **WHEN** recurring jobs or scheduler-owned background work are due
- **THEN** exactly one active `core` replica SHALL enqueue or coordinate that work
- **AND** follower `core` replicas SHALL NOT create duplicate recurring work

#### Scenario: Scheduler ownership survives a core failover
- **GIVEN** recurring work is owned by the current active `core` coordinator
- **WHEN** that replica exits or loses coordinator ownership
- **THEN** another healthy `core` replica SHALL assume scheduling ownership
- **AND** periodic work SHALL continue without duplicate scheduling
