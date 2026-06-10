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
- Normalize scanner lifecycle output into OCSF `1.9.0-dev` `Scan Activity` records and security outcomes into OCSF `1.9.0-dev` Findings records so the security data model remains vendor-neutral and queryable alongside other OCSF events.
- Add a Security navigation entry point for security findings and exposure posture rather than treating security posture as an Observability sub-pane.
- Validate against demo data with local web-ng and Playwright screenshots before marking implementation complete.

## Non-Goals
- Building a new dashboard package renderer.
- Adding a separate dashboard runtime for first-party dashboards.
- Adding new inventory or Bumblebee collection behavior.
- Adding a proprietary public Bumblebee finding schema.
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
- OCSF security findings, OCSF DNS Activity from DNS security producers such as PowerDNS, finding severity counts, finding classes, affected devices/resources, scanner/catalog metadata, and finding activity over time.
- Bumblebee scanner posture only as current-state operational context, not as the primary public finding schema.

### Decision: Represent scanner runs as OCSF Scan Activity
Bumblebee, Trivy, and scanner-like endpoint package discovery SHALL emit normalized OCSF `1.9.0-dev` `Scan Activity` events (`class_uid: 6007`, `category_uid: 6`) for scanner lifecycle and execution state. Scan lifecycle includes started, completed, cancelled, delayed, paused, resumed, duration violation, pause violation, and error states, mapped to the corresponding OCSF `activity_id` and `type_uid` values.

The `Scan Activity` event should carry scan execution details such as `scan`, `command_uid`, `schedule_uid`, `start_time`, `end_time`, `duration`, `total`, `num_detections`, `num_skipped_items`, status/status detail, scanner product metadata, and ServiceRadar metadata such as add-on id, agent id, run id, catalog snapshot ref, source instance, and gateway id.

### Decision: Represent security outcomes as OCSF Findings
Bumblebee, Falco, Trivy, and endpoint package discovery SHALL emit normalized OCSF `1.9.0-dev` events in category `Findings` (`category_uid: 2`) for actual security outcomes instead of exposing source-specific public finding event shapes. The mapping should choose the most specific OCSF class per result:

- `Application Security Posture Finding` (`class_uid: 2007`) for software/dependency/application posture issues, especially package or developer endpoint exposure findings.
- `Vulnerability Finding` (`class_uid: 2002`) for concrete weaknesses in an information system, control, or resource, including CVE-backed vulnerability results.
- `Compliance Finding` (`class_uid: 2003`) for benchmark, policy, expected-state, or coverage violations.
- `Detection Finding` (`class_uid: 2004`) for scanner-generated detections or alerts that are not more accurately posture, vulnerability, or compliance findings.

Falco runtime alerts are expected to map primarily to `Detection Finding`. Trivy vulnerability scan results are expected to map to `Vulnerability Finding`, while container/application posture results may map to `Application Security Posture Finding` and policy checks may map to `Compliance Finding`. Endpoint package discovery is inventory-first; it should only emit a Finding when package data is enriched into a real vulnerability, exposure, compliance, or posture condition.

Required OCSF fields such as `metadata`, `time`, `category_uid`, `class_uid`, `activity_id`, `severity_id`, and `finding_info` should be populated. ServiceRadar and scanner-specific fields such as source type, add-on id, agent id, run id, catalog snapshot ref, scanner version, package inventory identity, and evidence hashes should live in `metadata.service_radar`, `evidences`, `resources`, `observables`, or `unmapped` according to the closest OCSF fit.

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

### Decision: Add Security page and navigation
Security workflows should have a top-level Security section linked from the sidebar. The Security page should combine scanner activity, active findings, DNS security activity, severity/class breakdowns, affected devices, and links into the product-authored dashboards. Observability remains the place for logs, metrics, traces, flows, and raw event exploration, but security posture should not be hidden there as the primary UX.

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
