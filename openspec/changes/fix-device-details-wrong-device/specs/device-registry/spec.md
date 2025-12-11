# Device Registry Lookup Behavior

## ADDED Requirements

### Requirement: Device ID Lookup Returns Exact Match Only

When a device is requested by its unique device ID (format: `partition:type:name`), the system SHALL return only the device with that exact device ID. The system SHALL NOT fall back to IP-based lookup for device ID queries.

#### Scenario: Device ID lookup succeeds
- **WHEN** a device exists with ID `serviceradar:agent:docker-agent`
- **AND** a lookup is performed for `serviceradar:agent:docker-agent`
- **THEN** the system returns the device with ID `serviceradar:agent:docker-agent`

#### Scenario: Device ID lookup fails gracefully
- **WHEN** no device exists with ID `serviceradar:agent:nonexistent`
- **AND** a lookup is performed for `serviceradar:agent:nonexistent`
- **THEN** the system returns a "device not found" error
- **AND** the system does NOT attempt IP-based lookup

#### Scenario: Device ID with shared IP returns correct device
- **WHEN** device `serviceradar:agent:docker-agent` exists at IP `172.17.0.2`
- **AND** device `serviceradar:poller:docker-poller` exists at IP `172.17.0.2`
- **AND** a lookup is performed for `serviceradar:agent:docker-agent`
- **THEN** the system returns only `serviceradar:agent:docker-agent`
- **AND** the system does NOT return `serviceradar:poller:docker-poller`

### Requirement: IP Address Lookup Returns Devices at IP

When a device is requested by IP address, the system SHALL return devices associated with that IP address. This is separate from device ID lookups.

#### Scenario: IP lookup returns matching devices
- **WHEN** devices exist at IP `192.168.1.100`
- **AND** a lookup is performed for `192.168.1.100`
- **THEN** the system returns all devices at that IP

#### Scenario: IP lookup with no devices
- **WHEN** no devices exist at IP `192.168.1.200`
- **AND** a lookup is performed for `192.168.1.200`
- **THEN** the system returns a "device not found" error
