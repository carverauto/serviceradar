## MODIFIED Requirements
### Requirement: Core Processes Sweep Results via DIRE

The core SHALL process sweep results through DIRE to update device records with availability information.

#### Scenario: Update device availability from sweep
- **GIVEN** sweep results indicating host availability
- **WHEN** core processes the results
- **THEN** DIRE SHALL match hosts to existing devices by IP
- **AND** update `ocsf_devices.is_available` based on sweep result
- **AND** update `ocsf_devices.last_seen_time` for available devices
- **AND** add "sweep" to `discovery_sources` array

#### Scenario: Ignore sweep hosts not in inventory
- **GIVEN** sweep results for a host not in device inventory
- **WHEN** core processes the results
- **THEN** DIRE SHALL NOT create a new device record
- **AND** the host result SHALL be excluded from inventory updates
- **AND** the host result SHALL NOT create device or alias records

#### Scenario: Enrich device with port information
- **GIVEN** sweep results with TCP port scan data
- **WHEN** core processes the results
- **THEN** the device metadata SHALL be updated with open ports
- **AND** device type MAY be inferred from port signatures (e.g., port 22 = likely server)
