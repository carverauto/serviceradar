## MODIFIED Requirements

### Requirement: OID Configuration with Data Types

Each SNMP target MUST support configurable OIDs with data type specification and scaling. Counter OIDs SHALL preserve raw cumulative values and wire type metadata; rate/delta calculation SHALL be performed by the counter normalization consumer unless an explicitly configured compatibility mode is enabled.

#### Scenario: Counter value is preserved as raw cumulative
- **GIVEN** an OID configured or observed as Counter32 or Counter64
- **WHEN** two consecutive polls return values 1000 and 1500
- **THEN** the emitted metric SHALL include the raw value 1500 and the counter width
- **AND** downstream rate views MAY derive the delta 500 from stored raw values

#### Scenario: Gauge scaling still applies
- **GIVEN** an OID configured with data_type gauge and scale 0.01
- **WHEN** a poll returns value 9500
- **THEN** the reported gauge value is 95.0
- **AND** the value is not treated as a monotonic counter

## ADDED Requirements

### Requirement: Reset-Default Counter Handling
The SNMP counter path SHALL treat counter decreases as resets by default and SHALL only apply wrap adjustment when wrap is positively corroborated.

#### Scenario: Device reboot does not create wrap spike
- **GIVEN** a Counter32 value decreases after `sysUpTime` or `ifCounterDiscontinuityTime` indicates a reset
- **WHEN** the counter normalizer processes the new value
- **THEN** the interval SHALL be dropped or marked reset
- **AND** no wrap-adjusted spike SHALL be emitted

#### Scenario: Known 32-bit wrap is adjusted
- **GIVEN** a known Counter32 value decreases while reset anchors are unchanged
- **AND** the elapsed time and expected maximum rate make a single wrap plausible
- **WHEN** the counter normalizer processes the interval
- **THEN** it MAY compute the wrapped delta using integer arithmetic

#### Scenario: 64-bit decrease is reset
- **GIVEN** a Counter64 value decreases
- **WHEN** the counter normalizer processes the interval
- **THEN** the interval SHALL be treated as reset or invalid
- **AND** the normalizer SHALL NOT add a 64-bit modulus
