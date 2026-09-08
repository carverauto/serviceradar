## ADDED Requirements

### Requirement: Dashboard creation is metadata-first
The dashboard creator SHALL create a dashboard identity from metadata before allowing panel composition.

#### Scenario: Create empty dashboard from analytics page
- **GIVEN** an authorized user is on `/analytics`
- **WHEN** they enter title, description, and visibility and save
- **THEN** the system creates a dashboard without requiring a default SRQL query
- **AND** the user is navigated to the saved dashboard.

#### Scenario: Panel controls unavailable before save
- **GIVEN** an authorized user is creating a new dashboard on `/analytics`
- **WHEN** no dashboard identity exists yet
- **THEN** panel add and panel layout controls are not shown as active controls.

### Requirement: Panel authoring is schema-guided
The dashboard panel editor SHALL use SRQL preview output to guide visualization and binding choices.

#### Scenario: Visualization options follow query output
- **GIVEN** a user authors a panel SRQL query
- **WHEN** the query preview succeeds
- **THEN** the available visualization choices are constrained to options compatible with the returned fields and row shape.

#### Scenario: Binding controls use returned fields
- **GIVEN** a query preview returns typed fields
- **WHEN** the user selects a visualization
- **THEN** the editor shows field selectors appropriate for that visualization and field types.

#### Scenario: Invalid visual bindings are unreachable
- **GIVEN** a query preview returns fields that do not satisfy an availability visual
- **WHEN** the user configures the panel
- **THEN** availability is not offered as a selectable visualization
- **AND** the user cannot save a panel that fails with missing numerator or denominator bindings.

### Requirement: Query-first dashboard authoring model
The dashboard builder SHALL treat SRQL source queries as reusable data sources that can produce one or more typed outputs before dashboard layout is configured.

This requirement is tracked as phase 2 of this change. The immediate implementation stabilizes the existing panel editor; tasks 4.1-4.5 cover the new source-query/output/panel model.

#### Scenario: Run source query before choosing outputs
- **GIVEN** a user is authoring a dashboard
- **WHEN** they enter and run a SRQL source query
- **THEN** the builder shows sample rows and typed field metadata before asking for visualization details.

#### Scenario: One source query supports multiple outputs
- **GIVEN** a source query returns fields compatible with more than one visualization intent
- **WHEN** the user adds outputs from the source query
- **THEN** each output can choose its own title, intent, fields, and visualization
- **AND** the SRQL source query is not duplicated for every output.

#### Scenario: Layout is configured after outputs exist
- **GIVEN** a dashboard has one or more outputs
- **WHEN** the user enters layout mode
- **THEN** outputs can be placed, moved, resized, or left unplaced without changing their source query.

#### Scenario: Odd final row does not leave dead space
- **GIVEN** automatic layout or compact layout places a single panel on the final row
- **WHEN** the final-row panel would otherwise leave unused horizontal space
- **THEN** the panel spans the available row width by default
- **AND** the user can still resize it manually in the dashboard canvas.

#### Scenario: Intent drives visualization selection
- **GIVEN** typed source query fields are available
- **WHEN** the user chooses an intent such as single number, list, trend, breakdown, comparison, pivot / cross-tab, or status grid
- **THEN** the builder maps that intent to compatible visualizations and field selectors
- **AND** incompatible fields are excluded from the selectors.

### Requirement: Panel settings avoid raw JSON editing
Dashboard panel settings SHALL expose structured controls for common binding, display, visual, and layout options instead of requiring raw JSON editing.

#### Scenario: Edit panel without JSON textareas
- **GIVEN** a user opens dashboard panel settings
- **WHEN** the panel editor is displayed
- **THEN** the user can configure dataset, SRQL, visualization, field bindings, display labels, units, and layout through typed controls
- **AND** raw `data_binding`, `display_config`, `visual_config`, and `layout` JSON textareas are not shown.

### Requirement: Rendered panel controls are interactive
Rendered dashboard panel controls SHALL be clickable and keyboard accessible.

#### Scenario: Table panel control works
- **GIVEN** a dashboard table panel is rendered
- **WHEN** the user opens a panel or table control
- **THEN** the control opens and can be interacted with without being blocked by the table layout.

### Requirement: Rendered panels expose action menus
Rendered dashboard panels SHALL expose common actions through an ellipsis menu instead of burning horizontal space with always-visible icon buttons.

#### Scenario: Open panel actions
- **GIVEN** a dashboard panel is rendered
- **WHEN** the user opens the panel ellipsis menu
- **THEN** refresh, view SRQL, edit, duplicate, delete, and export actions are available when permitted
- **AND** the menu remains clickable without being clipped by the panel container.

### Requirement: Gauge dashlets support configurable lookback comparison
Gauge and availability dashlets SHALL support a user-configurable comparison lookback so operators can see whether the metric moved up or down relative to a prior period.

#### Scenario: Configure gauge lookback
- **GIVEN** a user is composing a gauge or availability panel
- **WHEN** they enable comparison and choose a lookback such as 7 or 30 days
- **THEN** the panel stores the lookback configuration with the visual settings
- **AND** the rendered dashlet labels the comparison period using operator-facing copy.

#### Scenario: Render gauge comparison
- **GIVEN** a gauge panel has comparison trend data from an SRQL `stats:` or `bucket:` query
- **WHEN** the panel renders
- **THEN** it shows the current gauge value, numerator/denominator context, a directional trend indicator, and copy such as "Compared to 30 days ago"
- **AND** raw implementation labels such as "numerator" and "denominator" are not shown.
