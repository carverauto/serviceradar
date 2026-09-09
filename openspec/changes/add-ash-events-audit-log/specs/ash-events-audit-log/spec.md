## ADDED Requirements

### Requirement: Centralized API Event Log
The system SHALL record every create, update, and destroy action performed
against `StatefulAlertRule` — regardless of whether it originated from the
web UI or from the JSON:API surface — as a row in a single, centralized
event log resource, keyed by the actor who performed it.

#### Scenario: An action is performed via the JSON:API route
- **WHEN** an authorized actor creates, updates, or destroys a
  `StatefulAlertRule` via `/api/v2/stateful-alert-rules`
- **THEN** exactly one event row SHALL be written recording the resource,
  record id, action, action input, the actor's identity, and the time it
  occurred
- **AND** the event's metadata SHALL record the source as `"api"`

#### Scenario: An action is performed via the existing web UI
- **WHEN** an authorized actor creates, updates, or destroys a
  `StatefulAlertRule` via the existing Settings rules LiveView
- **THEN** exactly one event row SHALL be written with the same fields as
  the API scenario
- **AND** the event's metadata SHALL record the source as `"web"`

### Requirement: Event Logging Does Not Alter Authorization
Recording an event SHALL NOT change whether an action is authorized to run.
Event rows SHALL only be written for actions that already passed
`StatefulAlertRule`'s existing policy checks.

#### Scenario: An unauthorized action is attempted
- **WHEN** an actor lacking operator/admin/system role attempts to create,
  update, or destroy a `StatefulAlertRule`
- **THEN** the action SHALL be denied exactly as it is today
- **AND** no event row SHALL be written for the denied attempt
