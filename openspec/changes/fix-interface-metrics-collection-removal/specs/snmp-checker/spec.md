## ADDED Requirements
### Requirement: Interface Metrics Removal on Config Refresh

The SNMP collector MUST stop collecting interface metrics that are removed from configuration on a refresh cycle.

#### Scenario: Disable interface error counters
- **GIVEN** an interface was previously configured to collect error counters
- **WHEN** the config refresh removes error counter collection for that interface
- **THEN** subsequent SNMP polls MUST omit `in_errors` and `out_errors` values for that interface

#### Scenario: Remove all interface metrics
- **GIVEN** an interface had metrics collection enabled
- **WHEN** a config refresh removes all metrics for that interface
- **THEN** the collector MUST stop collecting interface metrics for that interface
- **AND** no interface metrics payload entries are emitted for the removed metrics
