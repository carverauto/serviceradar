## ADDED Requirements

### Requirement: Sankey diagram visualization
The system SHALL provide a Sankey diagram visualization for NetFlow traffic to show `Source Subnet -> Service/Protocol -> Destination Subnet` over the selected time range.

#### Scenario: Operator drills down from a Sankey edge
- **GIVEN** the NetFlow dashboard is displaying a Sankey diagram
- **WHEN** the operator clicks an edge (e.g. `10.0.0.0/24 -> HTTPS -> 172.16.0.0/24`)
- **THEN** the dashboard applies equivalent global filters
- **AND** the flows table updates to match the selected path

### Requirement: Global traffic heatmap
The system SHALL provide a global traffic heatmap visualization (country-level at minimum) using cached GeoIP enrichment.

#### Scenario: Operator filters flows by destination country
- **GIVEN** GeoIP cache entries exist for destination IPs
- **WHEN** the operator clicks a country on the heatmap
- **THEN** the dashboard applies a destination-geo filter
- **AND** the flows table updates to match

### Requirement: Relative time comparison overlay
The system SHALL support relative time comparisons on traffic time-series charts (e.g. previous window or yesterday) using aligned buckets.

#### Scenario: Compare to previous window
- **WHEN** the operator enables "previous window" comparison
- **THEN** the chart renders the current series and comparison series overlaid
- **AND** the comparison series is computed from a separate query for the shifted window

### Requirement: SRQL-driven visualization data
All NetFlow dashboard visualization series data (charts/widgets/heatmaps/sankey) MUST be produced via SRQL queries.

#### Scenario: No Ecto queries for chart series
- **WHEN** the dashboard renders visualization series data
- **THEN** the series data originates from SRQL queries
- **AND** the UI does not run Ecto queries to compute visualization aggregates
