## 1. Data Contract and External Plugin Contract

- [ ] 1.1 Define the WiFi-map batch JSON schema and versioning contract.
- [x] 1.2 Add Go SDK helpers for emitting plugin device discovery/enrichment envelopes that core can reconcile into inventory.
- [x] 1.2.1 Add Rust SDK types for the same `serviceradar.device_discovery.v1` payload contract.
- [ ] 1.3 Document the customer-owned WiFi-map plugin repository/package contract, including manifest, signatures, config schema, and expected outputs.
- [x] 1.4 Define the `csv_seed` configuration contract for airport/site reference CSVs, `sites.csv`, `search_index.csv`, `history.csv`, `overrides.csv`, and optional AP/WLC/RADIUS source CSVs.
- [ ] 1.5 Define separate refresh cadence controls for slowly changing airport/site reference data versus normal AP/controller polling data.
- [ ] 1.6 Decide and implement the approved seed-file access model: package assets, explicit file-read host permission, or object handoff.
- [ ] 1.7 Provide an external plugin fixture/harness that customer authors can use to validate CSV parsing, normalization, malformed rows, reference-data hash handling, and bounded batch emission without adding the customer plugin to the ServiceRadar OSS repository.

## 2. Customer Plugin Sources

- [ ] 2.1 Add `platform` schema tables/resources for customer plugin sources, source sync state, trust policy, and encrypted credential references.
- [ ] 2.2 Implement private Git source sync for a configured repo URL, ref, manifest path, auth mode, timeout, and size limits.
- [ ] 2.3 Verify customer plugin source manifests, package digests, signatures/checksums, and configured trust policy before staging any package.
- [ ] 2.4 Mirror verified package content into ServiceRadar-managed plugin storage; never expose customer repository URLs or credentials to agents.
- [ ] 2.5 Reuse staged plugin review so customer packages require capability/allowlist approval before assignment.
- [ ] 2.6 Add settings UI for adding, testing, syncing, disabling, and deleting customer plugin sources.
- [ ] 2.7 Add plugin catalog UI state showing official and customer sources, source provenance, verification state, sync errors, and import actions.
- [ ] 2.8 Add tests for auth failure, manifest validation failure, invalid signature, duplicate versions, sync idempotency, and staged approval.
- [ ] 2.9 Add manifest-declared plugin result contracts so approved customer plugin packages can declare supported output schemas without hardcoding customer handlers in core.

## 3. Pipeline and Storage

- [x] 3.1 Measure seed payload size and decide whether plugin-result chunking or object-store handoff is required.
- [x] 3.2 Add core-elx plugin-result dispatch for WiFi-map batches.
- [x] 3.3 Add Elixir migrations in `elixir/serviceradar_core/priv/repo/migrations/` for WiFi map tables in `platform`.
- [x] 3.4 Add slowly changing airport/site reference storage with source hash/version tracking and idempotent refresh semantics.
- [x] 3.5 Add PostGIS generated geography columns and spatial indexes for WiFi map sites/assets.
- [x] 3.6 Add Ash resources/actions for airport/site references, WiFi sites, snapshots, AP observations, controller observations, RADIUS mappings, fleet history, and map views.
- [x] 3.7 Implement typed batch recognition, normalization, transactional table upserts, and unit tests for non-device WiFi-map persistence.
- [x] 3.8 Add OCSF device identity upserts for AP and WLC/controller seed records through the existing inventory sync path; keep non-device map/reference data in queryable WiFi-map tables.
- [x] 3.8.1 Keep the generic plugin-result ingestor free of WiFi-map-specific runtime branching; WiFi-map batch ingestion remains a local/dev bridge, while production plugin inventory flows through platform contracts such as device discovery.
- [x] 3.8.2 Add a generic plugin device-discovery handler that converts `serviceradar.device_discovery.v1` records into inventory sync updates for `ocsf_devices`.
- [x] 3.8.3 Make platform plugin-result handlers schema-driven with `supports?/2` checks so unrelated handlers are not invoked for customer payloads and core does not require per-customer dispatch branches.
- [ ] 3.9 Add concrete RADIUS/CPPM host device upserts if future source data includes hostnames/IPs for those hosts rather than only server-group/cluster labels.
- [ ] 3.10 Add ingestion tests covering database idempotency, reference-data skip-on-same-hash behavior, coordinate validation, OCSF identity updates, and partial batch failures.
- [ ] 3.11 Keep `mix serviceradar.wifi_map.seed` documented as a local Docker Compose/dev harness only; production/customer data must enter through an agent-side plugin result.

## 4. SRQL

- [x] 4.1 Add SRQL entities for `wifi_sites`, `wifi_site_snapshots`, `wifi_aps`, `wifi_controllers`, `wifi_radius_groups`, `wifi_fleet_history`, and `wifi_site_references`.
- [x] 4.2 Add filter/sort fields for site code, region, site type, AP counts, controller model/version, RADIUS cluster, server group, status, and time.
- [ ] 4.3 Add AP model-family JSONB filters and SRQL stats/grouping for WiFi map entities.
- [x] 4.4 Add map-compatible row projection for WiFi site queries with feature IDs, coordinates, GeoJSON location, and latest marker metrics.
- [ ] 4.5 Add a dedicated map projection mode that excludes non-coordinate rows when the UI requests geographic features.
- [x] 4.6 Add Rust translation tests for WiFi SRQL queries, parser aliases, map projections, and unsupported fields.
- [ ] 4.7 Add database-backed Rust fixtures/tests for WiFi SRQL grouping and representative query execution against migrated schema.
- [x] 4.8 Expose WiFi entities and fields in the web-ng SRQL builder metadata.

## 5. Web UI

- [ ] 5.1 Add settings UI for default dashboard network asset map query and named map views.
- [x] 5.2 Reuse or extend deployment-level Mapbox settings for map basemap styles/tokens; do not source tile/provider settings from plugin payloads.
- [ ] 5.3 Add dashboard map/dashboard package selector for NetFlow and enabled dashboard package map views, with full-screen actions for each selected view.
- [x] 5.3.1 Add the initial dashboard selector integration that lists enabled dashboard package instances and navigates selected packages through `/dashboards/:route_slug`.
- [ ] 5.4 Add a dashboard package preview card driven by configured SRQL data frames and configured ServiceRadar basemap provider.
- [ ] 5.5 Add full-screen dashboard package routing for map packages; do not keep `/wifi-map` as a product route.
- [ ] 5.6 Add saved view selection and map-specific filters to the full-screen network asset map route.
- [x] 5.7 Implement clickable deck.gl map features that open ServiceRadar-owned popups.
- [ ] 5.8 Add follow-on SRQL detail queries from map popups/detail panels.
- [ ] 5.9 Implement site/device search over SRQL-backed site code, site name, hostname, MAC, serial, IP, model, and status fields.
- [ ] 5.10 Move customer-specific POC parity interactions into an installable dashboard package: region, RADIUS cluster, AP family, WLC model/version filters, DOWN-only filter, site popup details, AP/WLC detail lists, freshness, and fleet migration trend.
- [ ] 5.11 Add responsive desktop/mobile styling and Playwright visual checks for dashboard and full-screen map views.
- [x] 5.12 Remove the hardcoded web-ng WiFi map hook, route, dashboard selector option, and spatial-page entry so customer-specific behavior lives outside the ServiceRadar product.

## 6. Dashboard Packages and Browser WASM

- [x] 6.1 Define the dashboard package JSON manifest schema: package ID, version, vendor, description, data-frame contracts, SRQL query definitions, React/browser-module renderer reference, optional renderer WASM reference, settings schema, signing metadata, and requested browser capabilities.
- [x] 6.2 Add `platform` schema resources for imported dashboard packages, package versions, sync provenance, verification state, administrator settings, and enabled dashboard instances.
- [ ] 6.3 Extend customer-owned Git source sync to discover dashboard package manifests alongside agent plugin manifests without exposing repository credentials to browsers or agents.
- [ ] 6.4 Verify dashboard package renderer artifacts against digest and trust policy before making them available in the UI.
- [ ] 6.5 Build a web-ng dashboard renderer host that loads signed browser renderers, passes theme/layout context, enforces the versioned `dashboard-browser-module-v1` and optional `dashboard-wasm-v1` interfaces, and exposes bounded host APIs for SRQL execution, saved queries, preferences, navigation, and popup/detail requests.
- [ ] 6.6 Support Arrow IPC or equivalent columnar data frames from SRQL results for high-volume dashboard renderers while retaining JSON row delivery for smaller payloads.
- [x] 6.6.1 Expose the dashboard-frame Arrow IPC payload contract to trusted browser modules and dashboard WASM renderers, with JSON row fallback when the active SRQL backend cannot emit Arrow.
- [x] 6.6.2 Extend SRQL execution so selected queries can emit real Arrow IPC directly from PostgreSQL result sets instead of row JSON.
- [x] 6.6.3 Add SDK examples/tests that decode Arrow IPC frames for custom topology-style renderers, including React browser-module and WASM paths.
- [x] 6.6.4 Add dashboard frame live delivery over Phoenix Channels/WebSockets: initial snapshot, bounded refresh/replacement frames, auth checks, and reconnect semantics.
- [ ] 6.7 Convert the United WiFi map experience into a customer dashboard package design that uses the WiFi-map SRQL entities and renderer host rather than hardcoded web-ng components.
- [x] 6.7.1 Create the initial external `~/src/ual-dashboard` dashboard package workspace with manifest build, sample frames, and harness instructions.
- [x] 6.7.2 Migrate the UAL dashboard package renderer to React using `dashboard-browser-module-v1`, preserving SRQL-driven filters, clustering, popups, Mapbox basemap behavior, device detail links, and ServiceRadar theme integration.
- [x] 6.7.3 Add Playwright parity checks for the React UAL package against the SDK harness and the Docker Compose dashboard route.
- [ ] 6.8 Add settings UI for importing, enabling, disabling, configuring, and choosing default dashboard packages and map views.
- [x] 6.8.1 Add the initial dashboard package settings UI for upload import, enable/disable, package inspection, and route creation.
- [ ] 6.8.2 Add default dashboard/map-view selection and richer per-instance settings editing.
- [ ] 6.9 Add sandbox, permission, and failure-state tests for dashboard renderer packages, including invalid signature, unsupported capability, renderer crash, slow renderer, and non-mappable SRQL result behavior.
- [x] 6.10 Provide a local customer dashboard package dev harness in `~/src/serviceradar-sdk-dashboard` that loads manifest JSON, renderer artifacts, validated settings, and sample SRQL frames without deploying to production.
- [x] 6.11 Create the initial external `~/src/serviceradar-sdk-dashboard` SDK workspace and update example/customer renderers to use it instead of copying ABI glue.
- [x] 6.11.1 Add a React SDK package surface in `~/src/serviceradar-sdk-dashboard` with host API types, SRQL query helpers, frame access hooks, theme hooks, navigation helpers, and a browser-module mount helper.
- [x] 6.11.2 Add a React/Vite dashboard package template and harness path that emits `dashboard-browser-module-v1` renderer artifacts consumable by web-ng.
- [ ] 6.12 Migrate built-in topology and netflow map experiences toward dashboard packages so they can be versioned and updated outside core/web-ng.

## 7. Live Aruba Collector Follow-Up

- [x] 7.0 Create the customer-owned UAL agent plugin package outside the ServiceRadar OSS repository using `serviceradar-sdk-go`; it must support CSV seed mode first and emit `serviceradar.wifi_map.batch.v1` through `serviceradar.plugin_result.v1`.
- [ ] 7.1 Customer plugin implements `aruba_controller` mode for AP database collection via Aruba REST.
- [ ] 7.2 Customer plugin implements WLC switchinfo/inventory collection via Aruba REST.
- [ ] 7.3 Customer plugin implements optional RADIUS/CPPM server-group collection via SSH/mdconnect with bounded timeouts.
- [ ] 7.4 ServiceRadar validates credential handling and capability restrictions for HTTP/SSH host calls during staged review and assignment.
- [ ] 7.5 Add integration tests or replay fixtures based on captured Aruba responses where they can live outside the OSS repo or in sanitized form.
- [ ] 7.6 Package long-lived airport/site reference CSVs with the customer plugin and refresh them on a slower cadence than AP/controller/RADIUS polling data.

## 8. Verification

- [x] 8.1 Run `openspec validate add-srql-wifi-site-map --strict`.
- [x] 8.2 Run focused Go SDK/runtime tests for any new host functions or payload helpers.
- [x] 8.3 Run core-elx migrations and ingestion tests against the local Docker Compose CNPG database only; do not load proprietary customer seed data into the Kubernetes `demo` namespace.
- [ ] 8.4 Run customer plugin source sync/import tests.
- [x] 8.5 Run `cd rust/srql && cargo test --lib` for the current SRQL implementation; run full integration coverage before final merge.
- [ ] 8.6 Run `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix` after web changes.
- [x] 8.7 Confirm the default Docker Compose stack has no faker service; if a dev faker overlay/profile is active, disable or scale it down for WiFi-map validation so synthetic demo devices do not clutter the local map/device inventory.
- [ ] 8.8 Capture Playwright screenshots for dashboard and full-screen network asset map on desktop and mobile against the local Docker Compose stack.
- [ ] 8.9 Add browser WASM dashboard host tests and Playwright coverage for an imported dashboard package rendered from SRQL data frames.
