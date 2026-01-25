## ADDED Requirements
### Requirement: Mapper interface de-duplication and merging
Mapper discovery MUST consolidate interface updates to a unique interface key before publishing results, merging attributes from multiple discovery sources (SNMP/API) into a single interface record.

#### Scenario: Duplicate interface from SNMP and API
- **GIVEN** the same device/interface is discovered by both SNMP and API in a single job
- **WHEN** mapper interface results are published
- **THEN** the mapper SHALL emit a single interface record per unique interface key
- **AND** the record SHALL include merged attributes from both sources

#### Scenario: Repeated discovery on the same target
- **GIVEN** a job scans the same device via multiple seed targets
- **WHEN** mapper interface results are published
- **THEN** duplicate interface updates SHALL be coalesced
- **AND** interface counts SHALL reflect unique interfaces only
