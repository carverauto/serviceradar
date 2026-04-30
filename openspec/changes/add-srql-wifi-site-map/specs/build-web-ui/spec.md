## ADDED Requirements

### Requirement: Dashboard map mode selection

The dashboard SHALL allow users to choose between the existing NetFlow map and a WiFi site map without removing either view.

#### Scenario: User switches dashboard map to WiFi
- **GIVEN** WiFi-map data has been ingested
- **WHEN** a user selects `WiFi map` from the dashboard map mode control
- **THEN** the dashboard map card SHALL render WiFi site markers from the configured default WiFi map SRQL query
- **AND** the selected mode SHALL persist according to the existing dashboard preference pattern

#### Scenario: WiFi map has no mappable data
- **GIVEN** the default WiFi map query returns no rows with valid coordinates
- **WHEN** the dashboard renders the WiFi map card
- **THEN** it SHALL show an empty state that identifies the configured SRQL query and explains that mappable WiFi site rows require coordinates

### Requirement: Full-screen SRQL-driven WiFi map

The system SHALL provide a full-screen WiFi map view where users can edit SRQL queries and render compatible results as map views.

#### Scenario: User opens WiFi map from dashboard
- **GIVEN** the dashboard is showing the WiFi map card
- **WHEN** a user opens the full-screen map action
- **THEN** the application SHALL navigate to the full-screen WiFi map view
- **AND** the view SHALL initialize with the same SRQL query used by the dashboard card

#### Scenario: User builds a new map query
- **GIVEN** a user is on the full-screen WiFi map view
- **WHEN** they use the SRQL builder to query `in:wifi_sites region:AM-East`
- **THEN** the map SHALL refresh from SRQL results
- **AND** a synchronized result table SHALL show the returned site rows
- **AND** unsupported non-map result sets SHALL show a clear non-mappable result state instead of failing

### Requirement: ServiceRadar-owned WiFi map basemap provider

The WiFi map SHALL use ServiceRadar-owned basemap configuration rather than plugin-owned tile URLs or credentials.

#### Scenario: Mapbox settings are configured
- **GIVEN** deployment-level Mapbox settings are enabled with an access token and style URLs
- **WHEN** the dashboard or full-screen WiFi map renders
- **THEN** deck.gl SHALL render the WiFi map over the configured Mapbox basemap style
- **AND** the plugin payload SHALL NOT provide Mapbox tokens, tile URLs, or executable map code

#### Scenario: Mapbox settings are not configured
- **GIVEN** Mapbox settings are disabled or missing a usable token
- **WHEN** a user opens the WiFi map
- **THEN** the UI SHALL render a clear basemap configuration state or a bounded ServiceRadar-supported fallback
- **AND** it SHALL NOT silently use third-party tile providers that require terms, API keys, or attribution not configured by an administrator

#### Scenario: Admin manages basemap settings
- **GIVEN** an authenticated admin is in settings
- **WHEN** they configure Mapbox token/style settings for map experiences
- **THEN** those settings SHALL apply to both dashboard and full-screen WiFi map views
- **AND** OpenStreetMap or other tile providers SHALL only be added through explicit ServiceRadar product settings if selected later

### Requirement: WiFi map saved view settings

Administrators SHALL be able to configure the dashboard WiFi map query and manage named WiFi map views from settings.

#### Scenario: Admin saves the default dashboard WiFi map query
- **GIVEN** an authenticated admin is in the settings UI
- **WHEN** they save a default WiFi map query such as `in:wifi_sites ap_count:>0 sort:ap_count:desc`
- **THEN** the query SHALL be validated by SRQL before persistence
- **AND** the dashboard WiFi map SHALL use that query on subsequent loads

#### Scenario: Admin saves a named WiFi map view
- **GIVEN** an authenticated admin has built a WiFi map query
- **WHEN** they save it as a named view
- **THEN** the view SHALL be available in the full-screen WiFi map view selector
- **AND** the saved view SHALL include SRQL query text and server-owned visualization options only

### Requirement: WiFi map POC parity interactions

The WiFi map UI SHALL provide the core interactions present in the standalone proof of concept using ServiceRadar-owned components.

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
