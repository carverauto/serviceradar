## ADDED Requirements

### Requirement: WiFi-map SRQL entities

SRQL SHALL expose WiFi-map entities for querying site map data, AP/controller detail rows, RADIUS mappings, and migration history.

#### Scenario: Query WiFi sites for map rendering
- **GIVEN** WiFi-map data has been ingested
- **WHEN** a client sends `in:wifi_sites region:AM-Central sort:ap_count:desc limit:50`
- **THEN** SRQL SHALL return site rows with site code, name, site type, region, latitude, longitude, AP counts, latest snapshot timestamp, and map-renderable marker metrics

#### Scenario: Query AP detail rows for a selected site
- **GIVEN** AP observations exist for site `ORD`
- **WHEN** a client sends `in:wifi_aps site_code:ORD status:Down sort:name:asc`
- **THEN** SRQL SHALL return matching AP rows with name, MAC, serial, IP, model, status, site code, and latest observation timestamp

#### Scenario: Query controller detail rows by AOS version
- **GIVEN** controller observations include AOS versions
- **WHEN** a client sends `in:wifi_controllers aos_version:8.10.0.21`
- **THEN** SRQL SHALL return controller rows matching that version with hostname, IP, model, site code, region, and observation timestamp

#### Scenario: Query RADIUS cluster mappings
- **GIVEN** WiFi RADIUS group observations have been ingested
- **WHEN** a client sends `in:wifi_radius_groups cluster:NDC`
- **THEN** SRQL SHALL return site and controller mappings for the NDC cluster including server group and AAA profile

#### Scenario: Query slowly changing site references
- **GIVEN** airport/site reference rows and manual overrides have been ingested
- **WHEN** a client sends `in:wifi_site_references site_type:airport region:EMEA`
- **THEN** SRQL SHALL return reference rows with site code, name, site type, region, latitude, longitude, reference hash, and reference update timestamp

#### Scenario: Search WiFi map assets
- **GIVEN** WiFi AP, WLC/controller, and site rows have been ingested
- **WHEN** a client searches by hostname, MAC, serial, IP, site code, or site name
- **THEN** SRQL SHALL return matching rows from the relevant WiFi-map entity
- **AND** each row SHALL include enough site context for the UI to focus the corresponding map feature

### Requirement: WiFi map SRQL projection

SRQL SHALL provide a map-compatible projection for WiFi site queries that includes coordinates, stable feature IDs, display labels, marker metrics, and popup/detail fields.

#### Scenario: Map projection includes required fields
- **GIVEN** a WiFi site query selects mappable sites
- **WHEN** the web UI requests the map projection
- **THEN** SRQL SHALL return each feature with `feature_id`, `site_code`, `label`, `latitude`, `longitude`, `site_type`, `region`, `ap_count`, `up_count`, `down_count`, and latest snapshot metadata
- **AND** each feature SHALL include stable identifiers for follow-on popup/detail SRQL queries

#### Scenario: Sites without coordinates are excluded from map projection
- **GIVEN** a WiFi site has no valid latitude or longitude
- **WHEN** SRQL builds a map projection
- **THEN** the site SHALL be omitted from geographic features
- **AND** non-map tabular queries SHALL still be able to return the site

### Requirement: WiFi-map grouping and filters

SRQL SHALL support filters and aggregations needed by the WiFi map UI, including region, site type, AP model family, WLC model, AOS version, RADIUS cluster, server group, status, and time.

#### Scenario: Group WiFi sites by RADIUS cluster
- **GIVEN** WiFi site snapshots include CPPM cluster values
- **WHEN** a client sends `in:wifi_sites stats:count() as count by cluster`
- **THEN** SRQL SHALL return counts grouped by cluster ordered by count descending

#### Scenario: Filter WiFi sites by AP model family
- **GIVEN** WiFi site snapshots include AP model breakdowns
- **WHEN** a client sends `in:wifi_sites ap_family:6xx`
- **THEN** SRQL SHALL return only sites with at least one AP in the 6xx model family

#### Scenario: Filter down APs for a selected site
- **GIVEN** AP observations exist for site `IAH`
- **WHEN** a client sends `in:wifi_aps site_code:IAH status:Down sort:name:asc`
- **THEN** SRQL SHALL return only down AP rows for that site
- **AND** the rows SHALL include canonical device UID when the AP was linked to `ocsf_devices`
