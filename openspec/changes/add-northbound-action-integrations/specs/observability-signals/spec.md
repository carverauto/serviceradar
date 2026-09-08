## ADDED Requirements

### Requirement: Northbound Action Observability Events
The observability plane SHALL accept normalized events for northbound action invocation lifecycle and event-handler decisions.

#### Scenario: Invocation lifecycle events are emitted
- **GIVEN** a northbound action invocation is created, dispatched, and completed
- **WHEN** each lifecycle transition occurs
- **THEN** the system emits normalized observability events with invocation ID, provider, action ID, source, target identifiers, and status

#### Scenario: Event handler suppresses an action
- **GIVEN** an event handler suppresses a matching event because of cooldown or dedupe
- **WHEN** the suppression is recorded
- **THEN** the system emits a normalized suppression event with handler ID, originating event ID, dedupe key, and reason
