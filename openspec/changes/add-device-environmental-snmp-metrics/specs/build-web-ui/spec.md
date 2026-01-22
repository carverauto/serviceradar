## ADDED Requirements
### Requirement: Environmental metrics configuration in device details
The device details editor SHALL provide an Environmental Metrics section that allows users to enable SNMP polling for discovered environmental metrics.

#### Scenario: Section is gated by SNMP capability
- **GIVEN** a device without `snmp_supported`
- **WHEN** a user opens the device details editor
- **THEN** the Environmental Metrics section SHALL be hidden

#### Scenario: Section shows discovered metrics
- **GIVEN** a device with `snmp_supported = true` and an `available_environmental_metrics` list
- **WHEN** a user opens the device details editor
- **THEN** the Environmental Metrics section SHALL present the discovered metrics as selectable options

#### Scenario: User enables metrics
- **GIVEN** a device with available environmental metrics
- **WHEN** the user enables selected metrics and saves
- **THEN** the device SNMP metrics settings SHALL be persisted and used for polling
