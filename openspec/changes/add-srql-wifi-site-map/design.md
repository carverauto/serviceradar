## Context

The standalone WiFi POC is a static Leaflet application. It loads:

- `sites.csv`: 241 site rows with IATA/site code, airport/site reference fields, name, latitude, longitude, site type, region, AP counts, model breakdowns, controller names, WLC count/model/version summaries, RADIUS server group, CPPM cluster, and AAA profile.
- `search_index.csv`: 10,295 AP/WLC rows with kind, site code, name, MAC, serial, IP, status, and model.
- `history.csv`: daily fleet-level AP family migration snapshots.
- `overrides.csv`: manual coordinates for non-airport sites.
- `meta.json`: collection/build timestamps and summary counts.

The POC collectors split into three data domains:

- AP inventory from Aruba Mobility Masters via REST `show ap database long`.
- WLC/controller switchinfo from Mobility Devices via REST `show switches`, `show switchinfo`, and `show inventory`.
- RADIUS/CPPM server-group mapping from Mobility Masters via SSH `mdconnect` and `show aaa profile`.

ServiceRadar must move these concerns into its normal architecture: collection at the edge via a customer-owned Go WiFi-map plugin, transport through the agent pipeline, persistence in CNPG, query via SRQL, and deck.gl rendering in web-ng. The plugin itself is not a ServiceRadar OSS deliverable; ServiceRadar must instead make it possible for operators to register customer-controlled plugin repositories, sync signed plugin packages, approve them, and assign them to agents.

## Goals

- Preserve parity with the current map: region filters, cluster filters, AP model family filters, WLC model/version filters, clickable map features, site popups, AP/WLC detail search, down/up AP lists, and migration history.
- Keep short-term demo seeding simple by letting a customer plugin read CSV files from approved configuration or package assets.
- Treat airport/site reference CSV data as slowly changing reference data that can refresh independently and far less often than AP/controller polling data.
- Keep long-term live collection possible without changing the database or UI contracts.
- Make map views SRQL-driven so operators can build and save alternate map queries.
- Keep basemap provider credentials and tile/style configuration in ServiceRadar product settings, starting with the existing Mapbox settings surface.
- Store spatial data in queryable PostGIS columns.
- Make all seed data database-backed and SRQL-queryable rather than browser-CSV-backed.
- Reuse OCSF device identity for seed records that are actual devices or device-like infrastructure, including APs, WLCs/controllers, and concrete RADIUS/CPPM hosts when present.
- Support customer-owned private Git repositories as plugin sources alongside ServiceRadar-supported plugin sources.

## Non-Goals

- Do not implement RF heatmaps, floor plans, channel optimization, roaming analytics, or wireless client analytics in this change. Those remain covered by the broader active WiFi analytics proposal.
- Do not make the browser fetch CSV files directly.
- Do not store schema through db-event-writer or any Go service.
- Do not add multitenancy behavior.
- Do not execute plugin-supplied HTML or JavaScript in web-ng.
- Do not publish the customer WiFi-map plugin as a first-party ServiceRadar plugin.
- Do not allow agents to fetch plugin packages directly from customer Git repositories.
- Do not make the customer plugin responsible for browser basemap providers, Mapbox tokens, tile URLs, or OpenStreetMap terms/attribution decisions.

## Decisions

### D1: Dedicated WiFi map tables plus selective OCSF device identity

Store site-level and observation-level data in dedicated `platform` tables:

- `wifi_airport_references` or equivalent: slowly changing airport/site reference rows keyed by site/IATA code with name, location, region, source hash, and refresh timestamp.
- `wifi_sites`: one row per site code with name, site type, region, latitude, longitude, generated `location geography(Point,4326)`, source metadata, and latest collection timestamps.
- `wifi_site_snapshots`: time-series aggregate snapshots per site: AP counts, up/down counts, model breakdowns, WLC summaries, RADIUS cluster/server-group fields.
- `wifi_access_point_observations`: latest/time-series AP observations keyed by collection timestamp and AP identity fields.
- `wifi_controller_observations`: latest/time-series WLC/MD observations keyed by collection timestamp and controller identity fields.
- `wifi_radius_group_observations`: RADIUS/CPPM server-group observations keyed by collection timestamp, site code, controller alias, and AAA profile.
- `wifi_fleet_history`: daily fleet-level AP family and migration snapshots.
- `wifi_map_views`: saved map view definitions with name, SRQL query, default dashboard flag, and visualization options.

The database, not the CSV files, should be the source for map rendering and SRQL. That does not mean every mappable row belongs in `ocsf_devices`. Records should be modeled according to what they represent:

- APs upsert into `ocsf_devices`: prefer wired MAC, then serial, then `(source, ap_name)`.
- WLC/MD controllers upsert into `ocsf_devices`: prefer MAC or hardware base MAC, then chassis serial, then `(source, hostname)`.
- Concrete infrastructure hosts present in seed data, such as RADIUS/CPPM endpoints when represented as hosts, upsert into `ocsf_devices`: prefer IP/MAC/hostname, then source-specific stable identifier.
- Sites, airports, regions, model breakdowns, and aggregate snapshots remain queryable in WiFi-map tables unless the existing device inventory model has an appropriate non-device asset representation.

`ocsf_devices.metadata` can hold Aruba-specific details such as MM host, group, standby IP, flags, uptime strings, AAA profile, and source CSV file name. Site aggregate facts do not belong in `ocsf_devices`.

### D1a: Plugins do not extend schema at runtime

The WiFi-map data demonstrates that customer plugin data must become database-backed and SRQL-queryable without living off CSV files. This change SHALL NOT let plugins run arbitrary DDL from the agent, gateway, db-event-writer, core ingest payloads, or plugin repository sync. Schema changes must remain controlled by ServiceRadar migrations in the `platform` schema.

For this workstream, WiFi-map tables are platform-owned because the UI and SRQL surface are ServiceRadar-owned. If future customer plugins need new queryable domains, those domains should be handled as ServiceRadar-supported data contracts or constrained generic observation/entity tables, not as plugin-authored migrations.

### D1b: Seed data classification

The initial CSV-backed map data should be classified before implementation:

| Source data | Existing table fit | Target shape |
| --- | --- | --- |
| AP rows from `search_index.csv` | Good fit for `ocsf_devices` | Upsert canonical device rows, then store WiFi-specific observation facts in `wifi_access_point_observations`. |
| WLC/controller rows from `search_index.csv` and switchinfo collectors | Good fit for `ocsf_devices` | Upsert canonical device rows, then store AOS/version/PSU/reboot/site facts in `wifi_controller_observations`. |
| Concrete RADIUS/CPPM hosts, if future source data includes hostnames/IPs | Conditional fit for `ocsf_devices` | Upsert as devices only when the source identifies actual hosts; otherwise keep server group and cluster labels in RADIUS mapping tables. |
| Airport/site reference rows and manual overrides | Poor fit for `ocsf_devices` | Store in slowly changing `wifi_airport_references`/`wifi_sites` tables with PostGIS points and source hash/version metadata. |
| AP counts, up/down counts, AP model breakdowns, WLC model/version summaries | Poor fit for `ocsf_devices` | Store in `wifi_site_snapshots`, with JSONB summary fields initially and normalized child tables only if SRQL grouping requires them. |
| RADIUS server group, CPPM cluster, AAA profile labels | Relationship/config data | Store in `wifi_radius_group_observations` keyed by site/controller/profile/source timestamp. |
| `history.csv` fleet migration rows | Poor fit for `ocsf_devices` | Store in `wifi_fleet_history` keyed by build date/source. |
| `meta.json` timestamps and counts | Batch/source metadata | Store on ingest batch/source state for audit and idempotency. |

### D2: External WiFi-map plugin result emits structured map batches

The customer-owned WiFi-map plugin should emit a typed JSON batch inside the plugin result payload rather than display widgets. A batch should contain:

- `collection_mode`: `csv_seed` or `aruba_controller`.
- `collection_timestamp`.
- `reference_timestamp` and source hash for slowly changing airport/site reference data when included.
- `airport_references` or site reference rows when refreshed.
- `sites`.
- `access_points`.
- `controllers`.
- `radius_groups`.
- `fleet_history`.
- `source_files` or controller sources.

The agent and gateway can continue forwarding the result as `plugin-result`; core-elx is responsible for recognizing the WiFi-map batch kind and dispatching it to the WiFi-map ingest handler. If current payload limits are too small, add chunking or object-store handoff before implementation.

The current seed snapshot is small enough for a single plugin-result message: the checked CSV seed files are about 862 KB raw and 179 KB gzipped. Even after JSON expansion, the expected batch is comfortably below the agent-gateway plugin-result limit of 15 MB. The initial CSV seed mode can therefore emit one structured batch per collection. Chunking or object-store handoff should remain a follow-up if live collector payloads grow beyond the gateway limit or if plugin runtime memory pressure becomes visible.

### D2a: Reference data has a separate refresh cadence

Airport/site reference CSV data should not be re-sent on every plugin polling interval. The customer plugin contract should allow reference data to be:

- Sent only when the source file hash or configured version changes.
- Refreshed on a separate long interval from AP/controller observations.
- Marked as reference data in the batch so core-elx can ingest it idempotently without creating duplicate snapshots.

Core-elx should retain the latest reference source hash and timestamp per source and ignore repeated unchanged reference payloads.

### D3: CSV seed mode remains a plugin mode, not a one-off importer

The short-term seed path should still run as a plugin assignment. Configuration includes:

- CSV paths from an explicitly approved file-read permission model or package-relative asset paths for airport/site references, `sites.csv`, `search_index.csv`, `history.csv`, `overrides.csv`, and optional WLC/RADIUS source CSVs.
- Site code normalization rules.
- Maximum row limits and max payload bytes.
- Whether to upsert OCSF device rows.

This validates the pipeline and keeps the later live Aruba collector behind the same output contract.

The customer-provided Python scripts show that most generated CSVs can be
replaced by Go plugin collection logic over time:

- AP rows are collected from Aruba Mobility Masters via REST `show ap database long`.
- WLC/controller rows are collected by discovering Mobility Devices from each MM,
  then querying each MD via REST `show switchinfo` and `show inventory`.
- RADIUS server-group rows are collected from Mobility Masters via SSH and
  `mdconnect`, then querying the configured AAA profile.
- `sites.csv`, `search_index.csv`, and `history.csv` are derived artifacts that
  join AP/WLC/RADIUS observations to airport/site reference data.

The production plugin should therefore support two compatible paths:

- `csv_seed`: read packaged or explicitly allowed CSV seed assets and emit the
  normalized WiFi-map batch directly. This remains first-class because airport
  and manual override data will likely stay CSV-backed package assets.
- `aruba_controller`: collect AP/WLC/RADIUS rows from Aruba APIs/SSH, apply the
  same site/reference join logic in Go, then emit the same normalized batch.

ServiceRadar also provides a local-only Mix validation task that builds the same
batch from CSVs and calls the core ingestor against a local Docker Compose CNPG
database. That task is a ServiceRadar validation harness, not a substitute for
the customer-owned plugin.

### D4: Customer plugin repositories are control-plane sources, not agent sources

Operators should be able to add customer-owned Git repositories as plugin sources from ServiceRadar settings. A source should include:

- Repository URL and provider type (`git`, with provider-specific metadata when known).
- Auth mode and encrypted credential reference, such as HTTPS token, API token, or SSH deploy key.
- Branch/tag/ref and path to the plugin source index or manifest.
- Trust policy: allowed signing keys, required signature/checksum policy, optional Cosign/Rekor policy, and expected plugin IDs.
- Sync settings: manual-only or scheduled, interval, timeout, and last sync status.

The control plane fetches and verifies repository metadata, mirrors approved package content into ServiceRadar-managed plugin storage, and stages packages in the existing review workflow. Agents receive only internal package references after approval; they never receive customer repository URLs or credentials.

This extends the existing supported/first-party plugin import model without treating customer repositories as first-party. Official ServiceRadar sources can keep their pinned repository policy, while customer sources are operator-configured and operator-trusted.

### D5: SRQL owns map data selection

Add WiFi map entities to SRQL:

- `in:wifi_sites`
- `in:wifi_site_snapshots`
- `in:wifi_aps`
- `in:wifi_controllers`
- `in:wifi_radius_groups`
- `in:wifi_fleet_history`

The dashboard WiFi map uses a saved SRQL query from settings. The full-screen map initializes from that query, then lets users edit it through the SRQL builder. A result set is map-renderable when it includes site code, label, latitude, longitude or geography-derived coordinates, and numeric marker metrics.

### D6: Deck.gl web map renderer is ServiceRadar-owned

The existing POC behavior should be rebuilt as ServiceRadar-owned LiveView/JS components using deck.gl for map layers. The implementation may reuse concepts from the POC, but it must not render arbitrary HTML from plugin payloads. The renderer consumes normalized map rows returned by SRQL and supports known visualization options only.

Clickable deck.gl features should open ServiceRadar-owned popups/details. A selected site or asset should expose popup content, detail panels, and follow-on SRQL queries for AP/WLC/detail rows. Popup state should be driven by normalized row IDs and SRQL, not by static CSV payloads in the browser.

Basemap configuration is also ServiceRadar-owned. The initial implementation should use the existing deployment-level Mapbox settings and configured Mapbox styles when available because it gives the product a cleaner map appearance and avoids introducing a second tile-provider settings surface. OpenStreetMap tile layers should not be consumed implicitly by plugin payloads; if ServiceRadar later supports OSM or another provider, it should be exposed as an explicit administrator setting with provider-specific attribution, rate-limit, credential, and terms handling.

The POC behavior to preserve in ServiceRadar terms includes:

- Marker clustering or aggregation at low zoom and readable site labels at inspectable zooms.
- Region, CPPM cluster, WLC model, AOS version, AP family, and DOWN-only filtering.
- Device search across hostname, MAC, serial, IP, site code, and site name.
- Popup/detail expansion for up APs, down APs, and WLCs using SRQL-backed detail queries.
- Data freshness and fleet migration trend indicators based on ingested batch metadata/history.
- Dashboard card to full-screen map transition while preserving query/view context where possible.

## Data Model Sketch

The exact migration can evolve during implementation, but it should preserve these concepts:

```sql
CREATE TABLE platform.wifi_map_sources (
  source_id uuid PRIMARY KEY,
  plugin_source_id uuid,
  name text NOT NULL,
  source_kind text NOT NULL,
  latest_collection_at timestamptz,
  latest_reference_hash text,
  latest_reference_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}',
  inserted_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE platform.wifi_map_batches (
  batch_id uuid PRIMARY KEY,
  source_id uuid NOT NULL REFERENCES platform.wifi_map_sources(source_id),
  collection_mode text NOT NULL,
  collection_timestamp timestamptz NOT NULL,
  reference_hash text,
  source_files jsonb NOT NULL DEFAULT '[]',
  row_counts jsonb NOT NULL DEFAULT '{}',
  diagnostics jsonb NOT NULL DEFAULT '[]',
  inserted_at timestamptz NOT NULL
);

CREATE TABLE platform.wifi_site_references (
  source_id uuid NOT NULL REFERENCES platform.wifi_map_sources(source_id),
  site_code text NOT NULL,
  name text NOT NULL,
  site_type text NOT NULL,
  region text,
  latitude double precision,
  longitude double precision,
  location geography(Point, 4326) GENERATED ALWAYS AS (
    CASE
      WHEN latitude IS NOT NULL AND longitude IS NOT NULL
      THEN ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
      ELSE NULL
    END
  ) STORED,
  reference_hash text,
  reference_metadata jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (source_id, site_code)
);

CREATE TABLE platform.wifi_sites (
  source_id uuid NOT NULL REFERENCES platform.wifi_map_sources(source_id),
  site_code text PRIMARY KEY,
  name text NOT NULL,
  site_type text NOT NULL,
  region text,
  latitude double precision,
  longitude double precision,
  location geography(Point, 4326) GENERATED ALWAYS AS (
    CASE
      WHEN latitude IS NOT NULL AND longitude IS NOT NULL
      THEN ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
      ELSE NULL
    END
  ) STORED,
  metadata jsonb NOT NULL DEFAULT '{}',
  first_seen_at timestamptz,
  last_seen_at timestamptz,
  inserted_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);
```

Observation tables should include collection timestamps and be eligible for Timescale hypertables when they keep history. Latest/current views can be implemented as SQL views or query patterns over the most recent snapshot. The implementation should preserve these observation concepts:

- `wifi_site_snapshots`: `(source_id, site_code, collection_timestamp)` with AP counts, up/down counts, JSONB model breakdowns, WLC summaries, AOS summaries, RADIUS cluster, server group, AAA profile, and batch ID.
- `wifi_access_point_observations`: `(source_id, device_uid, collection_timestamp)` plus site code, name, MAC, serial, IP, model, status, vendor/source metadata, and batch ID.
- `wifi_controller_observations`: `(source_id, device_uid, collection_timestamp)` plus site code, hostname, IP, MAC/base MAC, model, AOS version, chassis serial, PSU status, reboot/uptime fields, and batch ID.
- `wifi_radius_group_observations`: `(source_id, site_code, controller_device_uid nullable, collection_timestamp)` plus cluster, server group, all server groups, AAA profile, status, and batch ID.
- `wifi_fleet_history`: `(source_id, build_date)` plus total AP count, AP family counts, AP-325 count, percent 6xx, percent legacy, site count, and batch ID.
- `wifi_map_views`: saved SRQL query text plus visualization options, default dashboard flag, and timestamps.

Reference rows should include source hash/version metadata so unchanged airport/reference CSV content can be skipped on normal polling intervals.

Indexes should include:

- PostGIS GiST indexes on generated geography columns.
- B-tree indexes on source/site/time keys used by SRQL.
- Trigram or lower-case search indexes for device/site search fields if current SRQL search paths cannot satisfy hostname, MAC, serial, IP, site code, and site name search efficiently.

## Ingestion Flow

1. Customer publishes a signed WiFi-map plugin package and source index/manifest in their private Git repository.
2. ServiceRadar operator adds that repository as a customer plugin source and configures auth plus trust policy.
3. Core/web-ng syncs the source, verifies manifests/artifacts/signatures, mirrors package content into ServiceRadar plugin storage, and stages the package for review.
4. Operator reviews capabilities, seed-file permissions, network allowlists, and config schema, then approves and assigns the plugin to agents.
5. Agent executes the customer WiFi-map plugin.
6. Plugin reads CSV seed files or collects from Aruba controllers.
7. Plugin validates and normalizes records, sends slowly changing reference data only when refreshed/changed, then emits a structured map batch.
8. Agent sends plugin result to agent-gateway.
9. Agent-gateway forwards the result to core-elx without interpreting the WiFi schema.
10. Core-elx validates the batch version and source kind.
11. Core-elx upserts airport/site references, sites, observations, RADIUS mappings, history rows, and OCSF device identities for device-like seed records in a transaction per bounded batch.
12. SRQL queries read normalized tables and saved map view settings.
13. Dashboard and full-screen map render SRQL results.

## Risks / Trade-Offs

- Plugin payload size may exceed current plugin-result limits. Mitigation: chunk batches by entity/site or use object-store handoff if measurement shows the full seed is too large.
- Customer source credentials and signing keys are sensitive. Mitigation: store credentials as encrypted secret references, never expose them to agents, and fail closed when trust policy verification fails.
- Customer repositories may contain multiple plugins or unexpected manifests. Mitigation: require explicit source paths, expected plugin IDs, manifest schema validation, and staged operator approval.
- The CSV map has aggregate strings such as `models` and `wlcs`. Mitigation: ingest both normalized child rows when available and preserve aggregate JSON for parity.
- Airport/site reference data may be large but changes slowly. Mitigation: use source hashes, separate refresh intervals, and idempotent reference-table upserts instead of sending it every poll.
- Customer plugin-specific data may not fit existing platform tables. Mitigation: do not allow plugin-driven DDL; keep this work on ServiceRadar-owned WiFi-map tables and evaluate constrained generic entity/observation tables separately if another plugin domain needs them.
- IATA-like site codes can collide with airport codes or represent non-airport sites. Mitigation: keep explicit `site_type` and manual overrides as first-class data.
- RADIUS collection via SSH/mdconnect may be slow. Mitigation: keep it optional, independently scheduled, and merged by site/controller timestamp.
- `add-unifi-wifi-discovery-parity` overlaps conceptually with WiFi analytics. Mitigation: this change is site inventory/map focused and should later feed the vendor-neutral WiFi analytics model rather than duplicate RF/client analytics.

## Open Questions

- Should CSV seed files be packaged inside the customer plugin artifact for demos, mounted on the agent host with an explicit `read_file` capability, or fetched by the plugin through an approved object/source reference?
- Should the first customer plugin implementation import `sites.csv` directly, or should it rebuild `sites.csv` from lower-level AP/WLC/RADIUS CSVs inside the plugin for better lineage? Current direction: support both, with direct generated CSV import required for initial production seeding and Go rebuild logic preferred once API collection is enabled.
- Should `wifi_site_snapshots` store AP model and WLC model breakdowns as JSONB only, or also maintain normalized breakdown tables for faster SRQL grouping?
- Should dashboard map tile providers reuse existing Mapbox settings only, or support an OSM/Carto fallback for environments without Mapbox tokens?
- What retention should apply to AP/controller observations after the map reaches parity: latest-only, 90-day history, or Timescale downsampling?
- Should customer plugin source sync support arbitrary Git servers only, or provider-specific APIs for Forgejo/GitHub/GitLab when available?
- What should the default slow refresh interval be for airport/site reference data: manual-only, daily, weekly, or source-hash-triggered only?
- If another customer plugin domain needs queryable custom data later, is a constrained generic entity/observation schema sufficient, or should it become another ServiceRadar-supported data contract like WiFi-map?
