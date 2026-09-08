## ADDED Requirements

### Requirement: NetFlow timestamps honor the user timezone

The interactive NetFlow UI SHALL present human-visible absolute timestamps in the authenticated user's saved timezone across explorer rows, flow details, chart axes, chart tooltips, and displayed time-window labels. NetFlow storage, SRQL filters, chart scale inputs, and range-selection event bounds SHALL remain canonical UTC instants.

#### Scenario: Explorer and detail timestamps use the saved timezone

- **GIVEN** a user with timezone `America/Chicago`
- **AND** a flow with a canonical UTC timestamp
- **WHEN** the user views the flow in an explorer row or detail surface
- **THEN** the visible timestamp SHALL represent the instant in `America/Chicago`
- **AND** the original UTC ISO value SHALL remain available in semantic metadata

#### Scenario: Chart labels and tooltips use the saved timezone

- **GIVEN** a time-based NetFlow chart rendered for a user with a non-UTC timezone
- **WHEN** the chart renders its axis labels or a tooltip
- **THEN** human-visible time labels SHALL use the saved timezone
- **AND** the chart scale SHALL continue to use canonical epoch or UTC values

#### Scenario: Range selection submits canonical bounds

- **GIVEN** localized labels on a NetFlow chart with range selection enabled
- **WHEN** the user commits a bucket or multi-bucket selection
- **THEN** the client event SHALL submit the exact canonical UTC bucket bounds supplied by the server
- **AND** the resulting SRQL query SHALL not be constructed by parsing localized labels

#### Scenario: NetFlow export remains UTC

- **GIVEN** a flow timestamp displayed in the user's timezone
- **WHEN** the same data is returned by an API or downloadable export
- **THEN** its machine-facing timestamp SHALL remain canonical UTC
