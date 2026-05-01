# Change: Add SRQL-driven WiFi map ingestion and dashboard plugins

## Why

Wireless operators need the Aruba WiFi map that currently exists as a standalone CSV-backed Leaflet proof of concept inside ServiceRadar, with the same site, airport/reference, AP, WLC, RADIUS/CPPM, and migration visibility available through the normal agent pipeline, CNPG storage, SRQL, and web-ng dashboard.

The near-term source of truth is the CSV seed data in `tmp/wifi-map/`; the long-term source is a customer-owned Go SDK WiFi-map plugin that collects the same Aruba AP database, controller switchinfo, and RADIUS server-group data directly from controllers. Airport/site reference CSV data is expected to remain a long-lived source of truth and should refresh on a much slower cadence than polling data. The plugin should live in the customer's own repository, not in the ServiceRadar OSS repository.

The browser experience should not become a United Airlines-specific feature baked into ServiceRadar. ServiceRadar should provide the data contracts, SRQL execution, signed package sync, and dashboard runtime needed to host customer dashboards. The customer-specific map/dashboard should live as a signed dashboard WASM package that can be imported from a customer repository.

## What Changes

- Define the external WiFi-map plugin contract for plugins built with `serviceradar-sdk-go`.
- Add customer-owned private Git plugin sources so operators can register repositories, configure credentials/trust policy, sync signed plugin manifests, and stage approved plugins for assignment.
- Support two plugin collection modes:
  - `csv_seed`: customer plugin reads airport/site reference data, site overrides, AP inventory, WLC inventory, RADIUS group mapping, history snapshots, and search index seed files from approved plugin configuration or package assets.
  - `aruba_controller`: future live collection path equivalent to the POC collectors (`Collect_AP_Database.py`, `collect_controller_info.py`, `collect_radius_groups.py`).
- Extend plugin result ingestion so structured WiFi-map batches can flow through `plugin -> agent -> agent-gateway -> core-elx`.
- Add platform-owned CNPG tables in the `platform` schema for WiFi map sites, airport/site reference data, AP observations, WLC/controller observations, RADIUS mappings, site history snapshots, and configurable map views.
- Use PostGIS geography columns for site coordinates instead of storing latitude/longitude only in opaque metadata.
- Preserve OCSF device identity for seed records that are actual devices or device-like infrastructure, including APs, WLCs/controllers, and concrete auth infrastructure hosts when present.
- Extend SRQL with WiFi site map entities and fields so map payloads are driven by SRQL queries rather than static CSV fetches.
- Add dashboard map mode selection between NetFlow and location-aware network asset maps.
- Add a generic network asset map route for SRQL result sets with coordinates, keeping `/wifi-map` as a compatibility alias while making `/network-map` the product route.
- Add a dashboard WASM plugin runtime where imported dashboard packages define custom views, interactions, popups, and layout logic without compiling customer-specific UI into web-ng.
- Use JSON dashboard package manifests for dashboard identity, versioning, required SRQL queries, data-frame contracts, permissions, renderer WASM references, signing metadata, and settings schema.
- Add settings UI for importing dashboard packages, selecting default dashboard/map views, and configuring approved dashboard package settings.

## Impact

- Affected specs:
  - `plugin-sdk-go`
  - `wasm-plugin-system`
  - `plugin-configuration-ui`
  - `device-inventory`
  - `srql`
  - `build-web-ui`
  - `docker-compose-stack`
- Affected code:
  - `/home/mfreeman/src/serviceradar-sdk-go`: SDK helpers for structured inventory result batches if needed.
  - Customer plugin repository: WiFi-map plugin package, manifests, signatures, and seed/live collector implementation.
  - `go/` agent runtime/package handling if approved seed-file access or payload handoff host functions are insufficient.
  - `proto/monitoring.proto` and agent/gateway handling if current plugin-result payload limits or typing are insufficient.
  - `elixir/serviceradar_core/priv/repo/migrations/`: platform schema migrations for WiFi map storage.
  - `elixir/serviceradar_core/`: plugin source sync, encrypted credential references, ingestion resources, Ash actions, and plugin-result handlers.
  - `rust/srql/`: parser/entity support, SQL generation, fixtures, and tests for WiFi map entities.
  - `elixir/web-ng/`: customer plugin source UI, dashboard package import UI, dashboard map selector, generic network map LiveView, browser-side dashboard WASM host, SRQL builder integration, settings UI.

## Source Material Reviewed

- `tmp/wifi-map/site_inventory_map.html`
- `tmp/wifi-map/sites.csv`
- `tmp/wifi-map/search_index.csv`
- `tmp/wifi-map/history.csv`
- `tmp/wifi-map/overrides.csv`
- `tmp/wifi-map/meta.json`
- `tmp/wifi-map/Collect_AP_Database.py`
- `tmp/wifi-map/collect_controller_info.py`
- `tmp/wifi-map/collect_radius_groups.py`
- `tmp/wifi-map/build_sites.py`
- `/home/mfreeman/src/serviceradar-sdk-go`
