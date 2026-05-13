## ADDED Requirements

### Requirement: Discovery credential surfaces reuse unified credentials
Network discovery and mapper credential workflows SHALL reuse the unified credential inventory for reusable secrets where practical while preserving existing profile-specific behavior until migrated.

#### Scenario: Discovery references existing credential
- **GIVEN** an admin configures a discovery or mapper job that needs controller/API credentials
- **WHEN** a compatible credential exists in the unified credentials inventory
- **THEN** the form SHALL allow selecting that credential
- **AND** it SHALL NOT require retyping the same secret into a separate provider-specific field

#### Scenario: Existing SNMP profile behavior remains compatible
- **GIVEN** existing SNMP profiles store encrypted credentials
- **WHEN** unified credential management is introduced
- **THEN** existing polling and discovery SHALL continue to resolve SNMP credentials correctly
- **AND** the UI SHALL clearly identify whether a credential is profile-local or reusable from the unified inventory
