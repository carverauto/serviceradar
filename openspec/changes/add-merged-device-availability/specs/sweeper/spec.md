## MODIFIED Requirements

### Requirement: Core Processes Sweep Results via DIRE

The core SHALL process sweep results through DIRE and SHALL submit each matched host's reachability to the device availability resolver as `active_probe` evidence, without writing `ocsf_devices.is_available` directly.

#### Scenario: Update device availability from sweep
- **GIVEN** sweep results indicating host availability
- **WHEN** core processes the results
- **THEN** DIRE SHALL match hosts to existing devices by IP
- **AND** submit `active_probe` availability evidence for each matched device, carrying the reporting agent, the reporter's eligibility for the sweep group, the observed state and a TTL derived from the sweep interval
- **AND** the device's availability SHALL change only as decided by the availability resolver
- **AND** update `ocsf_devices.last_seen_time` for available devices
- **AND** add "sweep" to `discovery_sources` array

#### Scenario: Sweep failure counters are not stored on the device row
- **GIVEN** a device that fails consecutive sweeps
- **WHEN** core processes each failed result
- **THEN** the consecutive-failure count SHALL be kept on the sweep evidence record, capped at the confirmation threshold
- **AND** core SHALL NOT write sweep failure counters into `ocsf_devices.metadata`

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
