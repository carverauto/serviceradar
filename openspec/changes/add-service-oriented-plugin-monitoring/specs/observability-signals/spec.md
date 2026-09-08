## ADDED Requirements

### Requirement: Check result transitions emit normalized events
The system SHALL create normalized OCSF events from service check result transitions according to monitoring binding policy.

#### Scenario: Warning transition emits event
- **GIVEN** a binding emits events for warning and critical transitions
- **WHEN** a check instance changes from OK to WARNING
- **THEN** the created event SHALL reference the check instance, monitored service, optional device, binding, descriptor, agent, and observed timestamp

#### Scenario: Repeated unchanged OK does not emit transition event
- **GIVEN** a check instance remains OK across repeated executions
- **WHEN** no transition policy matches
- **THEN** the system SHALL update latest state and metrics
- **AND** it SHALL NOT create duplicate OK transition events

### Requirement: Check events promote to alerts through stateful rules
Service check events SHALL be eligible for alert promotion through stateful alert rules with grouping, dedupe, cooldown, and re-notify behavior.

#### Scenario: Group alert by service group
- **GIVEN** an alert rule groups critical HTTP check events by service group
- **WHEN** multiple services in the same group fail within the configured window
- **THEN** the system SHALL create or update the grouped alert
- **AND** the alert SHALL link back to representative events and affected check instances

### Requirement: Check result details are redacted before event storage
The system SHALL redact secrets and sensitive endpoint material from check events, alert payloads, and plugin result details before persistence or UI rendering.

#### Scenario: HTTP auth header is not stored
- **GIVEN** an authenticated HTTP check fails
- **WHEN** the plugin result and transition event are persisted
- **THEN** bearer tokens, cookies, passwords, API keys, and private key material SHALL NOT appear in details, event metadata, alert metadata, logs, or UI payloads

