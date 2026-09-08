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

### Requirement: Redacted config reads preserve secrets on update
ServiceRadar MUST redact sensitive configuration fields from admin config reads returned to the browser, and MUST preserve previously-stored secret values when the browser submits redacted placeholders.

#### Scenario: Admin edits mapper config without clobbering secrets
- **GIVEN** the mapper configuration contains secret fields (e.g., API keys, SNMP auth data)
- **WHEN** an admin retrieves the config via Core and secret fields are redacted
- **AND** the admin submits an updated config that still includes redacted placeholders for those secret fields
- **THEN** Core SHALL restore the previous secret values when persisting the updated configuration

### Requirement: Core can rebuild SNMP checker targets from preferences
ServiceRadar MUST support rebuilding the effective SNMP checker targets in KV based on enabled interface polling preferences.

#### Scenario: Rebuild updates managed targets only
- **GIVEN** the SNMP checker configuration in KV includes a mix of operator-defined targets and system-managed targets
- **WHEN** Core rebuilds targets based on interface preferences
- **THEN** Core SHALL only replace system-managed targets
- **AND** operator-defined targets SHALL remain unchanged
