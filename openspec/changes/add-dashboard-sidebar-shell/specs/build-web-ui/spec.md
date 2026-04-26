## ADDED Requirements

### Requirement: Shared Sidebar Application Shell
The web-ng UI SHALL provide a reusable authenticated sidebar application shell for primary app routes. The shell MUST include persistent navigation, active route state, account controls, collapse behavior, responsive behavior for narrow viewports, and SRQL query/builder affordances for SRQL-backed pages while keeping the navigation model defined in one project-owned place.

#### Scenario: Dashboard renders inside the shell
- **GIVEN** an authenticated operator can access the dashboard route
- **WHEN** the dashboard page renders
- **THEN** the page is framed by the shared sidebar shell
- **AND** the dashboard navigation item is marked active

#### Scenario: Shell collapses without losing navigation
- **GIVEN** an authenticated operator is viewing a shell-backed route
- **WHEN** the sidebar is collapsed or the viewport becomes narrow
- **THEN** primary navigation remains available through the responsive shell controls
- **AND** page content does not overlap the shell controls

#### Scenario: Navigation model is not duplicated per page
- **WHEN** developers add or update a primary navigation item
- **THEN** the change is made in the shared shell/navigation model
- **AND** shell-backed routes consume the same navigation definition

#### Scenario: Authenticated routes use the same shell
- **GIVEN** an authenticated operator opens a primary app route such as devices, topology, events, flows, cameras, observability, diagnostics, or settings
- **WHEN** the route renders
- **THEN** the page is framed by the shared sidebar shell
- **AND** the active sidebar item reflects the current route family

#### Scenario: SRQL pages retain query controls
- **GIVEN** an authenticated SRQL-backed route enables the SRQL query bar or builder
- **WHEN** the route renders inside the shared sidebar shell
- **THEN** the query bar and builder remain available above the route content
- **AND** the shell does not remove route-specific SRQL state

### Requirement: Operations Dashboard Surface
The web-ng UI SHALL provide a dashboard surface for authenticated operators that combines operational KPI cards, asset posture cards, a network traffic map, security event trends, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset cards, and a SIEM alert feed region in a dense scannable layout.

#### Scenario: Operator opens the dashboard
- **GIVEN** an authenticated operator has dashboard access
- **WHEN** they navigate to the dashboard route
- **THEN** the UI displays operational KPI cards, asset posture cards, the network traffic map, security event trends, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset cards, and a SIEM alert feed region
- **AND** all regions fit without incoherent overlap at supported desktop and mobile viewport widths

#### Scenario: Available metrics populate dashboard cards
- **GIVEN** health, inventory, or NetFlow summary data is available from existing ServiceRadar sources
- **WHEN** the dashboard loads
- **THEN** cards backed by those sources display current values for the selected time window
- **AND** each displayed value is labeled with its source context or time window

#### Scenario: Optional operational panels render honest unavailable states
- **GIVEN** camera fleet, Wi-Fi survey, or FieldSurvey data is not available in the deployment
- **WHEN** the dashboard renders the corresponding operational panel
- **THEN** the panel shows an explicit unavailable or empty state
- **AND** the UI does not display fabricated camera, Wi-Fi, or survey values

#### Scenario: Dashboard opens available camera previews
- **GIVEN** relay-capable camera sources with stream profiles and assigned agents exist
- **WHEN** the authenticated dashboard LiveView connects
- **THEN** the camera operations panel starts bounded relay-backed previews from existing camera inventory
- **AND** unavailable or failed relays show explicit status instead of fake video

#### Scenario: Dashboard widgets drill into detail pages
- **GIVEN** an authenticated operator is viewing the dashboard
- **WHEN** they click an events trend, alert row, camera preview, or camera tile
- **THEN** the UI navigates to the corresponding events, alerts, or camera detail route
- **AND** the destination page provides a more detailed view backed by the existing data source

### Requirement: Adaptive Dashboard Composition
The dashboard SHALL compose operational panels from available ServiceRadar capability signals, including configured collector packages, persisted records, materialized service checks, and plugin outputs. Optional collectors or feeds that are not configured SHALL render as not configured or omitted/disabled states rather than blank broken widgets.

#### Scenario: NetFlow is not configured
- **GIVEN** no NetFlow, IPFIX, or sFlow collector package and no recent observed flow records exist
- **WHEN** an operator opens the dashboard
- **THEN** the network traffic panel identifies NetFlow/IPFIX as not configured
- **AND** the map does not show synthetic traffic animation

#### Scenario: Collector configured but no recent records
- **GIVEN** a collector package exists for a dashboard capability
- **AND** no recent records for that capability are available in the selected time window
- **WHEN** the dashboard loads
- **THEN** the corresponding panel distinguishes configured-without-data from not-configured
- **AND** the panel provides source status context instead of an empty broken widget

#### Scenario: Camera plugin service checks expose camera inventory
- **GIVEN** recent plugin service checks report camera-oriented summaries such as camera and stream counts
- **WHEN** the dashboard builds the camera operations panel
- **THEN** the panel may use those plugin results as camera availability signals
- **AND** first-class camera inventory remains available for mapped relay-capable camera sources

### Requirement: Camera Operations Multiview
The web-ng UI SHALL provide a camera-first operations route that displays live relay-backed camera feeds from existing camera inventory. The route SHALL support selectable viewport counts of 2, 4, 8, 16, and 32 and SHALL show clear unavailable states for empty or failed viewports.

#### Scenario: Operator opens camera multiview
- **GIVEN** an authenticated operator has device view permission
- **WHEN** they navigate to the Cameras route
- **THEN** the page displays a camera-focused multiview layout
- **AND** the default view attempts to open bounded relay-backed streams from available camera sources

#### Scenario: Operator changes viewport count
- **GIVEN** the camera multiview route is open
- **WHEN** the operator selects a 2, 4, 8, 16, or 32 viewport layout
- **THEN** the page updates the visible camera viewport count
- **AND** each unavailable viewport explains that no relay-capable camera is selected or available

#### Scenario: Camera navigation does not land on diagnostics
- **GIVEN** an authenticated operator uses the primary sidebar Cameras item
- **WHEN** they activate that navigation item
- **THEN** they land on the camera multiview route
- **AND** relay diagnostics remain available through observability-specific routes rather than as the primary camera destination

#### Scenario: Operator opens one camera feed
- **GIVEN** a dashboard camera preview or camera tile references a camera source
- **WHEN** the operator opens that camera
- **THEN** the UI navigates under `/cameras/`
- **AND** the camera detail route attempts to open that camera source's relay-backed stream

### Requirement: Dashboard Network Traffic Map
The dashboard SHALL render a deck.gl/luma network topology/traffic map based on observed NetFlow/IPFIX summaries and SHALL support an animated MTR diagnostic overlay. The widget SHALL also provide a separate NetFlow map view that maps flow data geographically without topology overlays. The dashboard MUST NOT animate fake traffic when observed flow data is unavailable.

#### Scenario: Observed flows render as traffic animation
- **GIVEN** observed NetFlow/IPFIX summaries exist for the selected time window
- **WHEN** the dashboard topology/traffic view renders
- **THEN** deck.gl/luma layers display directional traffic using those observed summaries in the context of topology-oriented coordinates
- **AND** visual intensity is derived from bounded flow metrics such as bytes, packets, flow count, or rate

#### Scenario: Operator switches to NetFlow map
- **GIVEN** observed NetFlow/IPFIX summaries have GeoIP coordinates available
- **WHEN** the operator selects the NetFlow map view from the widget control
- **THEN** the map renders flow arcs and endpoints from NetFlow GeoIP coordinates
- **AND** topology nodes, topology links, and MTR diagnostic overlays are not shown in that NetFlow-only view

#### Scenario: No observed flows avoids fake animation
- **GIVEN** no observed flow summaries exist for the selected time window
- **WHEN** the dashboard traffic map renders
- **THEN** the map shows an empty or unavailable state
- **AND** it does not synthesize animated traffic arcs or packet movement

#### Scenario: MTR overlay animates diagnostic evidence
- **GIVEN** recent MTR diagnostic summaries exist for paths visible on the dashboard map
- **WHEN** the MTR overlay is enabled
- **THEN** deck.gl/luma layers animate diagnostic path evidence
- **AND** latency, loss, or route-change state is visually distinguishable from NetFlow traffic animation

#### Scenario: SNMP interface telemetry enriches topology edges
- **GIVEN** topology edges include interface telemetry such as current rate, directional rate, capacity, interface names, or telemetry source
- **WHEN** the dashboard topology/traffic view renders
- **THEN** edge width, packet animation, and hover details use the observed interface telemetry where available
- **AND** the UI does not synthesize rates, capacities, utilization, or history when no interface telemetry exists

#### Scenario: Topology inspection exposes interface trend context
- **GIVEN** historical SNMP interface metric timeseries exists for a device or topology edge
- **WHEN** an operator hovers, focuses, or selects the corresponding node or edge in the dashboard map or GodView topology
- **THEN** the inspector may display a compact sparkline and current interface summary for the selected interface context
- **AND** when historical timeseries is unavailable the inspector shows current telemetry only, not a fabricated trend

### Requirement: Dashboard Security Feed Placeholders
The dashboard SHALL include vulnerable asset and SIEM alert regions as explicit placeholder surfaces until follow-up OpenSpec proposals define real vulnerability tracking and SIEM feed ingestion behavior.

#### Scenario: Vulnerable asset feed is not implemented
- **GIVEN** no approved vulnerable asset tracking capability exists
- **WHEN** the dashboard renders vulnerable asset cards
- **THEN** the cards present an explicit unconnected or empty state
- **AND** the UI does not display fabricated vulnerable asset counts

#### Scenario: SIEM alert feed is not implemented
- **GIVEN** no approved SIEM alert ingestion capability exists
- **WHEN** the dashboard renders the SIEM alert feed region
- **THEN** the region presents an explicit unconnected or empty state
- **AND** the UI does not display fabricated alerts
