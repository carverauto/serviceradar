## 1. Data Contract and External Plugin Contract

- [ ] 1.1 Define the WiFi-map batch JSON schema and versioning contract.
- [ ] 1.2 Add or document Go SDK helpers for emitting structured inventory batches from plugins.
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

## 3. Pipeline and Storage

- [x] 3.1 Measure seed payload size and decide whether plugin-result chunking or object-store handoff is required.
- [x] 3.2 Add core-elx plugin-result dispatch for WiFi-map batches.
- [x] 3.3 Add Elixir migrations in `elixir/serviceradar_core/priv/repo/migrations/` for WiFi map tables in `platform`.
- [x] 3.4 Add slowly changing airport/site reference storage with source hash/version tracking and idempotent refresh semantics.
- [x] 3.5 Add PostGIS generated geography columns and spatial indexes for WiFi map sites/assets.
- [x] 3.6 Add Ash resources/actions for airport/site references, WiFi sites, snapshots, AP observations, controller observations, RADIUS mappings, fleet history, and map views.
- [x] 3.7 Implement typed batch recognition, normalization, transactional table upserts, and unit tests for non-device WiFi-map persistence.
- [x] 3.8 Add OCSF device identity upserts for AP and WLC/controller seed records through the existing inventory sync path; keep non-device map/reference data in queryable WiFi-map tables.
- [ ] 3.9 Add concrete RADIUS/CPPM host device upserts if future source data includes hostnames/IPs for those hosts rather than only server-group/cluster labels.
- [ ] 3.10 Add ingestion tests covering database idempotency, reference-data skip-on-same-hash behavior, coordinate validation, OCSF identity updates, and partial batch failures.

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

- [ ] 5.1 Add settings UI for default dashboard WiFi map query and named WiFi map views.
- [x] 5.2 Reuse or extend deployment-level Mapbox settings for WiFi map basemap styles/tokens; do not source tile/provider settings from plugin payloads.
- [x] 5.3 Add dashboard map mode selector for NetFlow vs WiFi site map, with full-screen actions for both modes.
- [ ] 5.4 Add a dashboard deck.gl WiFi map card driven by the configured SRQL query and configured ServiceRadar basemap provider.
- [x] 5.5 Add an initial full-screen deck.gl WiFi map LiveView route with SRQL builder and result table.
- [ ] 5.6 Add saved view selection and map-specific filters to the full-screen WiFi map route.
- [x] 5.7 Implement clickable deck.gl WiFi site features that open ServiceRadar-owned popups.
- [ ] 5.8 Add follow-on SRQL detail queries from WiFi map popups/detail panels.
- [ ] 5.9 Implement site/device search over SRQL-backed site code, site name, hostname, MAC, serial, IP, model, and status fields.
- [ ] 5.10 Rebuild POC parity interactions: region, RADIUS cluster, AP family, WLC model/version filters, DOWN-only filter, site popup details, AP/WLC detail lists, freshness, and fleet migration trend.
- [ ] 5.11 Add responsive desktop/mobile styling and Playwright visual checks for dashboard and full-screen map views.

## 6. Live Aruba Collector Follow-Up

- [ ] 6.1 Customer plugin implements `aruba_controller` mode for AP database collection via Aruba REST.
- [ ] 6.2 Customer plugin implements WLC switchinfo/inventory collection via Aruba REST.
- [ ] 6.3 Customer plugin implements optional RADIUS/CPPM server-group collection via SSH/mdconnect with bounded timeouts.
- [ ] 6.4 ServiceRadar validates credential handling and capability restrictions for HTTP/SSH host calls during staged review and assignment.
- [ ] 6.5 Add integration tests or replay fixtures based on captured Aruba responses where they can live outside the OSS repo or in sanitized form.

## 7. Verification

- [x] 7.1 Run `openspec validate add-srql-wifi-site-map --strict`.
- [ ] 7.2 Run focused Go SDK/runtime tests for any new host functions or payload helpers.
- [x] 7.3 Run core-elx migrations and ingestion tests against the local Docker Compose CNPG database only; do not load proprietary customer seed data into the Kubernetes `demo` namespace.
- [ ] 7.4 Run customer plugin source sync/import tests.
- [x] 7.5 Run `cd rust/srql && cargo test --lib` for the current SRQL implementation; run full integration coverage before final merge.
- [ ] 7.6 Run `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix` after web changes.
- [x] 7.7 Confirm the default Docker Compose stack has no faker service; if a dev faker overlay/profile is active, disable or scale it down for WiFi-map validation so synthetic demo devices do not clutter the local map/device inventory.
- [ ] 7.8 Capture Playwright screenshots for dashboard and full-screen WiFi map on desktop and mobile against the local Docker Compose stack.
