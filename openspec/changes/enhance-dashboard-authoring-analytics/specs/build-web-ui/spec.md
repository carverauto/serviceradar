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

### Requirement: Authored dashboard viewer actions
The authored dashboard viewer SHALL expose panel-level actions for authorized users to refresh data, inspect SRQL, edit panel settings, duplicate a panel, clone a panel to another dashboard, and export visible rows as CSV.

#### Scenario: User duplicates a dashboard panel
- **GIVEN** an authorized dashboard editor is viewing a dashboard panel
- **WHEN** they choose duplicate
- **THEN** the dashboard SHALL create a new panel with the same SRQL, bindings, visual configuration, and layout adjusted to the next available position.

#### Scenario: User clones a panel to another dashboard
- **GIVEN** an authorized dashboard editor can edit a source panel and a target dashboard
- **WHEN** they clone the panel to the target dashboard
- **THEN** the target dashboard SHALL receive an independent panel copy.

### Requirement: Dashboard variables
Authored dashboards SHALL support dashboard-scoped variable controls whose selected values are substituted into panel SRQL before execution.

#### Scenario: User changes a dashboard variable
- **GIVEN** a dashboard defines a `site` variable and a panel query contains `${site}`
- **WHEN** the user selects `MSP`
- **THEN** the panel query SHALL execute with `MSP` substituted for `${site}`
- **AND** the rendered dashboard SHALL refresh using the selected value.

### Requirement: Saved dashboard layout utilities
The authored dashboard viewer SHALL expose grid layout utilities for authorized editors, including compacting panels to remove gaps and showing refresh interval metadata in panel headers.

#### Scenario: User compacts a dashboard layout
- **GIVEN** a saved dashboard has panels with gaps in their grid positions
- **WHEN** an authorized editor chooses compact layout
- **THEN** the panel layouts SHALL be updated to remove gaps while preserving each panel width and height where possible.

### Requirement: Advanced dashboard inspector
The dashboard creator SHALL provide an inspector that supports SRQL editing assistance, automatic preview, inline validation errors, structured visualization bindings, and comparison-window trend configuration.

#### Scenario: User edits a panel query
- **GIVEN** an authorized dashboard editor has selected a pending panel
- **WHEN** they change the panel SRQL or visualization binding controls
- **THEN** the inspector SHALL debounce preview execution
- **AND** show any validation error inline with the selected panel instead of only relying on page flash messages.

#### Scenario: User configures visualization bindings
- **GIVEN** a panel preview returns named fields
- **WHEN** the user selects gauge, count, pivot, or chart visualizations
- **THEN** the inspector SHALL expose structured controls for the fields relevant to that visualization
- **AND** persist those bindings into the saved panel configuration.

### Requirement: Dashboard authoring continuity
The dashboard creator SHALL preserve in-progress dashboard drafts across page reloads and avoid shipping unnecessary preview payloads on every canvas update.

#### Scenario: User reloads with an unsaved dashboard draft
- **GIVEN** a user has an unsaved dashboard with pending panels
- **WHEN** they reload the dashboard creator
- **THEN** the creator SHALL restore the draft metadata and pending panels for that user and browser.

### Requirement: Dashboard export and group management
Authored dashboards SHALL provide authenticated streaming CSV export for panel rows and SHALL manage reusable user groups outside of the dashboard creator page.

#### Scenario: User exports a panel
- **GIVEN** a user can view an authored dashboard panel
- **WHEN** they request CSV export for that panel
- **THEN** the system SHALL stream CSV content from an authenticated route.

#### Scenario: User manages dashboard sharing groups
- **GIVEN** a user has permission to view or manage sharing principals
- **WHEN** they open the user group settings route
- **THEN** they SHALL see reusable groups and memberships outside the dashboard creator workflow.
