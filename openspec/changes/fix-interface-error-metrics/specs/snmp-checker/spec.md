## ADDED Requirements
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
