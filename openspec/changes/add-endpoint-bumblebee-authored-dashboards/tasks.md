## 1. Discovery And Design
- [ ] 1.1 Inspect current authored dashboard resources, seeding patterns, visual components, and `/dashboards` hub behavior.
- [ ] 1.2 Inventory current SRQL/query support for endpoint inventory scans, packages, risk summaries, Bumblebee posture, and Bumblebee findings.
- [ ] 1.3 Identify which panels can use existing query surfaces and which require reusable SRQL/Ash additions.

## 2. Product Dashboard Seeding
- [ ] 2.1 Add an idempotent product-authored-dashboard seeder with stable product identifiers and definition versions.
- [ ] 2.2 Seed the Endpoint Inventory dashboard as an authored dashboard with stable slug/reference, product ownership metadata, visibility, layout, panels, and descriptions.
- [ ] 2.3 Seed the Bumblebee Exposure dashboard as an authored dashboard with stable slug/reference, product ownership metadata, visibility, layout, panels, and descriptions.
- [ ] 2.4 Ensure seeded dashboards appear in `/dashboards` with clear authored/product labels and stable links.
- [ ] 2.5 Ensure product dashboard updates do not mutate unrelated user-authored dashboards or dashboard packages.

## 3. Endpoint Inventory Dashboard
- [ ] 3.1 Add panels for inventory coverage, scan freshness, stale/failed agents, package-source distribution, top packages, package-count outliers, vulnerability/risk posture, and recent inventory activity.
- [ ] 3.2 Add drill-down tables for stale collectors, high-risk devices, and package/risk details with badge/timestamp/link renderers.
- [ ] 3.3 Add honest empty and partial-data states for deployments without endpoint inventory data.

## 4. Bumblebee Exposure Dashboard
- [ ] 4.1 Add panels for scanner coverage, active finding count, highest severity distribution, high-risk devices, catalog snapshot adoption, partial coverage, and recent finding activity.
- [ ] 4.2 Add drill-down tables for active findings, partial scans, stale scans, and affected devices with severity/catalog/device links.
- [ ] 4.3 Add honest empty and partial-data states for deployments without Bumblebee scans or findings.

## 5. Dashboard Visual Runtime
- [ ] 5.1 Extend shared authored dashboard visual types only where needed for KPI tiles, severity bars, grouped/category charts, freshness/coverage visuals, sparklines, and polished tables.
- [ ] 5.2 Add or update visual binding validation so seeded dashboard definitions fail fast when required fields are missing.
- [ ] 5.3 Ensure visual components remain responsive and avoid text overlap on desktop and mobile.

## 6. Query Support
- [ ] 6.1 Add missing SRQL entities/fields or Ash-backed query helpers for endpoint inventory dashboard panels.
- [ ] 6.2 Add missing SRQL entities/fields or Ash-backed query helpers for Bumblebee dashboard panels.
- [ ] 6.3 Ensure dashboard panel queries are bounded and avoid direct broad aggregate scans from LiveView render paths.

## 7. Tests And Validation
- [ ] 7.1 Add unit tests for product dashboard seeding idempotence and update behavior.
- [ ] 7.2 Add SRQL/query tests for new endpoint inventory and Bumblebee dashboard query surfaces.
- [ ] 7.3 Add LiveView tests for `/dashboards` hub visibility and authored dashboard route loading.
- [ ] 7.4 Run `mix format` and `mix compile --warnings-as-errors`.
- [ ] 7.5 Run focused web-ng/core tests for dashboards, SRQL, and seeders.
- [ ] 7.6 Run local web-ng against demo CNPG with `$demo-cnpg-local-web-ng`.
- [ ] 7.7 Use `$playwright-cli` to validate `/dashboards` and both dashboard routes with desktop/mobile screenshots.

