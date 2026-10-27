## MODIFIED Requirements

### Requirement: Core Processes Sweep Results via DIRE

The core SHALL process sweep results through DIRE, SHALL record each matched host's result in the per-agent availability ledger, and SHALL have the device availability resolver re-resolve the matched devices, and SHALL NOT write `ocsf_devices.is_available` directly.

#### Scenario: Update device availability from sweep
- **GIVEN** sweep results indicating host availability
- **WHEN** core processes the results
- **THEN** DIRE SHALL match hosts to existing devices by IP
- **AND** upsert the reporting agent's latest result for each matched device into the per-agent ledger, keeping the result whether reachable or not
- **AND** re-resolve each matched device's availability in the same transaction
- **AND** the device's availability SHALL change only as decided by the availability resolver
- **AND** update `ocsf_devices.last_seen_time` for available devices
- **AND** add "sweep" to `discovery_sources` array

#### Scenario: Sweep failure counters are not stored on the device row
- **GIVEN** a device that fails consecutive sweeps
- **WHEN** core processes each failed result
- **THEN** the consecutive-failure count SHALL be kept on the agent's per-agent ledger row, capped at the confirmation threshold
- **AND** once the legacy availability writers are removed, core SHALL NOT write sweep failure counters into `ocsf_devices.metadata`

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
