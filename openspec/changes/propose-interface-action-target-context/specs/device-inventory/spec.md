## ADDED Requirements

### Requirement: Interface inventory preserves physical-location evidence
The system SHALL preserve physical-location evidence for discovered interfaces when mapper, SNMP ENTITY-MIB, ifStack, LLDP/CDP, or integration data can identify chassis, slot, module, submodule, parent interface, or port ownership.

Physical-location evidence SHALL be stored or projected in a way that can be used by interface details, topology, and northbound action target snapshots without conflating it with SNMP `if_index`.

#### Scenario: ENTITY-MIB maps ifIndex to module port
- **GIVEN** mapper discovery observes IF-MIB interface `if_index = 10103`
- **AND** ENTITY-MIB evidence maps it to chassis `1`, module `1`, and port `3`
- **WHEN** interface inventory is ingested
- **THEN** ServiceRadar SHALL preserve both `if_index = 10103` and the physical-location fields
- **AND** downstream consumers SHALL be able to distinguish the SNMP index from the physical port

#### Scenario: Interface has no physical-location source
- **GIVEN** an interface is discovered without ENTITY-MIB, ifStack, LLDP/CDP, or vendor location evidence
- **WHEN** interface inventory is ingested
- **THEN** ServiceRadar SHALL preserve normal interface fields
- **AND** physical-location fields SHALL remain unset
