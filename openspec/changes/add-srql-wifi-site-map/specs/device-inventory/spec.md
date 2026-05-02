## ADDED Requirements

### Requirement: WiFi map data storage

The system SHALL store WiFi map seed and collected data in platform-owned tables that preserve site identity, map coordinates, airport/site reference data, aggregate AP/controller state, RADIUS mapping, and source metadata without relying on browser-loaded CSV files.

#### Scenario: WiFi site is ingested from seed data
- **GIVEN** a WiFi-map batch contains a site with site code, name, site type, region, latitude, longitude, AP counts, model breakdowns, controller summaries, and RADIUS mapping
- **WHEN** core-elx ingests the batch
- **THEN** the platform SHALL upsert a WiFi site record in the `platform` schema
- **AND** it SHALL persist a generated PostGIS geography point when latitude and longitude are valid
- **AND** it SHALL persist a site snapshot with AP counts, model summaries, WLC summaries, AOS versions, CPPM cluster, server group, and AAA profile

#### Scenario: Non-airport site uses manual override coordinates
- **GIVEN** seed data includes a non-airport site from `overrides.csv`
- **WHEN** the WiFi site is ingested
- **THEN** the site SHALL retain its explicit site type
- **AND** the map location SHALL use the override latitude and longitude
- **AND** the record SHALL NOT be treated as an airport solely because its code resembles an IATA code

### Requirement: WiFi device identity integration

The system SHALL upsert device-like WiFi map records as OCSF devices while keeping map/reference/aggregate data in WiFi-map tables.

#### Scenario: AP observation creates or updates an OCSF device
- **GIVEN** a WiFi-map batch contains an AP with MAC, serial, hostname, IP, model, site code, and status
- **WHEN** the AP observation is ingested
- **THEN** DIRE SHALL resolve a stable OCSF device identity from MAC or serial
- **AND** `ocsf_devices` SHALL be updated with hostname/name, IP, MAC, model, vendor, discovery source, availability, and last seen time
- **AND** Aruba-specific fields such as MM host, AP group, flags, uptime, and source row metadata SHALL be retained outside core OCSF columns

#### Scenario: WLC/controller observation creates or updates an OCSF device
- **GIVEN** a WiFi-map batch contains a controller with hostname, IP, MAC or hardware base MAC, model, AOS version, chassis serial, and PSU status
- **WHEN** the controller observation is ingested
- **THEN** DIRE SHALL resolve a stable OCSF device identity from MAC or serial
- **AND** `ocsf_devices` SHALL be updated with controller identity and hardware metadata
- **AND** controller observation history SHALL preserve AOS version, uptime, reboot cause, chassis serial, and PSU status

#### Scenario: Non-device map data is stored outside OCSF devices
- **GIVEN** a WiFi map batch contains airport/site reference data, model breakdowns, AP count aggregates, RADIUS cluster labels, or fleet history rows
- **WHEN** core-elx ingests the batch
- **THEN** those records SHALL be stored in queryable WiFi-map tables
- **AND** they SHALL NOT be forced into `ocsf_devices` unless they represent a concrete device or device-like infrastructure endpoint

### Requirement: WiFi-map history

The system SHALL preserve fleet-level and per-site WiFi-map snapshots so migration and availability trends can be queried.

#### Scenario: Fleet history row is ingested
- **GIVEN** a WiFi-map batch contains a history row with build date, total AP count, AP family counts, AP-325 count, percent 6xx, percent legacy, and site count
- **WHEN** core-elx ingests the batch
- **THEN** the platform SHALL upsert the fleet history row by build date and source
- **AND** subsequent SRQL queries SHALL be able to chart the migration trend

#### Scenario: Site snapshot is ingested repeatedly
- **GIVEN** the same site snapshot is delivered again for the same collection timestamp
- **WHEN** core-elx ingests the batch
- **THEN** the platform SHALL update the existing snapshot idempotently rather than creating duplicate rows
