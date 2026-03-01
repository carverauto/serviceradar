## MODIFIED Requirements

### Requirement: SNMP Target Reachability Check

The mapper discovery engine SHALL attempt SNMP connection for all targets in the SNMP target pool regardless of ICMP ping result, so that devices which block ICMP but allow SNMP are still discovered and enriched.

#### Scenario: Device responds to SNMP but not ICMP ping
- **GIVEN** device `192.168.1.131` is in the SNMP target pool (discovered via UniFi API)
- **AND** the device does not respond to ICMP ping
- **AND** the device responds to SNMP queries on port 161
- **WHEN** the mapper runs Phase 2 SNMP polling
- **THEN** the mapper SHALL still perform the SNMP system info query, interface walk, and topology walk for the device
- **AND** the mapper SHALL log a warning that ICMP ping failed for the target

#### Scenario: Device responds to both ICMP and SNMP
- **GIVEN** device `192.168.2.1` is in the SNMP target pool
- **AND** the device responds to ICMP ping
- **AND** the device responds to SNMP queries
- **WHEN** the mapper runs Phase 2 SNMP polling
- **THEN** the mapper SHALL perform the SNMP system info query, interface walk, and topology walk as before (no regression)
