## ADDED Requirements
### Requirement: SNMP fingerprint payload for discovery
The mapper SNMP discovery pipeline SHALL emit a normalized `snmp_fingerprint` payload per discovered device containing stable system, bridge, and VLAN signals when available.

#### Scenario: Populate system identity signals
- **GIVEN** an SNMP device responds to `sysName`, `sysDescr`, `sysObjectID`, `sysContact`, `sysLocation`, and `ipForwarding`
- **WHEN** mapper discovery processes the device
- **THEN** the published device payload SHALL include those values under `snmp_fingerprint.system`

#### Scenario: Partial fingerprint when bridge tables are absent
- **GIVEN** an SNMP device does not expose BRIDGE-MIB or Q-BRIDGE-MIB tables
- **WHEN** mapper discovery processes the device
- **THEN** mapper SHALL still publish a device payload with available system signals
- **AND** bridge/VLAN fingerprint sections SHALL be omitted or marked unavailable without failing discovery

### Requirement: SNMP fingerprint extraction is bounded and resilient
SNMP fingerprint extraction SHALL use bounded polling timeouts and robust type conversion so malformed or unsupported PDUs do not abort device discovery.

#### Scenario: Unexpected PDU type in system field
- **GIVEN** a system OID response has an unexpected PDU type
- **WHEN** mapper extracts fingerprint fields
- **THEN** mapper SHALL record a field-level extraction error
- **AND** continue extracting remaining fields
- **AND** publish the device with partial fingerprint data
