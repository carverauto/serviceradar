## 1. Discovery And Design
- [x] 1.1 Inspect current authored dashboard resources, seeding patterns, visual components, and `/dashboards` hub behavior.
- [x] 1.2 Inventory current SRQL/query support for endpoint inventory scans, packages, risk summaries, OCSF scan activity, OCSF findings, and source-specific Bumblebee/Falco/Trivy/package-discovery data.
- [x] 1.3 Identify which panels and Security page sections can use existing query surfaces and which require reusable SRQL/Ash additions.

## 2. Product Dashboard Seeding
- [x] 2.1 Add an idempotent product-authored-dashboard seeder with stable product identifiers and definition versions.
- [x] 2.2 Seed the Endpoint Inventory dashboard as an authored dashboard with stable slug/reference, product ownership metadata, visibility, layout, panels, and descriptions.
- [x] 2.3 Seed the Security Findings / Bumblebee Exposure dashboard as an authored dashboard with stable slug/reference, product ownership metadata, visibility, layout, panels, and descriptions.
- [x] 2.4 Ensure seeded dashboards appear in `/dashboards` with clear authored/product labels and stable links.
- [x] 2.5 Ensure product dashboard updates do not mutate unrelated user-authored dashboards or dashboard packages.

## 3. Endpoint Inventory Dashboard
- [x] 3.1 Add panels for inventory coverage, scan freshness, stale/failed agents, package-source distribution, top packages, package-count outliers, vulnerability/risk posture, and recent inventory activity.
- [x] 3.2 Add drill-down tables for stale collectors, high-risk devices, and package/risk details with badge/timestamp/link renderers.
- [x] 3.3 Add honest empty and partial-data states for deployments without endpoint inventory data.

## 4. Security Page And Security Findings Dashboard
- [x] 4.1 Add a top-level Security sidebar navigation item and canonical Security page route.
- [x] 4.2 Add Security page sections for OCSF scan activity, OCSF DNS Activity, active findings, severity distribution, finding class/source breakdown, affected devices/resources, and dashboard links.
- [x] 4.3 Add dashboard panels for scanner coverage, active finding count, highest severity distribution, finding class distribution, high-risk devices, catalog snapshot adoption where applicable, partial coverage, and recent finding activity.
- [x] 4.4 Add drill-down tables for active findings, partial scans, stale scans, and affected devices with severity/catalog/source/device links.
- [x] 4.5 Add honest empty and partial-data states for deployments without security scans or findings.

## 5. OCSF Security Event Mapping
- [x] 5.1 Add or update shared OCSF `1.9.0-dev` mapping helpers for `Scan Activity` (`class_uid: 6007`) scanner lifecycle events.
- [x] 5.2 Add or update shared OCSF `1.9.0-dev` mapping helpers for `Vulnerability Finding`, `Compliance Finding`, `Detection Finding`, and `Application Security Posture Finding`.
- [x] 5.3 Update Bumblebee to emit `Scan Activity` for scan lifecycle and OCSF Findings for security outcomes.
- [x] 5.4 Ensure Falco, Trivy, and endpoint package discovery use the shared mapping path or are compatible with the new Security query surface.
- [x] 5.5 Preserve inventory correlation metadata for Bumblebee, Falco, Trivy, and endpoint package discovery signals so findings can resolve to `ocsf_devices` through device UID, agent ID, hostname, or IP where available.

## 6. Dashboard Visual Runtime
- [x] 6.1 Extend shared authored dashboard visual types only where needed for KPI tiles, severity bars, grouped/category charts, freshness/coverage visuals, sparklines, and polished tables.
- [x] 6.2 Add or update visual binding validation so seeded dashboard definitions fail fast when required fields are missing.
- [x] 6.3 Ensure visual components remain responsive and avoid text overlap on desktop and mobile.

## 7. Query Support
- [x] 7.1 Add missing SRQL entities/fields or Ash-backed query helpers for endpoint inventory dashboard panels.
- [x] 7.2 Add missing SRQL entities/fields or Ash-backed query helpers for OCSF scan activity, OCSF DNS Activity, and security finding panels/pages.
- [x] 7.3 Ensure Security page and dashboard panel queries are bounded and avoid direct broad aggregate scans from LiveView render paths.
- [x] 7.4 Resolve Security page finding rows to inventory devices and link to device details when producer metadata can identify the affected device.

## 8. Tests And Validation
- [x] 8.1 Add unit tests for product dashboard seeding idempotence and update behavior.
- [x] 8.2 Add SRQL/query tests for new endpoint inventory, OCSF scan activity, OCSF DNS Activity, and OCSF security finding query surfaces.
- [x] 8.3 Add tests for shared OCSF security mapping helpers and producer-specific mappings where practical.
- [x] 8.4 Add LiveView tests for sidebar Security nav, `/security`, `/dashboards` hub visibility, and authored dashboard route loading.
- [x] 8.5 Run `mix format` and `mix compile --warnings-as-errors`.
- [x] 8.6 Run focused web-ng/core tests for Security page, dashboards, SRQL, mappings, and seeders.
- [x] 8.7 Run local web-ng against demo CNPG with `$demo-cnpg-local-web-ng`.
- [x] 8.8 Use `$playwright-cli` to validate `/security`, `/dashboards`, and both dashboard routes with desktop/mobile screenshots.

## 9. Operator Documentation
- [x] 9.1 Document Helm setup and verification for Falco/Falcosidekick sidecar ingestion into ServiceRadar security events.
- [x] 9.2 Document Docker Compose setup and verification for Falco/Falcosidekick sidecar ingestion into a local ServiceRadar stack.
- [x] 9.3 Document Helm setup and verification for Trivy Operator report ingestion through `serviceradar-trivy-sidecar`.
- [x] 9.4 Document Docker Compose setup and verification for `serviceradar-trivy-sidecar` watching a Kubernetes cluster while publishing to a local ServiceRadar stack.
