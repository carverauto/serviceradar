## ADDED Requirements

### Requirement: Security Sidebar Section
The web-ng authenticated sidebar SHALL expose a top-level Security navigation section for security posture, scan activity, and findings workflows.

#### Scenario: Operator sees Security in sidebar
- **GIVEN** an authenticated operator is authorized to view security posture
- **WHEN** the operator opens the application shell
- **THEN** the sidebar SHALL include a Security navigation item
- **AND** activating it SHALL navigate to the canonical Security page.

#### Scenario: Security navigation is access controlled
- **GIVEN** a user lacks permission to view security posture
- **WHEN** the application shell renders
- **THEN** the Security navigation item SHALL be hidden or disabled according to the existing authorization pattern
- **AND** direct navigation to the Security page SHALL deny access without leaking security findings or scan activity data.

### Requirement: Security Page
The web-ng UI SHALL provide a canonical Security page that presents OCSF `Scan Activity`, OCSF security findings, OCSF `DNS Activity`, source coverage, and links to first-party security dashboards in a single operator workflow.

#### Scenario: Security page summarizes scanner and finding posture
- **GIVEN** OCSF scan activity, security finding, or DNS Activity events exist from Bumblebee, Falco, Trivy, endpoint package discovery, or PowerDNS
- **WHEN** an authorized operator opens the Security page
- **THEN** the page SHALL show scanner coverage, recent scan activity, DNS security activity, active finding count, severity distribution, finding class distribution, affected devices/resources, and source breakdown by producer
- **AND** it SHALL use visual treatments such as KPI cards, severity bars, timelines, source filters, and drill-down tables rather than only raw event JSON.

#### Scenario: Security page separates scan activity from findings
- **GIVEN** both OCSF `Scan Activity` and OCSF `Findings` events exist
- **WHEN** the Security page renders
- **THEN** scan lifecycle/status panels SHALL be visually and semantically distinct from finding/outcome panels
- **AND** failed or missing scans SHALL NOT be presented as clean security outcomes.

#### Scenario: Security page links to security dashboards and devices
- **GIVEN** the first-party Security Findings / Bumblebee Exposure dashboard has been seeded
- **WHEN** an operator opens the Security page
- **THEN** the page SHALL provide a stable link to that authored dashboard
- **AND** finding rows SHALL resolve affected device references from device UID, agent ID, hostname, or IP producer metadata where possible
- **AND** finding rows SHALL link to affected device detail pages or event detail pages when those references are available.

#### Scenario: Security page handles empty and partial data
- **GIVEN** no security scan activity or findings exist
- **WHEN** an authorized operator opens the Security page
- **THEN** the page SHALL show an explicit no-data state
- **AND** it SHALL NOT imply the deployment is secure or clean
- **AND** partial producer data SHALL identify which sources are present or absent.

#### Scenario: Security page is responsive
- **GIVEN** the Security page renders on desktop and mobile viewports
- **WHEN** Playwright captures the page
- **THEN** text, charts, controls, and tables SHALL not overlap incoherently
- **AND** the page SHALL remain navigable without horizontal page-level overflow.
