## ADDED Requirements

### Requirement: Embeddable SNMP Collector Library

The SNMP collector MUST be refactored as an embeddable Go library that can be integrated directly into the serviceradar-agent without requiring a standalone gRPC service.

#### Scenario: Create collector from parsed config
- **GIVEN** a parsed SNMPConfig struct with targets and OIDs
- **WHEN** `NewSNMPCollector(config)` is called
- **THEN** a collector instance is returned ready for use
- **AND** no network listeners are started

#### Scenario: Start and stop collector lifecycle
- **GIVEN** an SNMPCollector instance
- **WHEN** `Start(ctx)` is called
- **THEN** the collector begins polling configured SNMP targets
- **AND** `Stop()` halts polling and releases resources

#### Scenario: Dynamic reconfiguration
- **GIVEN** a running SNMPCollector
- **WHEN** `Reconfigure(newConfig)` is called
- **THEN** new targets are added and removed targets are cleaned up
- **AND** existing targets continue polling without interruption

### Requirement: SNMP Profile-Based Configuration

The SNMP monitoring system MUST support profile-based configuration where administrators define SNMP profiles that are assigned to devices via SRQL queries.

#### Scenario: Device receives profile via SRQL match
- **GIVEN** an SNMP profile with `target_query: "in:devices tags.snmp:enabled"`
- **AND** a device with tag `snmp: enabled`
- **WHEN** the agent requests its configuration
- **THEN** the agent receives the SNMP profile configuration

#### Scenario: Default profile fallback
- **GIVEN** a device with no matching SNMP profiles
- **AND** a default SNMP profile exists (is_default: true)
- **WHEN** the agent requests its configuration
- **THEN** the agent receives the default profile configuration

#### Scenario: SNMP disabled when no profile matches
- **GIVEN** a device with no matching SNMP profiles
- **AND** no default SNMP profile exists
- **WHEN** the agent requests its configuration
- **THEN** the SNMPConfig.enabled is false
- **AND** no SNMP polling occurs

### Requirement: SNMP Target Configuration

Each SNMP profile MUST contain a list of SNMP targets (network devices) to poll, with support for SNMPv1, SNMPv2c, and SNMPv3 authentication.

#### Scenario: SNMPv2c target with community string
- **GIVEN** an SNMP target configured with version v2c
- **AND** community string "public"
- **WHEN** the agent polls the target
- **THEN** SNMP GET requests use the community string for authentication

#### Scenario: SNMPv3 target with auth and privacy
- **GIVEN** an SNMP target configured with version v3
- **AND** security level authPriv with SHA/AES
- **WHEN** the agent polls the target
- **THEN** SNMP requests are authenticated and encrypted

#### Scenario: Target polling interval
- **GIVEN** an SNMP target with poll_interval 60 seconds
- **WHEN** the collector is running
- **THEN** OIDs are polled approximately every 60 seconds
- **AND** polling continues until the collector is stopped

### Requirement: OID Configuration with Data Types

Each SNMP target MUST support configurable OIDs with data type specification, scaling, and delta calculation.

#### Scenario: Counter OID with delta calculation
- **GIVEN** an OID configured with data_type counter and delta true
- **WHEN** two consecutive polls return values 1000 and 1500
- **THEN** the reported value is the delta: 500
- **AND** the value represents the rate of change

#### Scenario: Gauge OID with scaling
- **GIVEN** an OID configured with data_type gauge and scale 0.01
- **WHEN** a poll returns value 9500
- **THEN** the reported value is 95.0
- **AND** scaling is applied after type conversion

### Requirement: SNMP Credential Security

SNMP authentication credentials MUST be encrypted at rest in the database and decrypted only when generating agent configuration.

#### Scenario: Community string encryption
- **GIVEN** an SNMP target with community string "secretcommunity"
- **WHEN** the target is saved to the database
- **THEN** the community string is encrypted using Cloak
- **AND** the plaintext is not stored

#### Scenario: Credential decryption for agent config
- **GIVEN** an encrypted SNMP target configuration
- **WHEN** the SNMPCompiler generates agent config
- **THEN** credentials are decrypted for the proto message
- **AND** the agent receives usable credentials

### Requirement: SNMP Status Reporting

The embedded SNMP collector MUST report per-target status as part of the agent's health status.

#### Scenario: Target available status
- **GIVEN** an SNMP target that responds to polls
- **WHEN** agent status is requested
- **THEN** the target status shows available: true
- **AND** last_poll timestamp is recent

#### Scenario: Target unreachable status
- **GIVEN** an SNMP target that does not respond
- **WHEN** agent status is requested
- **THEN** the target status shows available: false
- **AND** error message describes the connection failure

### Requirement: OID Template Library

The system MUST provide pre-defined OID templates for common monitoring scenarios to simplify SNMP profile configuration.

#### Scenario: Apply interface-stats template
- **GIVEN** an SNMP target configuration form
- **WHEN** the user selects the "interface-stats" template
- **THEN** OIDs for ifInOctets, ifOutOctets, ifOperStatus are added
- **AND** appropriate data types and delta flags are set

#### Scenario: Custom OIDs alongside template
- **GIVEN** an SNMP target with interface-stats template applied
- **WHEN** the user adds a custom OID
- **THEN** both template OIDs and custom OID are polled
