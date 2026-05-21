## ADDED Requirements

### Requirement: Mapper and discovery credentials resolve through broker
Mapper and network discovery credential consumers SHALL resolve internal and external credentials through the credential broker instead of directly decrypting credential rows.

#### Scenario: Mapper uses external controller token
- **GIVEN** a mapper controller credential references an external secret provider object
- **WHEN** a mapper run starts
- **THEN** the mapper credential resolver SHALL obtain a broker grant for the controller target
- **AND** the mapper SHALL receive credential material only inside the owned request/client adapter

#### Scenario: Standalone tool does not decrypt database rows
- **GIVEN** a standalone discovery or mapper tool needs credentials
- **WHEN** it is run outside the ServiceRadar broker context
- **THEN** it SHALL NOT decrypt Ash/Cloak database rows directly
- **AND** it SHALL require a brokered export or test-only explicit credential input

#### Scenario: SNMP credentials use reusable broker secrets
- **GIVEN** an SNMP profile, explicit SNMP target, or device SNMP override references a reusable network credential secret
- **WHEN** mapper or SNMP agent configuration is compiled
- **THEN** the compiler SHALL resolve the SNMP credential through the credential broker
- **AND** legacy encrypted SNMP fields SHALL remain valid as a compatibility fallback until migrated

### Requirement: Discovery external reference tests are scoped
Discovery and mapper credential tests SHALL run through the selected control-plane or agent-side broker path with target and provider scope enforcement.

#### Scenario: Test from selected agent
- **GIVEN** an external secret provider is reachable only from an edge site
- **WHEN** an admin tests a discovery credential reference through an eligible agent
- **THEN** the test SHALL use an agent-side broker grant
- **AND** the response SHALL report reachability/auth/status without returning secret values
