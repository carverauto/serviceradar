# snmp-checker (delta)

## ADDED Requirements

### Requirement: Interface counter polling uses the widest supported counter width

The SNMP collector SHALL poll the 64-bit ifHC counter OIDs for interface metrics whenever discovery marked the interface `supports_64bit`, falling back to 32-bit OIDs only when 64-bit is unsupported, and SHALL stamp `counter_width` in emitted metric metadata from the OID actually polled. (This behavior is implemented and verified live; this requirement locks it against regression — a 1 Gbps link wraps a 32-bit octet counter in ~34 seconds, faster than the poll interval.)

#### Scenario: 64-bit capable interface polls ifHC OIDs
- **GIVEN** an interface whose discovery record has supports_64bit true
- **WHEN** the collector polls its octet and packet counters
- **THEN** the 64-bit ifHC OIDs are used
- **AND** the emitted samples carry counter_width 64

#### Scenario: 32-bit-only device falls back with correct stamping
- **GIVEN** an interface without IF-MIB 64-bit support
- **WHEN** the collector polls it
- **THEN** the 32-bit OIDs are used and samples carry counter_width 32

### Requirement: Counter sample drops are accounted

Every interface counter sample dropped or withheld during rate normalization (counter wrap salvage, reset lineage change, gap exceeding the maximum, non-monotonic timestamps, implausible decrease) SHALL increment a counted, per-reason telemetry metric so gaps in interface series are attributable to a cause rather than silent.

#### Scenario: Reset-lineage drop is visible
- **GIVEN** a device that reboots and resets its counters
- **WHEN** the normalizer drops the discontinuous sample
- **THEN** a drop counter with reason reset-lineage increments for that series
