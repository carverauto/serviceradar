## ADDED Requirements

### Requirement: NetFlow Visualize Supports Five Chart Types
The system SHALL support five D3-based chart types for NetFlow Visualize: stacked area, 100% stacked area, line series, grid, and sankey.

#### Scenario: User switches chart type
- **GIVEN** the user is on `/netflow`
- **WHEN** the user selects a different chart type
- **THEN** the page renders the chosen chart type using SRQL-driven data

### Requirement: Shared Chart Hook API
NetFlow chart hooks SHALL accept datasets via `data-*` attributes (`data-keys`, `data-points`, optional `data-colors`) and render deterministically.

#### Scenario: Chart hook renders points
- **GIVEN** `data-keys` and `data-points` are present
- **WHEN** the hook mounts
- **THEN** it renders the visualization without client-side fetching
