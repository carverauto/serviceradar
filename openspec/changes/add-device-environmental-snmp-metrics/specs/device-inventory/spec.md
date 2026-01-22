## ADDED Requirements
### Requirement: Device capability flags
The system SHALL store device capability flags (including SNMP support) in the device inventory and expose them in device query results.

#### Scenario: Persist SNMP capability
- **GIVEN** discovery results indicate `snmp_supported = true` for a device
- **WHEN** the device inventory is updated
- **THEN** the device record SHALL persist the SNMP capability flag

#### Scenario: Capability exposed to clients
- **GIVEN** a device with `snmp_supported = true`
- **WHEN** the device is returned via API/SRQL queries
- **THEN** the response SHALL include the SNMP capability flag

---

### Requirement: Available environmental metrics storage
The system SHALL store per-device environmental metric availability as a JSONB list and expose it in device query results.

#### Scenario: Persist environmental metrics
- **GIVEN** discovery results include `available_environmental_metrics`
- **WHEN** the device inventory is updated
- **THEN** the device record SHALL store the metrics list with `name`, `oid`, `data_type`, `unit`, and `category`

#### Scenario: Metrics list exposed to clients
- **GIVEN** a device record with stored environmental metrics
- **WHEN** the device is returned via API/SRQL queries
- **THEN** the response SHALL include `available_environmental_metrics`
