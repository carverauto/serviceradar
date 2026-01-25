## ADDED Requirements
### Requirement: Interface metrics timeseries charts
The device interface metrics view SHALL render SNMP interface traffic as timeseries charts with a time axis, a rate axis, and gridlines for readability.

#### Scenario: Interface traffic chart axes
- **GIVEN** a device interface has SNMP traffic metrics available
- **WHEN** the interface metrics charts are rendered
- **THEN** the chart SHALL show a time-based X axis and a rate-based Y axis
- **AND** the chart SHALL include gridlines aligned to the axes

#### Scenario: Counter-based traffic rate calculation
- **GIVEN** SNMP interface traffic metrics are stored as counters (ifIn/OutOctets or ifHCIn/OutOctets)
- **WHEN** the interface metrics chart is rendered
- **THEN** the chart SHALL display per-second rates computed from consecutive counter deltas
