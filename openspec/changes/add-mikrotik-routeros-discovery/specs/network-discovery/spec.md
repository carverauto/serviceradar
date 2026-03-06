## ADDED Requirements

### Requirement: MikroTik RouterOS API discovery source
The system SHALL support a read-only MikroTik RouterOS API discovery source for mapper jobs so edge agents can collect RouterOS device and topology metadata without relying exclusively on SNMP.

#### Scenario: RouterOS API discovery returns device identity and interfaces
- **GIVEN** a mapper job with a configured MikroTik RouterOS source
- **WHEN** the job runs in API or SNMP+API mode
- **THEN** the mapper SHALL authenticate to the RouterOS endpoint
- **AND** collect device identity data including hostname/identity, model, RouterOS version, and hardware details when available
- **AND** collect interface, bridge, VLAN, and IP address data when available
- **AND** publish the results through the existing mapper result pipeline

#### Scenario: Unsupported RouterOS resources degrade gracefully
- **GIVEN** a RouterOS target where one or more REST resources are unavailable due to firmware/version differences
- **WHEN** the mapper executes discovery
- **THEN** the mapper SHALL still publish any successful discovery data it collected
- **AND** mark the missing coverage as partial discovery metadata
- **AND** SHALL NOT fail the entire job solely because one optional RouterOS resource is unavailable

### Requirement: MikroTik RouterOS discovery settings
The system SHALL allow mapper jobs to store MikroTik RouterOS connection settings securely and compile them into agent mapper configuration.

#### Scenario: Configure RouterOS source on a mapper job
- **GIVEN** an admin configures a mapper job for RouterOS discovery
- **WHEN** they save the RouterOS endpoint, credentials, and TLS settings
- **THEN** the settings SHALL be persisted in core with encrypted secrets
- **AND** the mapper compiler SHALL include the RouterOS source in the generated agent config

#### Scenario: RouterOS secrets are redacted from UI-facing responses
- **GIVEN** a stored RouterOS discovery source
- **WHEN** the source is read back through UI-facing APIs
- **THEN** endpoint and non-secret settings MAY be returned
- **AND** secrets SHALL be redacted while still indicating whether credentials are present

### Requirement: RouterOS topology evidence ingestion
The system SHALL ingest RouterOS API-derived adjacency and bridge evidence as discovery metadata without overriding higher-confidence SNMP-attributed topology when both sources exist.

#### Scenario: RouterOS provides neighbor evidence
- **GIVEN** a RouterOS discovery result containing LLDP or other reliable neighbor evidence
- **WHEN** the results are ingested
- **THEN** the system SHALL create topology evidence tagged with source `mikrotik-api`
- **AND** the evidence SHALL participate in topology projection alongside other mapper evidence sources

#### Scenario: SNMP-attributed evidence remains authoritative for telemetry mapping
- **GIVEN** the same physical link is observed from RouterOS API data and from LLDP/CDP/SNMP evidence with usable interface attribution
- **WHEN** canonical topology selection runs
- **THEN** SNMP-attributed evidence SHALL remain authoritative for telemetry-bearing edge mapping
- **AND** RouterOS API evidence SHALL remain available as supplemental structural evidence
