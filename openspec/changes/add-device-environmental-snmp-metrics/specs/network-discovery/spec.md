## ADDED Requirements
### Requirement: Device SNMP capability detection
The system SHALL mark a device as SNMP-capable when mapper discovery receives valid SNMP responses for that device and include this capability in discovery results.

#### Scenario: SNMP discovery succeeds
- **GIVEN** mapper discovery receives a valid SNMP response for a device (e.g., sysDescr or ifTable)
- **WHEN** discovery results are emitted
- **THEN** the device capability flag `snmp_supported` SHALL be set to true in the discovery payload

#### Scenario: SNMP discovery fails
- **GIVEN** mapper discovery receives no valid SNMP responses for a device
- **WHEN** discovery results are emitted
- **THEN** the device capability flag `snmp_supported` SHALL be false or omitted

---

### Requirement: Environmental metric discovery
The system SHALL probe a curated catalog of environmental SNMP OIDs during mapper discovery and include the available metrics per device in the discovery payload.

#### Scenario: Environmental metrics available
- **GIVEN** a device that exposes CPU and temperature OIDs
- **WHEN** mapper discovery probes environmental OIDs
- **THEN** the discovery payload SHALL include available metrics with `name`, `oid`, `data_type`, `unit`, and `category`

#### Scenario: No environmental metrics available
- **GIVEN** a device that does not expose any environmental OIDs in the catalog
- **WHEN** mapper discovery completes
- **THEN** the discovery payload SHALL omit `available_environmental_metrics` or set it to an empty list
