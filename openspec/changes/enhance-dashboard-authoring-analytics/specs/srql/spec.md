## ADDED Requirements

### Requirement: Dashboard authoring query families
SRQL-backed dashboard authoring SHALL support query families where a visual can bind a current-value query and optional trend-over-time query while preserving each query as independent SRQL.

#### Scenario: Gauge trend uses independent SRQL
- **GIVEN** a gauge dashlet has a current-value SRQL query
- **WHEN** the editor adds a trend-over-time comparison
- **THEN** the trend SHALL be represented as a separate SRQL query or generated time-window variant
- **AND** the current-value query SHALL NOT be overwritten.

### Requirement: Pivot-compatible result metadata
SRQL preview metadata used by dashboard authoring SHALL identify fields that can be used as pivot rows, pivot columns, and aggregate values.

#### Scenario: Preview exposes pivot fields
- **GIVEN** an SRQL preview returns string and numeric fields
- **WHEN** the dashboard editor configures a pivot table
- **THEN** string-like fields SHALL be available as row/column dimensions
- **AND** numeric fields SHALL be available as aggregate values.
