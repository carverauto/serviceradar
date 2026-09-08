## ADDED Requirements

### Requirement: No Internal Or Customer-Specific Content On The Public Docs Site

The public documentation site (`docs/docs/`, served at `docs.serviceradar.cloud`) SHALL
NOT contain internal infrastructure detail, credentials, internal tooling references,
dated dev-run snapshots, or content identifying a specific customer.

#### Scenario: Internal infrastructure detail is excluded

- **WHEN** any published documentation page is reviewed
- **THEN** it MUST NOT contain internal host names (for example `code.carverauto.dev`,
  `registry.carverauto.dev`, `staging.serviceradar.cloud`), real device IP addresses or
  hardware serial numbers, real user names, or internal-only tooling references (for
  example `Beads`/`bd`)
- **AND** environment-specific values are shown as placeholders (for example
  `<namespace>`, `<SERVICERADAR_HOST>`, `<token>`)

#### Scenario: Customer-specific runbooks are removed

- **WHEN** the documentation set is reviewed for customer-specific material
- **THEN** the WiFi-map local-compose runbook (proprietary single-customer content) MUST
  NOT be present on the public site
- **AND** any page that remains describes general product capability rather than one
  customer's deployment

#### Scenario: Demo-environment specifics are generalized

- **WHEN** a page references the demo environment
- **THEN** hardcoded demo namespaces, demo pod names, and dated demo benchmark/snapshot
  data are replaced with generic placeholders or removed

### Requirement: Single Source Of Truth For SDK And Plugin Development

SDK and WASM plugin authoring reference SHALL be maintained only on
`developer.serviceradar.cloud`. The public docs site SHALL carry conceptual overviews that
link to the developer portal rather than duplicating reference material.

#### Scenario: WASM plugin page is an overview, not a reference

- **WHEN** the WASM plugins page is viewed
- **THEN** it explains what WASM plugins are, the sandbox/capability model at a high level,
  the upload/import/approval workflow, and operator-facing deployment configuration
- **AND** it does NOT contain the manifest schema, result schema, host ABI, or SDK code
  samples, and instead links to `developer.serviceradar.cloud` for that reference

#### Scenario: SDK pages link to the developer portal

- **WHEN** a page covers `serviceradar-sdk-go`, `serviceradar-sdk-rust`, or
  `serviceradar-sdk-dashboard`
- **THEN** it gives a high-level description of the SDK and links to
  `developer.serviceradar.cloud`
- **AND** it does NOT duplicate SDK API reference or repository URLs

### Requirement: Network Topology Naming

The high-density topology feature SHALL be documented as "Network Topology". The term
"God-View" SHALL NOT appear in published prose, headings, page filenames, or the sidebar.

#### Scenario: Topology page uses the public name

- **WHEN** the topology documentation page is viewed
- **THEN** its title, headings, and prose use "Network Topology"
- **AND** "God-View"/"God View" does not appear in any published prose

#### Scenario: Code identifiers are preserved

- **WHEN** the page documents configuration an operator must set
- **THEN** code identifiers such as `SERVICERADAR_GOD_VIEW_ENABLED`, `GodViewStream`, and
  `god_view_disabled` are shown verbatim because they are the actual code names

### Requirement: Accurate Integration Status

Documentation SHALL describe the availability of each integration accurately and SHALL NOT
describe a supported integration as removed or retired when it is only disabled in a
specific environment.

#### Scenario: Trivy is documented as supported

- **WHEN** the Trivy integration page is viewed
- **THEN** it describes Trivy as a supported integration that is currently disabled in the
  demo environment, and explains how to enable and use it
- **AND** it does NOT instruct readers to recover the integration from git history

### Requirement: Robust SRQL Documentation

SRQL SHALL be documented as a multi-page section that supports both first-time learners and
experienced users: a guided tutorial, a complete reference, and a task-oriented cookbook.

#### Scenario: A new user can learn SRQL from a tutorial

- **WHEN** a new user opens the SRQL tutorial
- **THEN** it walks them, with runnable examples, from a first query through filtering,
  time ranges, and querying across entities

#### Scenario: The SRQL reference is complete and accurate

- **WHEN** the SRQL reference is viewed
- **THEN** it documents the grammar, entities, filterable fields, operators, and functions
- **AND** it contains no references to nonexistent internal files (for example
  `entity_mapping.ml`) and entity names are consistent with the `in:` query syntax

#### Scenario: A cookbook provides task-oriented recipes

- **WHEN** an operator needs a query for a common task
- **THEN** the SRQL cookbook provides copy-paste recipes for tasks such as finding devices,
  inspecting events and logs, and querying NetFlow and BGP data

### Requirement: Current Architecture Representation

Architecture descriptions and diagrams SHALL reflect the current ServiceRadar platform and
SHALL NOT reference retired components or stale APIs.

#### Scenario: Diagrams reflect the current platform

- **WHEN** any architecture or pipeline diagram is viewed
- **THEN** it represents the Elixir control plane, `agent-gateway`, CNPG (Postgres +
  Timescale + AGE), and NATS JetStream, and does not reference retired components such as
  Proton/ClickHouse or a Go-only core

#### Scenario: Retired APIs are not documented

- **WHEN** the device configuration documentation is viewed
- **THEN** it documents the current SRQL / web-ng query path and does not document the
  retired Go-core `/api/query` + `X-API-Key` HTTP API

### Requirement: Coherent Documentation Information Architecture

The documentation SHALL be organized into coherent, task-based sections, SHALL NOT publish
contributor-only or dev-only pages on the customer-facing site, and every page SHALL have
consistent frontmatter.

#### Scenario: Contributor-only pages are not on the public site

- **WHEN** the published documentation set is reviewed
- **THEN** contributor-only and dev-only pages (repository layout, Rust/Bazel dependency
  tooling, topology reset/rebuild, the camera-analysis reference worker, the CNPG PG18
  engineering upgrade runbook) are not present

#### Scenario: Pages have consistent frontmatter and navigation

- **WHEN** any documentation page is viewed
- **THEN** it has frontmatter with a `title` and appears under a task-based sidebar section
  (Start Here, Deploy, Edge & Agents, Integrations, Get Data In, Query & Analyze, Extend,
  Operate)

### Requirement: Accurate Platform Positioning

The documentation SHALL describe ServiceRadar consistently as an IT operations and network
management platform with built-in observability and security analytics, and SHALL NOT make
unverifiable claims.

#### Scenario: Positioning is consistent and current

- **WHEN** the docs landing page, the introduction page, and the site tagline are reviewed
- **THEN** each positions ServiceRadar as an IT operations and network management platform
  with observability and security analytics, rather than only "a distributed network
  monitoring system"

#### Scenario: Landing page is clean and honest

- **WHEN** the docs landing page is viewed
- **THEN** feature highlights use themed icons rather than emoji
- **AND** the page contains no unverifiable usage statistics (installation counts, node
  counts, uptime figures)

### Requirement: Consistent Visual Theme Across ServiceRadar Web Properties

The documentation site SHALL use the same color palette and visual identity as the
ServiceRadar web application (`serviceradar-web`), so that the docs site, the web app, and
the developer portal present one consistent design theme.

#### Scenario: Docs site uses the shared palette

- **WHEN** the documentation site is rendered in light or dark mode
- **THEN** its primary, surface, and text colors are derived from the `serviceradar-web`
  palette tokens (light primary `#0369a1`, dark primary `#38bdf8`; navy dark base
  `#132033`)
- **AND** the stock Docusaurus indigo primary is no longer used

#### Scenario: Code blocks use a coordinated theme

- **WHEN** a code block is rendered
- **THEN** the Dracula prism theme is not used, the dark theme suits the navy base, and the
  monospace font matches `serviceradar-web`

#### Scenario: Palette source of truth is recorded

- **WHEN** the docs theme styles are reviewed
- **THEN** they cite `serviceradar.cloud` as the authoritative reference for the shared
  ServiceRadar palette

### Requirement: Docs Site Builds Without Broken Links

The documentation site SHALL build successfully with no broken internal links, and removed
or renamed pages SHALL have redirects so existing external links continue to resolve.

#### Scenario: Build passes with broken-link enforcement

- **WHEN** the Docusaurus build is run with `onBrokenLinks: throw`
- **THEN** the build completes successfully with zero broken internal links

#### Scenario: Removed and renamed pages redirect

- **WHEN** an external link points to a removed or renamed page (for example the former
  `god-view-topology` slug)
- **THEN** a redirect resolves it to the current page or an appropriate replacement
