## ADDED Requirements

### Requirement: Dashboard Flow Map Summaries
The system SHALL provide bounded, time-windowed summaries of observed NetFlow/IPFIX records for dashboard traffic map rendering. These summaries MUST be derived from persisted or queryable observed flow data and MUST be suitable for high-cardinality environments.

#### Scenario: Dashboard requests top flow links
- **GIVEN** observed flow records exist for the requested time window
- **WHEN** the dashboard requests map summaries
- **THEN** the system returns bounded top flow links or arcs with source, destination, direction, traffic magnitude fields, and optional GeoIP coordinates when enrichment exists
- **AND** the summaries are derived from observed NetFlow/IPFIX data

#### Scenario: GeoIP enrichment is unavailable
- **GIVEN** observed flow records exist
- **AND** GeoIP coordinate enrichment is unavailable for one or more endpoints
- **WHEN** the dashboard requests NetFlow map summaries
- **THEN** the response preserves the flow summary for non-geographic topology/traffic rendering
- **AND** the geographic NetFlow map excludes only the links that lack usable coordinates

#### Scenario: High-cardinality flow data is bounded
- **GIVEN** the selected time window contains more flow pairs than the dashboard can render usefully
- **WHEN** map summaries are generated
- **THEN** the system applies a deterministic top-N or aggregation limit
- **AND** it avoids returning unbounded raw flow rows to the dashboard map

#### Scenario: No observed flow data
- **GIVEN** no observed flow records exist for the requested time window
- **WHEN** the dashboard requests map summaries
- **THEN** the system returns an empty result with enough metadata for the UI to render a no-data state
- **AND** it does not return synthetic flow summaries
