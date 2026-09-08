## ADDED Requirements
### Requirement: Camera relay health degradation emits structured events
The system SHALL emit structured relay health events for repeated relay failures, gateway saturation denials, and abnormal viewer-idle churn so those conditions can be monitored and correlated.

#### Scenario: Relay failure burst is detected
- **GIVEN** camera relay session starts are failing repeatedly within a bounded time window
- **WHEN** the failure threshold is crossed
- **THEN** the system SHALL emit a structured relay health event describing the failure burst
- **AND** the event SHALL include the relevant gateway, agent, and relay context when available

#### Scenario: Gateway saturation denies new relay sessions
- **GIVEN** the gateway rejects new relay sessions because the configured concurrency limit is exhausted
- **WHEN** saturation denials occur
- **THEN** the system SHALL emit a structured relay health event for the saturation condition

### Requirement: Camera relay health events can drive alerting
The system SHALL provide default alert rules or templates that can create alerts from structured camera relay health events for repeated failures and sustained saturation.

#### Scenario: Repeated relay failures trigger an alert
- **GIVEN** the relay health event stream records repeated failure-burst events for the same gateway or camera source
- **WHEN** the configured alert threshold is met
- **THEN** the system SHALL create or update an alert for that condition
- **AND** the alert SHALL reference the triggering relay health event or events

#### Scenario: Sustained saturation triggers an alert
- **GIVEN** the relay health event stream records gateway saturation over the configured alert window
- **WHEN** the saturation condition persists
- **THEN** the system SHALL create or update an alert for the saturation incident
