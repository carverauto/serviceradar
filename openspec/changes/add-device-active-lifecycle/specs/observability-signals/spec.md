## ADDED Requirements
### Requirement: Inactive Devices Suppress Operational Signals
The system SHALL suppress device-scoped operational event and alert generation for devices marked inactive, while preserving raw telemetry and logs for audit/history.

#### Scenario: Inactive device telemetry does not create alerts
- **GIVEN** a device has `is_active = false`
- **WHEN** telemetry, health, or promoted log signals for that device would normally create an event or alert
- **THEN** the system SHALL NOT create a device-scoped operational event or alert for that signal
- **AND** raw telemetry/log records SHALL remain ingestible and queryable

#### Scenario: Active device telemetry still creates alerts
- **GIVEN** a device has `is_active = true`
- **WHEN** telemetry, health, or promoted log signals for that device match event or alert rules
- **THEN** the system SHALL create the corresponding event or alert according to existing rule behavior
