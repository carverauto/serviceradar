## ADDED Requirements

### Requirement: Human dashboard identifiers
Authored dashboards SHALL expose a unique short numeric dashboard reference for user-facing URLs, links, search results, and dashboard hub rows instead of exposing raw UUID identifiers.

#### Scenario: Dashboard route uses numeric reference
- **GIVEN** a saved authored dashboard has numeric reference `4821937`
- **WHEN** an authorized user opens `/dashboard/4821937`
- **THEN** the system SHALL resolve and render that dashboard
- **AND** the page, copy-link actions, and dashboard hub SHALL show `4821937` as the dashboard reference.

#### Scenario: Numeric reference is generated uniquely
- **GIVEN** a user creates an authored dashboard
- **WHEN** the dashboard is persisted
- **THEN** the system SHALL assign a 7-digit numeric reference
- **AND** the create flow SHALL retry or fail safely if a generated reference conflicts with an existing dashboard.

### Requirement: Optional unique dashboard slugs
Authored dashboards SHALL allow users with edit access to configure an optional unique slug that can be used as an alternate dashboard route reference.

#### Scenario: User saves an available slug
- **GIVEN** a dashboard has numeric reference `4821937`
- **WHEN** an authorized editor sets slug `zza-availability`
- **THEN** `/dashboard/zza-availability` SHALL resolve to that dashboard
- **AND** `/dashboard/4821937` SHALL continue to resolve to the same dashboard.

#### Scenario: Duplicate slug is rejected
- **GIVEN** another dashboard already uses slug `zza-availability`
- **WHEN** a user attempts to save `ZZA-Availability` as a slug
- **THEN** the system SHALL reject the change as a duplicate
- **AND** it SHALL keep the previous slug unchanged.

#### Scenario: Reserved slug is rejected
- **GIVEN** a user edits dashboard settings
- **WHEN** they choose a slug that conflicts with a reserved dashboard route word
- **THEN** the system SHALL reject the slug with a validation message.

### Requirement: Dashboard authoring reuses SRQL query builder
The dashboard creator SHALL use the existing SRQL query builder implementation for dashboard dataset and panel query authoring rather than introducing a separate query builder.

#### Scenario: User builds a dataset query
- **GIVEN** a user is editing a dashboard dataset
- **WHEN** they add SRQL filters through the builder controls
- **THEN** the dashboard editor SHALL generate the SRQL query using the shared SRQL builder logic
- **AND** preview SHALL run against the generated query.

#### Scenario: Unsupported raw SRQL remains editable
- **GIVEN** a saved dashboard query contains SRQL that cannot be represented by the builder
- **WHEN** the user opens the query editor
- **THEN** the editor SHALL show the raw query without overwriting it
- **AND** the builder SHALL indicate that the query is not fully synchronized.

### Requirement: Multiple SRQL datasets per dashboard
Authored dashboards SHALL support multiple named SRQL datasets that can be referenced by one or more visualizations.

#### Scenario: Dashboard compares site availability
- **GIVEN** a user wants panels for sites ZZA, MSP, and LAX
- **WHEN** they create three datasets with separate SRQL queries for each site tag
- **THEN** the dashboard SHALL persist each dataset independently
- **AND** visualizations SHALL be able to bind to the intended dataset.

#### Scenario: Multiple visuals reuse one dataset
- **GIVEN** a dashboard dataset returns service availability rows
- **WHEN** a user creates both a table and a gauge from that dataset
- **THEN** each visualization SHALL reference the same dataset key
- **AND** each visualization SHALL keep its own binding and display configuration.

### Requirement: Visualization output bindings
Each authored dashboard visualization SHALL declare which dataset output fields, JSON paths, and aggregation semantics drive the visual instead of relying on implicit first-field or raw-row behavior.

#### Scenario: Gauge binds to availability fields
- **GIVEN** a dataset returns fields `available`, `unavailable`, and `total`
- **WHEN** a user configures an availability gauge
- **THEN** the visual SHALL store explicit bindings for numerator, denominator, and label fields
- **AND** the renderer SHALL compute the gauge from those bindings.

#### Scenario: Binding validation catches missing fields
- **GIVEN** a visualization is bound to field `availability_pct`
- **WHEN** the dataset preview no longer returns `availability_pct`
- **THEN** the editor SHALL mark the binding invalid
- **AND** the dashboard SHALL show an actionable configuration error instead of rendering misleading data.

### Requirement: Rich table column renderers
Table visualizations SHALL render configured columns with explicit renderer types and SHALL NOT dump object or JSON values inline by default.

#### Scenario: JSON details field is summarized
- **GIVEN** a table dataset includes a `details` field containing an object or JSON document
- **WHEN** the table renders without an explicit JSON path binding
- **THEN** the table SHALL show a concise summary or expandable details control
- **AND** it SHALL NOT print raw JSON directly in the cell.

#### Scenario: Boolean field uses icon renderer
- **GIVEN** a table column is configured as a boolean icon renderer
- **WHEN** a row contains `true` or `false`
- **THEN** the table SHALL render an appropriate icon or badge
- **AND** it SHALL preserve accessible text for screen readers.

#### Scenario: Sparkline column uses time-series samples
- **GIVEN** a table column is configured as a sparkline renderer
- **WHEN** the bound field contains numeric samples or a compatible nested series
- **THEN** the table SHALL render a compact inline trend visual instead of raw sample JSON.

### Requirement: Visualization layout and labels
Authored dashboard visualizations SHALL provide structured controls for panel placement, sizing, labels, captions, units, thresholds, legends, and empty-state text.

#### Scenario: User positions a visualization
- **GIVEN** a dashboard has multiple visualizations
- **WHEN** an editor changes a panel's position and size
- **THEN** the dashboard SHALL persist the layout
- **AND** the show route SHALL render the visualization in the configured responsive position.

#### Scenario: User configures visual labels
- **GIVEN** a gauge visual is bound to availability data
- **WHEN** the editor sets label `ZZA availability` and unit `%`
- **THEN** the rendered visual SHALL display the configured label and unit
- **AND** reports SHALL use the same label metadata.

### Requirement: Dashboard hub default service dashboard
The `/dashboards` hub SHALL use the SDK-built `service-availability-noc` dashboard package as the system default dashboard when it is enabled and the current user has not selected another default.

#### Scenario: User opens dashboards hub with no personal default
- **GIVEN** the `service-availability-noc` dashboard package route is enabled
- **AND** the current user has not selected a personal default dashboard
- **WHEN** the user opens `/dashboards`
- **THEN** the hub SHALL present the service availability dashboard as the default action
- **AND** the user SHALL be able to open `/dashboards/service-availability-noc`.

#### Scenario: Default package is missing
- **GIVEN** the `service-availability-noc` package route is not enabled or cannot be loaded
- **WHEN** an authorized user opens `/dashboards`
- **THEN** the hub SHALL still list other accessible dashboards
- **AND** admins SHALL see an actionable diagnostic that the system default dashboard package is missing.

### Requirement: Dashboard hub discovery and switching
The `/dashboards` hub SHALL list dashboards available to the current user, including authored dashboards they own, authored dashboards shared with them, and enabled dashboard package routes, and SHALL let the user switch among them.

#### Scenario: User sees accessible dashboards
- **GIVEN** a user owns one authored dashboard and has access to one dashboard package
- **WHEN** they open `/dashboards`
- **THEN** both dashboards SHALL be listed with type labels, descriptions, and stable links
- **AND** the user SHALL be able to open either dashboard from the hub.

#### Scenario: User filters dashboards with SRQL
- **GIVEN** the user is viewing `/dashboards`
- **WHEN** they run `in:dashboards title:%availability%`
- **THEN** the hub SHALL show only accessible dashboards matching the SRQL query
- **AND** package dashboards and authored dashboards SHALL use the same search results contract.

### Requirement: Dashboard hub shell context
The `/dashboards` route SHALL present the dashboard workspace context in the application shell and expose SRQL search in the top navigation.

#### Scenario: Dashboard hub shell title
- **WHEN** a user opens `/dashboards`
- **THEN** the shell label next to the ServiceRadar logo SHALL read "Dashboards"
- **AND** it SHALL NOT show the generic "ServiceRadar" workspace label for that route.

#### Scenario: Dashboard hub top SRQL bar
- **WHEN** a user opens `/dashboards`
- **THEN** the top navigation SHALL include the SRQL input bar
- **AND** its default query context SHALL target `in:dashboards`.
