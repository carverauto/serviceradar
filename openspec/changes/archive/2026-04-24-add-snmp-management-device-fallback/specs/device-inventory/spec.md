## ADDED Requirements

### Requirement: Management Device Relationship

The system SHALL support a `management_device_id` field on devices to indicate that a device is reachable for management operations (e.g., SNMP polling) through another device rather than directly at its own IP address.

#### Scenario: Device created from discovered interface IP has management device set
- **GIVEN** the mapper discovers interfaces on device `sr:parent` at IP `192.168.1.1`
- **AND** an interface on that device has IP `203.0.113.5`
- **WHEN** DIRE creates a new device record for `203.0.113.5`
- **THEN** the new device SHALL have `management_device_id` set to `sr:parent`

#### Scenario: Device without management device retains direct reachability
- **GIVEN** a device with `management_device_id = nil`
- **WHEN** the system determines how to reach the device
- **THEN** the device's own `ip` field SHALL be used
