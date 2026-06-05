## ADDED Requirements

### Requirement: Attributed Flow Explorer Pagination And Live Mode
The attributed flow explorer SHALL default to paginated browsing with live updates
disabled. The page SHALL expose a Live control that enables automatic refresh for
the current filter set, and manual pagination, sorting, or filter changes SHALL
pause Live mode.

#### Scenario: Page opens in browsing mode
- **WHEN** a user opens `/observability/flows/attributed`
- **THEN** the page loads a paginated result set
- **AND** incoming flow events do not reset the current page unless Live mode is enabled

#### Scenario: Live mode pauses on manual browsing
- **GIVEN** Live mode is enabled
- **WHEN** the user changes page, sorting, search, or filter state
- **THEN** Live mode is disabled before the manual navigation is applied

### Requirement: Attributed Flow Filters And Summary Cards
Summary cards in the attributed flow explorer SHALL be actionable filters. The
Attributed card SHALL filter to rows with process attribution. Any unmatched/raw
flow card SHALL filter to clearly labeled raw flow candidates without process
attribution, not rows already presented as attributed records.

#### Scenario: Click attributed summary
- **GIVEN** the page shows an Attributed summary count
- **WHEN** the user clicks the Attributed card
- **THEN** the table filters to only flows with process attribution
- **AND** the filtered row count matches the card count for the selected time window

#### Scenario: Click unmatched summary
- **GIVEN** the page exposes unmatched/raw flow count
- **WHEN** the user clicks the unmatched/raw card
- **THEN** the table filters to raw flow candidates with no process attribution
- **AND** the UI labels the mode so it is not confused with attributed records

### Requirement: Attributed Flow Detail Drilldown
Each attributed flow row SHALL provide a detail drilldown showing the NetFlow tuple,
protocol, byte and packet counts, attribution evidence, process metadata, collector
agent, enrichment, and raw payload fields needed for forensics.

#### Scenario: Open row details
- **GIVEN** a user is viewing an attributed flow row
- **WHEN** the user activates the row detail affordance
- **THEN** the UI shows the full flow and attribution context
- **AND** long fields such as cmdline, container ID, and raw payload are available
  without widening the table

### Requirement: Responsive Attributed Flow Table
The attributed flow explorer table SHALL fit within normal desktop and mobile
viewports without requiring horizontal scrolling for the primary workflow.

#### Scenario: Desktop table fits
- **GIVEN** a desktop viewport
- **WHEN** the attributed flow table renders
- **THEN** primary columns fit without horizontal scrolling
- **AND** secondary fields are available through row details

### Requirement: Flow Endpoint Enrichment
The attributed flow explorer SHALL display endpoint enrichment when available,
including reverse-DNS or inventory hostname labels and CTI/IOC match indicators.
Enrichment SHALL come from cached/shared ServiceRadar data paths, not per-render
network lookups.

#### Scenario: Reverse DNS available
- **GIVEN** a flow endpoint has a cached reverse-DNS or inventory hostname
- **WHEN** the row renders
- **THEN** the endpoint shows the label alongside the IP address

#### Scenario: IOC match available
- **GIVEN** a flow endpoint or domain matches imported CTI
- **WHEN** the row or detail view renders
- **THEN** the UI shows an IOC indicator and links to the relevant threat context

### Requirement: Attributed Flow Topbar Title
The observability shell SHALL show "Attributed Flows" as the page title in the
topbar when the user is on `/observability/flows/attributed`.

#### Scenario: Direct route title
- **WHEN** a user opens `/observability/flows/attributed`
- **THEN** the topbar title next to the ServiceRadar logo is "Attributed Flows"
