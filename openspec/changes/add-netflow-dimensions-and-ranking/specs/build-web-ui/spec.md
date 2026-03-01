## ADDED Requirements

### Requirement: Dimension Selector For NetFlow Visualize
The system SHALL allow selecting and ordering dimensions for `/netflow` Visualize.

#### Scenario: User selects dimensions
- **WHEN** a user selects dimensions (e.g. `protocol_group`, `dst_port`)
- **THEN** the chart groups by the selected dimension(s) according to the chart type

### Requirement: Ranking Mode For Top-N Series
The system SHALL support ranking modes for selecting top-N series: `avg`, `max`, and `last`.

#### Scenario: User switches ranking mode
- **GIVEN** a time-series chart with multiple series
- **WHEN** the user changes ranking mode from `avg` to `max`
- **THEN** the top-N series selection updates accordingly

### Requirement: IP Truncation Control
The system SHALL support IP truncation controls for IP dimensions.

#### Scenario: User truncates source IPs
- **WHEN** a user selects `src_ip` and sets truncation to `/24`
- **THEN** the visualization groups source addresses by their `/24` CIDR prefix
