## ADDED Requirements

### Requirement: Dedicated NetFlow Analytics Page
The system SHALL provide a dedicated `/netflow` route with a two-panel layout: a left options panel for query configuration and a right panel for visualization and data display. The page SHALL NOT be embedded as a tab within the observability page.

#### Scenario: User navigates to NetFlow analytics
- **WHEN** a user navigates to `/netflow`
- **THEN** the page renders with a left options panel containing time range, dimensions, filter input, graph type selector, and units selector
- **AND** the right panel shows the selected visualization type and a data table below it

#### Scenario: Legacy netflows tab redirects
- **WHEN** a user navigates to `/observability` with the netflows tab active
- **THEN** the system redirects to `/netflow` preserving any SRQL query parameters

### Requirement: Five D3 Chart Types for Flow Analytics
The system SHALL render flow analytics using five distinct D3-based chart types: stacked area, 100% stacked area, line series, grid (multi-panel), and Sankey diagram. All chart types SHALL use a consistent color palette and shared interaction patterns.

#### Scenario: Stacked area chart renders flow data
- **WHEN** a user selects the "Stacked Areas" graph type and executes a query with dimensions
- **THEN** the chart renders time on the X-axis, traffic volume on the Y-axis, with each dimension value as a stacked colored area
- **AND** hovering shows a tooltip with timestamp and per-series values
- **AND** the legend allows clicking to toggle series visibility

#### Scenario: 100% stacked area normalizes to percentages
- **WHEN** a user selects the "100% Stacked" graph type
- **THEN** the Y-axis displays 0-100% and each time point's values are normalized to sum to 100%

#### Scenario: Grid chart renders multi-panel layout
- **WHEN** a user selects the "Grid" graph type with N dimension values
- **THEN** the chart renders ceil(sqrt(N)) columns and ceil(N/cols) rows, each panel showing one dimension value with independent Y-axis

#### Scenario: Sankey chart renders flow connections
- **WHEN** a user selects the "Sankey" graph type with 2+ dimensions
- **THEN** the chart renders nodes for each unique dimension value and links showing traffic volume between them

### Requirement: Bidirectional Traffic Visualization
The system SHALL support a bidirectional mode that displays forward and reverse traffic on the same chart using dual Y-axes. The forward direction uses axis 1 (above baseline) and reverse uses axis 2 (below baseline or mirrored).

#### Scenario: Bidirectional mode enabled
- **WHEN** a user enables the bidirectional toggle
- **THEN** the chart shows forward traffic above the X-axis and reverse traffic below (or on a secondary Y-axis)
- **AND** the tooltip shows both forward and reverse values for the hovered time point

### Requirement: Previous Period Comparison Overlay
The system SHALL support overlaying data from a previous time period on the current chart. The comparison period SHALL be automatically determined: hour for <2h, day for <2d, week for <2w, month for <2mo, year otherwise.

#### Scenario: Previous period overlay active
- **WHEN** a user enables the previous period comparison
- **THEN** a ghost series (reduced opacity) showing the prior period's data appears overlaid on the current chart
- **AND** the tooltip shows both current and previous values with the period label

### Requirement: Dimension Selector with Drag-and-Drop
The system SHALL provide a dimension selector that allows users to choose multiple dimensions, reorder them via drag-and-drop, configure IP truncation for IP-type dimensions, and set a top-N limit.

#### Scenario: User selects and reorders dimensions
- **WHEN** a user selects dimensions SrcAS and DstCountry and drags DstCountry above SrcAS
- **THEN** the visualization groups by DstCountry first, then SrcAS

#### Scenario: IP truncation applied
- **WHEN** a user selects SrcIP dimension and sets truncation to /24
- **THEN** the visualization groups source IPs by their /24 prefix (e.g., 10.0.1.0/24)

### Requirement: SRQL Filter Bar with Auto-Completion
The system SHALL provide an SRQL filter input with syntax highlighting, auto-completion from the SRQL catalog, real-time parse validation, and saved filter management.

#### Scenario: Filter auto-completion
- **WHEN** a user types `src_` in the filter bar
- **THEN** a dropdown appears showing matching fields: `src_endpoint_ip`, `src_endpoint_port`, `src_country`, etc.

#### Scenario: Filter validation error
- **WHEN** a user types an invalid SRQL expression
- **THEN** the filter bar shows an inline error indicator with the parse error message

### Requirement: Data Table with Series Statistics
The system SHALL display a data table below the chart showing dimension breakdowns with per-series statistics: average, minimum, maximum, and 95th percentile.

#### Scenario: Data table displays statistics
- **WHEN** a query returns results with dimensions
- **THEN** the data table shows one row per dimension combination with columns for average, min, max, and 95th percentile of the selected metric

### Requirement: Shareable URL State
The system SHALL encode the full query state (time range, dimensions, filters, graph type, units, bidirectional, previous period) into the URL using compressed serialization so that URLs are bookmarkable and shareable.

#### Scenario: URL state round-trip
- **WHEN** a user configures a query and copies the URL
- **AND** another user opens that URL
- **THEN** the page renders with identical query configuration and visualization

### Requirement: Dashboard Homepage with Configurable Widgets
The system SHALL provide a dashboard view at `/netflow` (or `/netflow/dashboard`) with configurable widgets: top-N pie/donut charts, flow rate gauge, active exporters list, mini traffic graph, and last flow detail.

#### Scenario: Dashboard renders with default widgets
- **WHEN** a user navigates to the NetFlow dashboard
- **THEN** the page displays flow rate, top source ASes, top destination countries, top protocols, active exporters, and a 24h traffic graph

#### Scenario: User customizes dashboard widgets
- **WHEN** a user changes a top-N widget from "Source AS" to "Application"
- **THEN** the widget re-renders showing top applications by traffic volume
- **AND** the configuration persists across sessions

### Requirement: Brush Selection for Time Range Zoom
The system SHALL support D3 brush selection on time-series charts that allows users to select a time range by clicking and dragging, which updates the query time window and re-renders.

#### Scenario: User brushes a time range
- **WHEN** a user clicks and drags across a portion of the time-series chart
- **THEN** the query time range updates to the brushed window
- **AND** the URL updates to reflect the new time range
- **AND** all visualizations re-render with the narrowed time window
