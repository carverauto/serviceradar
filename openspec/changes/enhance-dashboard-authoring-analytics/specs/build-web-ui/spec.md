## ADDED Requirements

### Requirement: Multi-query dashboard creation
The dashboard creator SHALL let an authorized user compose a new dashboard from multiple named SRQL-backed panels before saving the dashboard.

#### Scenario: User creates a dashboard with multiple queries
- **GIVEN** an authorized dashboard editor is creating a dashboard
- **WHEN** they add panels for `ZZA`, `MSP`, and `LAX`, each with a separate SRQL query
- **THEN** the creator SHALL show all pending panels before save
- **AND** the saved dashboard SHALL persist each panel and query independently.

#### Scenario: User previews each pending panel
- **GIVEN** a new dashboard has multiple pending panels
- **WHEN** the user previews one panel
- **THEN** the preview SHALL run only that panel's SRQL query
- **AND** compatible visualization and field-binding metadata SHALL update for that panel.

### Requirement: Gauge and count dashlets
Dashboard authoring SHALL provide first-class gauge and count dashlets with explicit output bindings, labels, units, thresholds, and optional trend-over-time context.

#### Scenario: Gauge dashlet renders bound progress
- **GIVEN** a panel query returns `available` and `total`
- **WHEN** the editor creates a gauge dashlet bound to those fields
- **THEN** the dashboard SHALL render a gauge using the configured numerator, denominator, label, unit, and thresholds.

#### Scenario: Count dashlet shows trend over time
- **GIVEN** a count dashlet has a current-value query and a historical comparison query or time window
- **WHEN** the dashboard renders the dashlet
- **THEN** it SHALL show the current value and a clearly labeled trend or delta over time.

### Requirement: Pivot table visualization
Dashboard authoring SHALL provide a pivot table visualization that groups SRQL result rows by configured row and column dimensions and aggregates configured value fields.

#### Scenario: User builds a pivot table
- **GIVEN** a dataset returns rows with `site`, `status`, and `device_count`
- **WHEN** the editor configures `site` as rows, `status` as columns, and `sum(device_count)` as values
- **THEN** the dashboard SHALL render a pivot table with one row per site and one column per status.

#### Scenario: Pivot table handles sparse values
- **GIVEN** some row/column combinations have no matching SRQL rows
- **WHEN** the pivot table renders
- **THEN** it SHALL display the configured empty-cell value
- **AND** totals/subtotals SHALL remain correct.

### Requirement: Dashboard package SRQL search separation
Dashboard package pages SHALL keep the global topbar SRQL controls scoped to dashboard catalog search and SHALL keep package frame queries inside the dashboard host data API.

#### Scenario: Package dashboard query builder opens as dashboard search
- **GIVEN** a user is viewing `/dashboards/service-availability-noc`
- **WHEN** they open the topbar SRQL query builder
- **THEN** the builder SHALL target `in:dashboards`
- **AND** it SHALL NOT warn that a package frame query cannot be represented by the builder.

#### Scenario: Dashboard frame query does not overwrite catalog search
- **GIVEN** a package dashboard updates an internal frame query
- **WHEN** the update is pushed through the dashboard host API
- **THEN** the global topbar search input SHALL continue to represent dashboard catalog search
- **AND** the frame query SHALL remain available to the package through frame query overrides.
