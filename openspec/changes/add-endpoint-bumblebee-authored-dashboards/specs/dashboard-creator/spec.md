## ADDED Requirements

### Requirement: Product-Seeded Authored Dashboards
The system SHALL support first-party product-authored dashboard definitions that are seeded as authored dashboards, not as Dashboard SDK packages.

#### Scenario: Product dashboard is seeded as authored dashboard
- **GIVEN** the ServiceRadar product dashboard seeder runs
- **WHEN** the Endpoint Inventory and Bumblebee Exposure definitions are absent
- **THEN** the system SHALL create authored dashboard records for both dashboards
- **AND** it SHALL NOT create or mutate `DashboardPackage` records for those dashboards.

#### Scenario: Product dashboard seed is idempotent
- **GIVEN** a product-authored dashboard already exists with the current product definition version
- **WHEN** the product dashboard seeder runs again
- **THEN** it SHALL leave the dashboard and panels semantically unchanged
- **AND** it SHALL NOT duplicate dashboards or panels.

#### Scenario: Product dashboard updates are versioned
- **GIVEN** a product-authored dashboard exists with an older product definition version
- **WHEN** a newer product definition is available
- **THEN** the seeder SHALL update the product-owned dashboard definition safely
- **AND** it SHALL NOT mutate unrelated user-created authored dashboards.

### Requirement: Product Dashboards Appear In Dashboard Hub
The `/dashboards` hub SHALL list the Endpoint Inventory and Bumblebee Exposure product-authored dashboards when the current user is authorized to view dashboards.

#### Scenario: Operator sees product dashboards
- **GIVEN** the Endpoint Inventory and Bumblebee Exposure dashboards have been seeded
- **WHEN** an authorized operator opens `/dashboards`
- **THEN** both dashboards SHALL appear with clear product/authored labels, descriptions, and stable links
- **AND** the links SHALL open the authored dashboard route rather than `/dashboards/:route_slug` package hosting.

#### Scenario: Dashboard search finds product dashboards
- **GIVEN** the product-authored dashboards have been seeded
- **WHEN** an authorized operator searches dashboards with `in:dashboards title:%inventory%` or `in:dashboards title:%bumblebee%`
- **THEN** matching product-authored dashboards SHALL be returned
- **AND** result rows SHALL identify them as authored dashboards.

### Requirement: Endpoint Inventory Authored Dashboard
The system SHALL ship a first-party Endpoint Inventory authored dashboard that visualizes fleet endpoint software inventory posture with polished summary, chart, and drill-down panels.

#### Scenario: Endpoint inventory dashboard summarizes fleet posture
- **GIVEN** endpoint inventory scan data exists
- **WHEN** an authorized operator opens the Endpoint Inventory dashboard
- **THEN** the dashboard SHALL show inventory coverage, fresh/stale/failed scan counts, current package/device counts, package source distribution, top package coordinates, and risk posture
- **AND** the summary SHALL use visual treatments such as KPI cards, status badges, charts, and freshness indicators rather than only a raw table.

#### Scenario: Endpoint inventory dashboard exposes stale collectors
- **GIVEN** one or more agents have stale, failed, or missing endpoint inventory scans
- **WHEN** the Endpoint Inventory dashboard renders
- **THEN** it SHALL provide a drill-down panel listing affected agents/devices, freshness verdict, last scan time, and bounded error or status information.

#### Scenario: Endpoint inventory dashboard has honest empty state
- **GIVEN** no endpoint inventory scans exist in the deployment
- **WHEN** an authorized operator opens the Endpoint Inventory dashboard
- **THEN** the dashboard SHALL show an explicit no-data state
- **AND** it SHALL NOT imply that the fleet has no packages or no endpoint risk.

### Requirement: Security Findings Authored Dashboard
The system SHALL ship a first-party Security Findings / Bumblebee Exposure authored dashboard that visualizes fleet scanner coverage and active OCSF security findings with polished summary, chart, and drill-down panels.

#### Scenario: Bumblebee dashboard summarizes exposure posture
- **GIVEN** OCSF `Scan Activity` or OCSF security finding data exists from Bumblebee, Falco, Trivy, or endpoint package discovery
- **WHEN** an authorized operator opens the Bumblebee Exposure dashboard
- **THEN** the dashboard SHALL show scanner coverage, active finding count, highest severity distribution, finding class distribution, high-risk devices, catalog snapshot adoption where applicable, partial coverage counts, and recent finding activity
- **AND** the summary SHALL use visual treatments such as KPI cards, severity bars, charts, timelines, and status badges rather than only a raw table.

#### Scenario: Bumblebee dashboard exposes active findings
- **GIVEN** one or more active OCSF security findings exist
- **WHEN** the Bumblebee Exposure dashboard renders
- **THEN** it SHALL provide a drill-down panel listing source, OCSF class, affected device/resource, severity, catalog or rule ID where available, ecosystem/package identity where available, status, first seen, last seen, and a link or action to inspect the corresponding device or event when available.

#### Scenario: Bumblebee dashboard distinguishes unscanned from clean
- **GIVEN** a deployment has agents without completed Bumblebee scans
- **WHEN** the Bumblebee Exposure dashboard renders coverage
- **THEN** it SHALL distinguish full clean scans, partial scans, stale scans, failed scans, and never-scanned agents
- **AND** it SHALL NOT present never-scanned or partial-coverage agents as clean.

#### Scenario: Dashboard separates scan activity from security findings
- **GIVEN** both OCSF `Scan Activity` and OCSF `Findings` events exist
- **WHEN** the Security Findings / Bumblebee Exposure dashboard renders
- **THEN** scanner execution panels SHALL use scan activity data
- **AND** security outcome panels SHALL use OCSF Findings data
- **AND** the dashboard SHALL NOT count scanner failures as vulnerabilities or findings unless a producer emitted a corresponding OCSF Finding.

### Requirement: Product Dashboard Visual Quality
Product-authored dashboards SHALL meet a visual quality baseline suitable for first-run operator workflows.

#### Scenario: Dashboard uses dashboard-native visuals
- **GIVEN** the Endpoint Inventory or Bumblebee Exposure dashboard renders with representative data
- **WHEN** an operator views the dashboard on desktop
- **THEN** the first viewport SHALL include meaningful visual hierarchy, summary cards, charts or distribution visuals, and concise drill-down affordances
- **AND** it SHALL NOT be composed only of unstyled tables.

#### Scenario: Dashboard is responsive
- **GIVEN** the Endpoint Inventory or Bumblebee Exposure dashboard renders on a mobile viewport
- **WHEN** Playwright captures the page
- **THEN** panel text, charts, controls, and tables SHALL not overlap incoherently
- **AND** the dashboard SHALL remain navigable without horizontal page-level overflow.

#### Scenario: Dashboard handles loading and errors
- **GIVEN** a product-authored dashboard panel is loading or a bounded query fails
- **WHEN** the dashboard renders
- **THEN** the panel SHALL show a clear loading or error state with bounded detail
- **AND** sibling panels SHALL continue rendering when possible.
