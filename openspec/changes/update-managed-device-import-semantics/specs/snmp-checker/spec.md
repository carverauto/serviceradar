## ADDED Requirements
### Requirement: SNMP polling excludes inactive devices
SNMP target resolution SHALL exclude inactive devices from generated poll targets.

#### Scenario: SNMP profile skips inactive inventory
- **GIVEN** an SNMP profile target query matches a device with `is_active = false`
- **WHEN** ServiceRadar materializes SNMP targets for agents
- **THEN** the inactive device SHALL NOT be included in the SNMP target list
