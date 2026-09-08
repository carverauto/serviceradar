## MODIFIED Requirements

### Requirement: Scanner Metrics Display

The Active Scans tab SHALL display scanner execution metrics in a grid format, handling numeric values that may arrive as integers or floats from the backend.

#### Scenario: Metrics with zero drop rate as integer
- **WHEN** scanner metrics contain `rx_drop_rate_percent` as integer `0`
- **THEN** the metrics grid renders without errors
- **AND** displays "0.0%" for the drop rate

#### Scenario: Metrics with float drop rate
- **WHEN** scanner metrics contain `rx_drop_rate_percent` as float `0.5`
- **THEN** the metrics grid displays "0.5%"

#### Scenario: Metrics with nil drop rate
- **WHEN** scanner metrics do not include `rx_drop_rate_percent`
- **THEN** the metrics grid displays "0.0%" as default
