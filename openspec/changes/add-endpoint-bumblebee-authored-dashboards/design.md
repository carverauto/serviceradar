## Context
ServiceRadar already has two relevant foundations:

- Authored dashboards: saved SRQL-backed dashboard records with panels, layouts, visibility, `/dashboard/:dashboard_id` routes, and `/dashboards` hub discovery.
- Endpoint inventory and Bumblebee exposure data: current-state inventory rows, scan/freshness metadata, risk contributions, Bumblebee posture, active findings, catalog provenance, and device-detail UI/API surfaces.

The requested dashboards are first-party product content on top of those foundations. They should be easy to discover and impressive enough to be a default operator workflow.

## Goals
- Ship two product-owned authored dashboard definitions that appear in `/dashboards`.
- Use authored dashboard records and web-ng-owned visuals, not Dashboard SDK packages.
- Make the dashboards visually strong: summary cards, charts, severity/freshness treatments, drill-down tables, and polished empty states.
- Keep dashboard data access reusable through SRQL/Ash-backed query surfaces.
- Validate against demo data with local web-ng and Playwright screenshots before marking implementation complete.

## Non-Goals
- Building a new dashboard package renderer.
- Adding a separate dashboard runtime for first-party dashboards.
- Adding new inventory or Bumblebee collection behavior.
- Making these dashboards immutable. Operators may later clone or customize them if the authored dashboard system supports that workflow.

## Decisions

### Decision: Seed product-authored dashboards
The implementation will add a product seeder for authored dashboards, similar in lifecycle to existing first-party seeders, but targeting `AuthoredDashboard` and panel records instead of `DashboardPackage`.

Each product dashboard will have:

- A stable slug, such as `endpoint-inventory` and `bumblebee-exposure`.
- Product/system ownership metadata.
- Public or role-visible visibility appropriate for normal operators.
- Idempotent create/update semantics keyed by a stable product dashboard identifier.
- A definition version so product updates can be applied safely without losing user-created dashboards.

### Decision: Query through SRQL-backed surfaces
Dashboard panels should execute SRQL or a dashboard query abstraction that uses the same underlying SRQL/Ash support. The implementation should not place bespoke Ecto queries inside LiveView render paths.

If needed, this change will add SRQL coverage for:

- Endpoint inventory current scans, freshness, package counts, source summaries, package coordinates, vulnerability/risk summaries, and failed/stale scan states.
- Bumblebee posture, findings, finding severity counts, coverage state, scanner/catalog versions, and finding activity over time.

### Decision: Improve authored dashboard visuals as needed
If the current authored dashboard renderer cannot produce a high-quality dashboard for these data sets, the change should extend the shared visual system rather than hardcoding one-off panels.

Likely shared additions include:

- KPI/stat cards with thresholds, trend deltas, icons, and status captions.
- Severity distribution bars.
- Freshness or coverage bands.
- Category/grouped bar charts.
- Compact sparklines or trend lines.
- Tables with badge, boolean, severity, timestamp, and link renderers.
- Better empty, loading, and error states.

### Decision: Treat `/dashboards` as the product entry point
The dashboards must be visible from the `/dashboards` hub with clear labels and stable links. Their route should use the authored dashboard route (`/dashboard/:dashboard_id` or stable authored slug/reference), not `/dashboards/:route_slug` package hosting.

## Risks And Mitigations
- Risk: seeded dashboards overwrite operator customizations.
  - Mitigation: product dashboards are keyed and versioned; user-authored dashboards remain separate. Product updates should not mutate user-created clones.
- Risk: attractive dashboard panels require expensive queries.
  - Mitigation: use existing rollups, current-state tables, bounded SRQL, and maintained aggregates. Add missing reusable query surfaces instead of direct LiveView aggregates.
- Risk: demo has incomplete data for one dashboard.
  - Mitigation: render honest empty/partial states and validate visual layout with available demo data plus tests/fixtures for populated cases.
- Risk: authored visual improvements become one-off for these dashboards.
  - Mitigation: implement any new visuals as shared visual types/components with focused tests.

## Validation Plan
- Run `openspec validate add-endpoint-bumblebee-authored-dashboards --strict` for this proposal.
- During implementation, run `mix format`, `mix compile --warnings-as-errors`, and focused web-ng/core tests for seeders, SRQL, and LiveViews.
- Start local web-ng against demo CNPG with the `$demo-cnpg-local-web-ng` workflow.
- Use `$playwright-cli` to capture and inspect desktop/mobile screenshots for:
  - `/dashboards`
  - Endpoint Inventory authored dashboard
  - Bumblebee Exposure authored dashboard
- Confirm screenshots show non-empty, non-overlapping, polished visuals where demo data exists, and honest empty states where it does not.

