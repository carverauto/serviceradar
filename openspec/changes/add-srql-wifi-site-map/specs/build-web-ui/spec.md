## ADDED Requirements

### Requirement: Dashboard map mode selection

The dashboard SHALL allow users to choose between the existing NetFlow map and a location-aware network asset map without removing either view.

#### Scenario: User switches dashboard map to network assets
- **GIVEN** WiFi-map data has been ingested
- **WHEN** a user selects `Network Asset Map` from the dashboard map mode control
- **THEN** the dashboard map card SHALL render network asset markers from the configured default map SRQL query
- **AND** the selected mode SHALL persist according to the existing dashboard preference pattern

#### Scenario: Network asset map has no mappable data
- **GIVEN** the default network asset map query returns no rows with valid coordinates
- **WHEN** the dashboard renders the network asset map card
- **THEN** it SHALL show an empty state that identifies the configured SRQL query and explains that mappable rows require coordinates

### Requirement: Full-screen SRQL-driven network asset map

The system SHALL provide a full-screen network asset map view where users can edit SRQL queries and render compatible coordinate-bearing results as map views.

#### Scenario: User opens network asset map from dashboard
- **GIVEN** the dashboard is showing the network asset map card
- **WHEN** a user opens the full-screen map action
- **THEN** the application SHALL navigate to the full-screen network asset map view
- **AND** the view SHALL initialize with the same SRQL query used by the dashboard card

#### Scenario: User builds a new map query
- **GIVEN** a user is on the full-screen network asset map view
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

#### Scenario: Admin saves the default dashboard map query
- **GIVEN** an authenticated admin is in the settings UI
- **WHEN** they save a default WiFi map query such as `in:wifi_sites ap_count:>0 sort:ap_count:desc`
- **THEN** the query SHALL be validated by SRQL before persistence
- **AND** the dashboard network asset map SHALL use that query on subsequent loads

#### Scenario: Admin saves a named map view
- **GIVEN** an authenticated admin has built a map-compatible SRQL query
- **WHEN** they save it as a named view
- **THEN** the view SHALL be available in the full-screen network asset map view selector
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
- **GIVEN** the dashboard WiFi map card is rendered from the configured SRQL query
- **WHEN** a user activates the map card open action
- **THEN** the full-screen deck.gl map SHALL open with the same query, filters, and selected view context where possible

### Requirement: Dashboard package import and hosting

The UI SHALL allow authorized administrators to import signed dashboard packages and enable them as custom dashboard views without rebuilding web-ng.

#### Scenario: Admin imports dashboard package manifest
- **GIVEN** a customer-owned source exposes a dashboard package JSON manifest with a signed WASM renderer artifact
- **WHEN** an authorized administrator imports the package
- **THEN** the UI SHALL show package identity, version, vendor, source provenance, requested capabilities, required SRQL data frames, and verification state
- **AND** the package SHALL remain disabled until verification succeeds and the administrator enables it

#### Scenario: Admin enables a custom dashboard package
- **GIVEN** a verified dashboard package defines settings schema and default SRQL data frames
- **WHEN** an authorized administrator enables it
- **THEN** the UI SHALL persist approved settings and make the dashboard available from the configured dashboard location
- **AND** the custom dashboard SHALL render through the ServiceRadar dashboard host rather than product-specific compiled routes

### Requirement: Browser WASM dashboard renderer host

The dashboard SHALL host signed browser-side WASM renderers for custom dashboards while keeping authentication, authorization, theming, SRQL execution, and navigation under ServiceRadar control.

#### Scenario: Versioned host interface is enforced
- **GIVEN** a dashboard package declares a browser WASM renderer interface version
- **WHEN** the dashboard host loads the package
- **THEN** it SHALL allow only explicitly supported interface versions such as `dashboard-wasm-v1`
- **AND** unsupported or missing interface versions SHALL fail with a product-native diagnostic instead of executing the renderer

#### Scenario: Custom renderer receives SRQL data frames
- **GIVEN** an enabled dashboard package declares SRQL data frames and a browser WASM renderer
- **WHEN** a user opens that dashboard
- **THEN** web-ng SHALL execute the approved SRQL queries server-side
- **AND** it SHALL pass validated settings and data frames to the WASM renderer through the versioned dashboard host API
- **AND** the renderer SHALL NOT receive database credentials, API tokens, repository credentials, or unrestricted network access

#### Scenario: Custom renderer emits a deck.gl render model
- **GIVEN** a dashboard WASM renderer emits a `deck_map` render model through the dashboard host API
- **WHEN** the host accepts the model
- **THEN** ServiceRadar-owned JavaScript SHALL render the declared deck.gl layers over the configured basemap
- **AND** custom interactions SHALL be limited to approved host actions such as native popups, details navigation, and saved view updates

#### Scenario: Renderer asset is served from ServiceRadar package storage
- **GIVEN** a dashboard package was imported from a customer-owned repository
- **WHEN** a user opens the dashboard
- **THEN** the browser SHALL fetch the renderer from an authenticated ServiceRadar asset URL backed by verified package storage
- **AND** it SHALL NOT fetch WASM, JSON, or credentials directly from the customer repository

#### Scenario: Custom renderer fails
- **GIVEN** a dashboard WASM renderer traps, times out, requests an unapproved capability, or receives a non-mappable result set
- **WHEN** the dashboard host detects the failure
- **THEN** the UI SHALL show a bounded product-native failure state with diagnostics for authorized users
- **AND** the failure SHALL NOT break the surrounding ServiceRadar shell, navigation, or other dashboard cards
