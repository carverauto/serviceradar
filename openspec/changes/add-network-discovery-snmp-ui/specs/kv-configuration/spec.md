## ADDED Requirements

### Requirement: KV-backed per-interface SNMP polling preferences
ServiceRadar MUST store per-interface SNMP metric polling preferences in KV using one entry per interface keyed by a stable interface identifier (for example `device_id` + `if_index`) so preferences scale with large discovered networks.

#### Scenario: Enable preference stored without overwriting others
- **GIVEN** interface polling preferences exist for multiple interfaces
- **WHEN** an admin enables SNMP polling for one interface
- **THEN** Core SHALL write only that interface’s preference entry in KV
- **AND** preferences for other interfaces SHALL remain unchanged

#### Scenario: Preference entries are addressable via stable identifiers
- **GIVEN** a discovered interface can be identified by stable fields (for example `device_id` + `if_index`)
- **WHEN** Core persists a polling preference for that interface
- **THEN** the KV key used for that preference SHALL be derivable from those stable identifiers
- **AND** Core SHALL sanitize identifiers as needed so the KV key is valid
