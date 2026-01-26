# snmp-checker Specification

## Purpose
TBD - created by archiving change fix-snmp-check-deadlock. Update Purpose after archive.
## Requirements
### Requirement: SNMP checker health checks are deadlock-free
The SNMP checker service MUST allow `Check()` and `GetStatus()` to execute concurrently with datapoint processing without deadlocking.

#### Scenario: Health check during concurrent datapoint updates
- **GIVEN** the SNMP checker is processing datapoints (updating internal status)
- **WHEN** a health check calls `Check()` concurrently with datapoint updates
- **THEN** `Check()` returns a result without blocking indefinitely

### Requirement: SNMP PDU string types convert without panics
The SNMP checker MUST convert gosnmp PDU values of type `OctetString` and `ObjectDescription` into Go strings without panicking.

#### Scenario: Convert OctetString value returned as bytes
- **GIVEN** an SNMP response variable with Type `OctetString` and Value `[]byte("Test SNMP String")`
- **WHEN** the SNMP client converts the variable
- **THEN** the conversion result is the string `"Test SNMP String"` and conversion returns no error

#### Scenario: Convert ObjectDescription value returned as bytes
- **GIVEN** an SNMP response variable with Type `ObjectDescription` and Value `[]byte("Device OS v1.2.3")`
- **WHEN** the SNMP client converts the variable
- **THEN** the conversion result is the string `"Device OS v1.2.3"` and conversion returns no error

#### Scenario: Unexpected value type does not crash the checker
- **GIVEN** an SNMP response variable with Type `OctetString` or `ObjectDescription` and a Value that is not a `[]byte`
- **WHEN** the SNMP client converts the variable
- **THEN** conversion returns an error and the checker does not panic

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
- **THEN** the agent receives the SNMP profile configuration (including credentials)

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

### Requirement: Interface Metrics Discovery

The SNMP mapper MUST discover available metrics for each interface during SNMP interface enumeration by probing standard IF-MIB OIDs.

#### Scenario: Discover 32-bit counter availability
- **GIVEN** an SNMP-enabled device with interface ifIndex 1
- **WHEN** the mapper performs interface discovery
- **THEN** the mapper probes ifInOctets OID (.1.3.6.1.2.1.2.2.1.10.1)
- **AND** if the device responds with a valid value, ifInOctets is marked as available
- **AND** if the device returns noSuchObject or timeout, ifInOctets is marked as unavailable

#### Scenario: Discover 64-bit counter support
- **GIVEN** an SNMP-enabled device with interface ifIndex 1
- **WHEN** the mapper probes ifHCInOctets OID (.1.3.6.1.2.1.31.1.1.1.6.1)
- **AND** the device responds with a valid 64-bit counter value
- **THEN** the metric record includes supports_64bit: true
- **AND** the 64-bit OID is stored alongside the 32-bit OID

#### Scenario: Handle devices without 64-bit counter support
- **GIVEN** an SNMP-enabled device that does not support IF-MIB extensions
- **WHEN** the mapper probes ifHCInOctets OID
- **AND** the device returns noSuchObject or noSuchInstance
- **THEN** the metric record includes supports_64bit: false
- **AND** only the 32-bit OID is stored

#### Scenario: Include discovered metrics in interface record
- **GIVEN** the mapper has probed standard OIDs for interface ifIndex 1
- **WHEN** the discovered interface is published
- **THEN** the DiscoveredInterface message includes available_metrics field
- **AND** available_metrics contains an entry for each successfully probed OID
- **AND** each entry includes name, oid, data_type, and supports_64bit

### Requirement: Standard Interface OIDs

The mapper MUST probe for the following standard IF-MIB OIDs during interface discovery:

| Metric | OID (32-bit) | OID (64-bit) | Data Type |
|--------|--------------|--------------|-----------|
| ifInOctets | .1.3.6.1.2.1.2.2.1.10 | .1.3.6.1.2.1.31.1.1.1.6 | counter |
| ifOutOctets | .1.3.6.1.2.1.2.2.1.16 | .1.3.6.1.2.1.31.1.1.1.10 | counter |
| ifInErrors | .1.3.6.1.2.1.2.2.1.14 | - | counter |
| ifOutErrors | .1.3.6.1.2.1.2.2.1.20 | - | counter |
| ifInDiscards | .1.3.6.1.2.1.2.2.1.13 | - | counter |
| ifOutDiscards | .1.3.6.1.2.1.2.2.1.19 | - | counter |
| ifInUcastPkts | .1.3.6.1.2.1.2.2.1.11 | .1.3.6.1.2.1.31.1.1.1.7 | counter |
| ifOutUcastPkts | .1.3.6.1.2.1.2.2.1.17 | .1.3.6.1.2.1.31.1.1.1.11 | counter |

#### Scenario: Probe all standard counter OIDs
- **GIVEN** an SNMP-enabled device with a discovered interface
- **WHEN** the mapper probes for available metrics
- **THEN** all 8 standard counter OIDs are probed (both 32-bit and 64-bit variants where applicable)
- **AND** the probing completes within 5 seconds per interface

#### Scenario: Metric probe timeout handling
- **GIVEN** an SNMP device that responds slowly
- **WHEN** a single OID probe takes longer than 1 second
- **THEN** the probe is aborted for that OID
- **AND** the OID is marked as unavailable
- **AND** probing continues for remaining OIDs

### Requirement: Metrics Discovery Protocol Buffer Message

The discovery protocol buffer MUST include an InterfaceMetric message and available_metrics field in DiscoveredInterface.

#### Scenario: InterfaceMetric message structure
- **GIVEN** the discovery.proto file
- **WHEN** InterfaceMetric message is defined
- **THEN** it includes string name field
- **AND** it includes string oid field
- **AND** it includes string data_type field (counter, gauge)
- **AND** it includes bool supports_64bit field
- **AND** it includes optional string oid_64bit field

#### Scenario: DiscoveredInterface includes available metrics
- **GIVEN** the discovery.proto file
- **WHEN** DiscoveredInterface message is updated
- **THEN** it includes repeated InterfaceMetric available_metrics field

### Requirement: Interface error counters are collected when configured
The SNMP collector MUST collect configured interface error counters (ifInErrors, ifOutErrors) and emit them as interface metrics fields using canonical keys.

#### Scenario: Configured error counters are emitted
- **GIVEN** an SNMP profile that enables interface error counters for a target interface
- **WHEN** the collector polls the interface
- **THEN** the emitted interface metrics payload includes `in_errors` and `out_errors` values
- **AND** the values are sourced from the configured OIDs

#### Scenario: Unconfigured error counters are omitted
- **GIVEN** an SNMP profile that does not enable interface error counters
- **WHEN** the collector polls the interface
- **THEN** the emitted interface metrics payload does not include `in_errors` or `out_errors`

### Requirement: Profile credential inheritance
SNMP profiles SHALL store credentials (v1/v2c/v3) that can be applied to targets unless overridden per device.

#### Scenario: Target inherits profile credentials
- **GIVEN** a profile with SNMPv2c community "public"
- **AND** a device matched to that profile
- **WHEN** SNMP config is compiled
- **THEN** targets for that device SHALL use the profile credentials

### Requirement: Credential precedence
SNMP credential resolution SHALL follow the precedence order: per-device override > profile credentials.

#### Scenario: Device override wins
- **GIVEN** a device with a per-device SNMP credential override
- **AND** a matching profile with different credentials
- **WHEN** SNMP config is compiled
- **THEN** the per-device override SHALL be used

### Requirement: Profile priority ordering
When multiple profiles match a device, the system SHALL choose the highest-priority profile.

#### Scenario: Higher priority wins
- **GIVEN** two matching SNMP profiles with priorities 10 and 5
- **WHEN** SNMP config is compiled
- **THEN** the profile with priority 10 SHALL be selected

### Requirement: SNMP checker is embedded in serviceradar-agent only
The system SHALL ship SNMP checking capabilities exclusively as an embedded library within `serviceradar-agent` and SHALL NOT build, publish, or deploy a standalone SNMP checker service.

#### Scenario: Build and release artifacts exclude standalone SNMP checker
- **WHEN** release artifacts are built (Bazel targets, Docker images)
- **THEN** no standalone SNMP checker image or binary is produced
- **AND** SNMP functionality remains available via `serviceradar-agent`

#### Scenario: Deployment manifests exclude standalone SNMP checker
- **WHEN** Docker Compose or Helm manifests are rendered
- **THEN** no standalone SNMP checker service, deployment, or chart entry is present
- **AND** SNMP configuration continues to apply to `serviceradar-agent`

