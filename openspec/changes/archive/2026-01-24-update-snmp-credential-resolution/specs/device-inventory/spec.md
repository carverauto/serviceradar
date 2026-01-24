## ADDED Requirements

### Requirement: Device-level SNMP credential overrides
The system SHALL allow per-device SNMP credential overrides that supersede profile credentials during discovery and polling.

#### Scenario: Persist per-device overrides
- **GIVEN** an admin saves SNMP credentials on a device
- **WHEN** the device is updated
- **THEN** the credentials SHALL be stored encrypted and associated with the device

#### Scenario: Override applied to polling
- **GIVEN** a device with a stored SNMP credential override
- **WHEN** SNMP polling config is generated
- **THEN** the override SHALL be used for that device
