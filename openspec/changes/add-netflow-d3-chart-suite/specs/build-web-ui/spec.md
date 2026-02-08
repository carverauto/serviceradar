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

### Requirement: Consistent Chart Interactivity
NetFlow Visualize chart hooks SHALL provide consistent interactivity patterns: responsive rendering, hover tooltips, and legend toggles where applicable.

#### Scenario: User toggles series visibility
- **GIVEN** a time-series chart with a legend
- **WHEN** the user clicks a legend item
- **THEN** the chart toggles that series visibility without reloading the page

#### Scenario: User hovers for a tooltip
- **GIVEN** a rendered NetFlow chart
- **WHEN** the user hovers over the chart area
- **THEN** the chart shows a tooltip with values and a timestamp (or edge details for sankey)
