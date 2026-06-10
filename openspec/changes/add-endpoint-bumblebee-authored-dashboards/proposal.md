# Change: Add endpoint inventory and Bumblebee authored dashboards

## Why
Endpoint inventory and Bumblebee exposure data now exist as product data surfaces, but operators still have to hunt through device details, settings pages, and raw events to understand fleet posture. ServiceRadar needs first-party dashboards that are immediately useful in `/dashboards` and show inventory/security state with real visual treatment, not plain administrative tables.

These dashboards must use the authored dashboard system. They are product-shipped dashboard definitions, not Dashboard SDK packages or custom JavaScript renderers.

## What Changes
- Seed two product-owned authored dashboards:
  - Endpoint Inventory, focused on fleet package coverage, scan freshness, package/source distribution, inventory drift, vulnerable-package posture, and stale or failed collectors.
  - Bumblebee Exposure, focused on scanner coverage, active findings, severity distribution, high-risk devices, catalog snapshot adoption, partial coverage, and recent finding activity.
- Publish both dashboards into the `/dashboards` discovery hub with stable product slugs, clear type/source labels, and stable links under the authored dashboard route.
- Keep these dashboards separate from `DashboardPackage` and Dashboard SDK publishing; they SHALL be regular authored dashboard records managed by the product seeder.
- Add or extend authored dashboard visual components when the current runtime cannot render these dashboards well. Required visual quality includes KPI tiles, severity bars, grouped/category charts, trend or freshness visuals, polished tables with badges/sparklines, and useful empty/loading/error states.
- Ensure SRQL or dashboard-query support exists for the required endpoint inventory and Bumblebee panels, using existing Ash/SRQL/data-access patterns rather than LiveView-only ad hoc database queries.
- Add tests and visual validation using local web-ng against demo CNPG plus Playwright screenshots for `/dashboards` and both dashboard routes.

## Impact
- Affected specs: dashboard-creator, srql
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/**`
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_hub_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/authored_dashboard_live/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/authored_dashboard_live/panel_components.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/**`
  - `rust/srql/**` where new SRQL entities or fields are required
  - `elixir/serviceradar_core/lib/serviceradar/inventory/**` only as needed to expose existing inventory/Bumblebee data through reusable query surfaces

## Non-Goals
- Do not build these dashboards as Dashboard SDK packages.
- Do not add arbitrary custom JavaScript to authored dashboards.
- Do not create new endpoint collectors, Bumblebee scanners, catalog delivery paths, or ingest pipelines.
- Do not expose raw full local package inventories or sensitive filesystem evidence beyond existing approved inventory/Bumblebee data surfaces.
- Do not run broad unbounded aggregate queries directly from LiveView render paths.
- Do not replace the device detail Bumblebee or endpoint inventory panels; these dashboards are fleet-level complements.

