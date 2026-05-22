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

### Requirement: SLO compliance transitions emit normalized events
The system SHALL create normalized OCSF events when SLO compliance, error-budget, or burn-rate state crosses configured thresholds.

#### Scenario: SLO enters noncompliant state
- **GIVEN** an SLO has a `99.9%` rolling 30-day availability goal
- **WHEN** the measured compliance falls below the goal
- **THEN** the system SHALL create an OCSF event linked to the SLO, SLI, affected service set, compliance period, current compliance, and error-budget state
- **AND** the event SHALL be eligible for alert promotion

#### Scenario: Error budget warning emits informational event
- **GIVEN** an SLO alert policy emits a warning when remaining budget is below `25%`
- **WHEN** the evaluator observes remaining budget crossing below `25%`
- **THEN** the system SHALL create a warning or informational event according to policy
- **AND** it SHALL include budget remaining, budget consumed, and period boundaries

#### Scenario: Fast burn emits critical event
- **GIVEN** an SLO has short-window and long-window burn-rate thresholds
- **WHEN** both thresholds are exceeded
- **THEN** the system SHALL emit a critical burn-rate event
- **AND** the event SHALL include burn rates and projected time to budget exhaustion

### Requirement: SLO events promote to alerts through stateful rules
SLO compliance, error-budget, and burn-rate events SHALL be eligible for alert promotion through stateful alert rules with grouping, dedupe, cooldown, and re-notify behavior.

#### Scenario: Burn-rate alert groups by SLO
- **GIVEN** multiple service checks contribute to the same SLO burn-rate violation
- **WHEN** the alert rule groups by SLO ID
- **THEN** the system SHALL create or update one alert for that SLO
- **AND** the alert SHALL link to representative events, affected services, and current error-budget state
