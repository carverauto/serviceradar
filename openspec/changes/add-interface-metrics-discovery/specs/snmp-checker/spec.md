## ADDED Requirements

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
