## ADDED Requirements

### Requirement: Shared Sidebar Application Shell
The web-ng UI SHALL provide a reusable authenticated sidebar application shell for primary app routes. The shell MUST include persistent navigation, active route state, account controls, collapse behavior, and responsive behavior for narrow viewports while keeping the navigation model defined in one project-owned place.

#### Scenario: Dashboard renders inside the shell
- **GIVEN** an authenticated operator can access the dashboard route
- **WHEN** the dashboard page renders
- **THEN** the page is framed by the shared sidebar shell
- **AND** the dashboard navigation item is marked active

#### Scenario: Shell collapses without losing navigation
- **GIVEN** an authenticated operator is viewing a shell-backed route
- **WHEN** the sidebar is collapsed or the viewport becomes narrow
- **THEN** primary navigation remains available through the responsive shell controls
- **AND** page content does not overlap the shell controls

#### Scenario: Navigation model is not duplicated per page
- **WHEN** developers add or update a primary navigation item
- **THEN** the change is made in the shared shell/navigation model
- **AND** shell-backed routes consume the same navigation definition

### Requirement: Operations Dashboard Surface
The web-ng UI SHALL provide a dashboard surface for authenticated operators that combines operational KPI cards, asset posture cards, a network traffic map, security event trends, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset cards, and a SIEM alert feed region in a dense scannable layout.

#### Scenario: Operator opens the dashboard
- **GIVEN** an authenticated operator has dashboard access
- **WHEN** they navigate to the dashboard route
- **THEN** the UI displays operational KPI cards, asset posture cards, the network traffic map, security event trends, FieldSurvey/Wi-Fi heatmap region, camera operations panel, observability metrics, vulnerable asset cards, and a SIEM alert feed region
- **AND** all regions fit without incoherent overlap at supported desktop and mobile viewport widths

#### Scenario: Available metrics populate dashboard cards
- **GIVEN** health, inventory, or NetFlow summary data is available from existing ServiceRadar sources
- **WHEN** the dashboard loads
- **THEN** cards backed by those sources display current values for the selected time window
- **AND** each displayed value is labeled with its source context or time window

#### Scenario: Optional operational panels render honest unavailable states
- **GIVEN** camera fleet, Wi-Fi survey, or FieldSurvey data is not available in the deployment
- **WHEN** the dashboard renders the corresponding operational panel
- **THEN** the panel shows an explicit unavailable or empty state
- **AND** the UI does not display fabricated camera, Wi-Fi, or survey values

### Requirement: Dashboard Network Traffic Map
The dashboard SHALL render a deck.gl/luma network traffic map based on observed NetFlow/IPFIX summaries and SHALL support an animated MTR diagnostic overlay. The dashboard MUST NOT animate fake traffic when observed flow data is unavailable.

#### Scenario: Observed flows render as traffic animation
- **GIVEN** observed NetFlow/IPFIX summaries exist for the selected time window
- **WHEN** the dashboard traffic map renders
- **THEN** deck.gl/luma layers display directional traffic using those observed summaries
- **AND** visual intensity is derived from bounded flow metrics such as bytes, packets, flow count, or rate

#### Scenario: No observed flows avoids fake animation
- **GIVEN** no observed flow summaries exist for the selected time window
- **WHEN** the dashboard traffic map renders
- **THEN** the map shows an empty or unavailable state
- **AND** it does not synthesize animated traffic arcs or packet movement

#### Scenario: MTR overlay animates diagnostic evidence
- **GIVEN** recent MTR diagnostic summaries exist for paths visible on the dashboard map
- **WHEN** the MTR overlay is enabled
- **THEN** deck.gl/luma layers animate diagnostic path evidence
- **AND** latency, loss, or route-change state is visually distinguishable from NetFlow traffic animation

### Requirement: Dashboard Security Feed Placeholders
The dashboard SHALL include vulnerable asset and SIEM alert regions as explicit placeholder surfaces until follow-up OpenSpec proposals define real vulnerability tracking and SIEM feed ingestion behavior.

#### Scenario: Vulnerable asset feed is not implemented
- **GIVEN** no approved vulnerable asset tracking capability exists
- **WHEN** the dashboard renders vulnerable asset cards
- **THEN** the cards present an explicit unconnected or empty state
- **AND** the UI does not display fabricated vulnerable asset counts

#### Scenario: SIEM alert feed is not implemented
- **GIVEN** no approved SIEM alert ingestion capability exists
- **WHEN** the dashboard renders the SIEM alert feed region
- **THEN** the region presents an explicit unconnected or empty state
- **AND** the UI does not display fabricated alerts
