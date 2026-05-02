## ADDED Requirements

### Requirement: Dashboard package map selection

The dashboard SHALL allow users to choose between the existing NetFlow map and enabled location-aware dashboard package map views without compiling customer-specific map UI into web-ng.

#### Scenario: User opens an enabled dashboard map package
- **GIVEN** a verified dashboard package has been enabled with dashboard placement
- **WHEN** a user selects that package from the dashboard map/package control
- **THEN** the dashboard SHALL navigate to or preview the package through the dashboard renderer host
- **AND** the package SHALL render from approved SRQL data frames instead of browser-loaded CSV files

#### Scenario: No dashboard map packages are enabled
- **GIVEN** no verified dashboard packages are enabled for dashboard placement
- **WHEN** the dashboard renders
- **THEN** the product SHALL show the built-in NetFlow map option only
- **AND** it SHALL NOT show a hardcoded WiFi map route, hook, or selector option

### Requirement: Full-screen dashboard package map

The system SHALL provide full-screen dashboard package views where approved packages can render compatible coordinate-bearing SRQL results as map views.

#### Scenario: User opens custom map from dashboard
- **GIVEN** the dashboard exposes an enabled map dashboard package
- **WHEN** a user opens the full-screen map action
- **THEN** the application SHALL navigate to the package route under `/dashboards/:route_slug`
- **AND** the view SHALL initialize with the package's approved data frames and validated settings

#### Scenario: User builds a new map query
- **GIVEN** a user is on a full-screen dashboard package map that exposes query editing
- **WHEN** they use the SRQL builder to query `in:wifi_sites region:AM-East`
- **THEN** the map SHALL refresh from SRQL results
- **AND** a synchronized result table SHALL show the returned site rows
- **AND** unsupported non-map result sets SHALL show a clear non-mappable result state instead of failing

### Requirement: ServiceRadar-owned map basemap provider

ServiceRadar map views SHALL use ServiceRadar-owned basemap configuration rather than plugin-owned tile URLs or credentials.

#### Scenario: Mapbox settings are configured
- **GIVEN** deployment-level Mapbox settings are enabled with an access token and style URLs
- **WHEN** the dashboard or full-screen network asset map renders
- **THEN** deck.gl SHALL render the map over the configured Mapbox basemap style
- **AND** data collection plugin payloads SHALL NOT provide Mapbox tokens, tile URLs, or executable map code

#### Scenario: Mapbox settings are not configured
- **GIVEN** Mapbox settings are disabled or missing a usable token
- **WHEN** a user opens a map view
- **THEN** the UI SHALL render a clear basemap configuration state or a bounded ServiceRadar-supported fallback
- **AND** it SHALL NOT silently use third-party tile providers that require terms, API keys, or attribution not configured by an administrator

#### Scenario: Admin manages basemap settings
- **GIVEN** an authenticated admin is in settings
- **WHEN** they configure Mapbox token/style settings for map experiences
- **THEN** those settings SHALL apply to both dashboard and full-screen map views
- **AND** OpenStreetMap or other tile providers SHALL only be added through explicit ServiceRadar product settings if selected later

### Requirement: Network map saved view settings

Administrators SHALL be able to configure the dashboard network asset map query and manage named map views from settings.

#### Scenario: Admin configures a dashboard package map query
- **GIVEN** an authenticated admin is in the settings UI
- **WHEN** they save a default WiFi map query such as `in:wifi_sites ap_count:>0 sort:ap_count:desc`
- **THEN** the query SHALL be validated by SRQL before persistence
- **AND** the enabled dashboard package instance SHALL use that query on subsequent loads

#### Scenario: Admin saves a named map view
- **GIVEN** an authenticated admin has built a map-compatible SRQL query
- **WHEN** they save it as a named view
- **THEN** the view SHALL be available to approved dashboard package instances that request saved map views
- **AND** the saved view SHALL include SRQL query text and server-owned visualization options only

### Requirement: Customer WiFi dashboard package POC parity interactions

The United WiFi dashboard package SHALL provide the core interactions present in the standalone proof of concept through the ServiceRadar dashboard package host.

#### Scenario: User filters WiFi sites
- **GIVEN** WiFi site map data includes regions, AP model families, WLC models, AOS versions, and RADIUS clusters
- **WHEN** a user applies one or more map filters
- **THEN** the visible markers and result table SHALL update consistently
- **AND** filter state SHALL remain reflected in the SRQL query or view state

#### Scenario: User inspects a site popup
- **GIVEN** a user selects a WiFi site marker
- **WHEN** the site detail popup opens
- **THEN** it SHALL display site type, region, AP counts, up/down counts, AP model breakdown, WLC summaries, AOS versions, CPPM cluster, server group, AAA profile, and coordinates when available
- **AND** AP and WLC detail lists SHALL be loaded through SRQL rather than embedded static CSV payloads

#### Scenario: User expands popup detail lists
- **GIVEN** a WiFi site popup includes up AP count, down AP count, or WLC count
- **WHEN** the user activates one of those counts
- **THEN** the popup or detail panel SHALL load the corresponding AP or WLC rows through SRQL
- **AND** it SHALL preserve the selected site context without requiring a browser-side CSV search index

#### Scenario: User searches device attributes
- **GIVEN** WiFi AP and WLC rows have been ingested and linked to sites
- **WHEN** a user searches by hostname, MAC, serial, IP, site code, or site name
- **THEN** the map, sidebar list, and result table SHALL show matching sites and devices
- **AND** selecting a device result SHALL focus the related map feature and expose the device detail context

#### Scenario: Map shows freshness and migration trends
- **GIVEN** WiFi-map batch metadata and fleet history rows have been ingested
- **WHEN** the WiFi map renders
- **THEN** the UI SHALL show data freshness based on the latest collection timestamp
- **AND** it SHALL show migration trend metrics from `wifi_fleet_history` when at least two snapshots are available

#### Scenario: Dashboard map opens full-screen view
- **GIVEN** the dashboard exposes the customer WiFi dashboard package
- **WHEN** a user activates the map card open action
- **THEN** the package route SHALL open with the same query, filters, and selected view context where possible

### Requirement: Dashboard package import and hosting

The UI SHALL allow authorized administrators to import signed dashboard packages and enable them as custom dashboard views without rebuilding web-ng.

#### Scenario: Admin imports dashboard package manifest
- **GIVEN** a customer-owned source exposes a dashboard package JSON manifest with a signed renderer artifact
- **WHEN** an authorized administrator imports the package
- **THEN** the UI SHALL show package identity, version, vendor, source provenance, requested capabilities, required SRQL data frames, and verification state
- **AND** the package SHALL remain disabled until verification succeeds and the administrator enables it

#### Scenario: Admin enables a custom dashboard package
- **GIVEN** a verified dashboard package defines settings schema and default SRQL data frames
- **WHEN** an authorized administrator enables it
- **THEN** the UI SHALL persist approved settings and make the dashboard available from the configured dashboard location
- **AND** the custom dashboard SHALL render through the ServiceRadar dashboard host rather than product-specific compiled routes

### Requirement: Browser dashboard renderer host

The dashboard SHALL host signed browser-side renderers for custom dashboards while keeping authentication, authorization, theming, SRQL execution, and navigation under ServiceRadar control.

#### Scenario: Versioned host interface is enforced
- **GIVEN** a dashboard package declares a browser renderer interface version
- **WHEN** the dashboard host loads the package
- **THEN** it SHALL allow only explicitly supported interface versions such as `dashboard-browser-module-v1` and `dashboard-wasm-v1`
- **AND** unsupported or missing interface versions SHALL fail with a product-native diagnostic instead of executing the renderer

#### Scenario: React browser-module renderer receives SRQL data frames
- **GIVEN** an enabled dashboard package declares SRQL data frames and a React browser-module renderer
- **WHEN** a user opens that dashboard
- **THEN** web-ng SHALL execute the approved SRQL queries server-side
- **AND** it SHALL pass validated settings and data frames to the renderer through the versioned dashboard host API
- **AND** the renderer SHALL NOT receive database credentials, API tokens, repository credentials, or unrestricted network access

#### Scenario: React renderer updates SRQL filters
- **GIVEN** an enabled React dashboard renderer uses the ServiceRadar dashboard SDK
- **WHEN** a user clicks a map cluster, selects a sidebar filter, changes search text, or resets the view
- **THEN** the renderer SHALL update the active SRQL query through the host API rather than filtering only in browser memory
- **AND** web-ng SHALL rerun approved SRQL frames server-side and deliver refreshed rows without remounting the entire dashboard when the renderer artifact is unchanged

#### Scenario: Custom renderer emits a deck.gl render model
- **GIVEN** a dashboard WASM renderer emits a `deck_map` render model through the dashboard host API
- **WHEN** the host accepts the model
- **THEN** ServiceRadar-owned JavaScript SHALL render the declared deck.gl layers over the configured basemap
- **AND** custom interactions SHALL be limited to approved host actions such as native popups, details navigation, and saved view updates

#### Scenario: React renderer owns custom map interactions
- **GIVEN** a trusted React browser-module renderer is approved for map and navigation capabilities
- **WHEN** it renders custom deck.gl/Mapbox layers, popups, clusters, or detail panels
- **THEN** those interactions SHALL run inside the ServiceRadar-owned dashboard host container
- **AND** device detail navigation SHALL use host-approved navigation helpers or same-origin ServiceRadar routes

#### Scenario: Renderer asset is served from ServiceRadar package storage
- **GIVEN** a dashboard package was imported from a customer-owned repository
- **WHEN** a user opens the dashboard
- **THEN** the browser SHALL fetch the renderer from an authenticated ServiceRadar asset URL backed by verified package storage
- **AND** it SHALL NOT fetch renderer code, JSON, WASM, or credentials directly from the customer repository

#### Scenario: Custom renderer fails
- **GIVEN** a dashboard renderer throws, traps, times out, requests an unapproved capability, or receives a non-mappable result set
- **WHEN** the dashboard host detects the failure
- **THEN** the UI SHALL show a bounded product-native failure state with diagnostics for authorized users
- **AND** the failure SHALL NOT break the surrounding ServiceRadar shell, navigation, or other dashboard cards
