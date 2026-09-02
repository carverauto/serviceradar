## ADDED Requirements
### Requirement: Operations Dashboard Drill-Down Actions
The `/dashboard` LiveView SHALL make summary cards and panels that represent drillable operational data clickable, with each action navigating to the most specific existing ServiceRadar page for the represented data. Range-enabled chart surfaces MAY reserve direct manipulation for range selection when general navigation remains available through a separate accessible View all action. Clickable dashboard elements MUST preserve keyboard access, visible focus, hover affordance, and readable light/dark theme styling.

#### Scenario: Top KPI cards open matching drill-ins
- **GIVEN** an authenticated operator is viewing `/dashboard`
- **WHEN** the operator activates the Total Assets, Threat Level, Network Health, Camera Fleet, or Wi-Fi Coverage KPI card
- **THEN** the UI SHALL navigate respectively to `/devices`, `/events`, `/services`, `/cameras`, or `/spatial/field-surveys`
- **AND** each card SHALL expose an accessible label that describes the drill-in target

#### Scenario: Rich dashboard panels are clickable
- **GIVEN** the dashboard renders the FieldSurvey heatmap, Threat Intel summary, Alerts Feed, and Observability Metrics panels
- **WHEN** the operator activates a panel-level summary or an individual metric card
- **THEN** the UI SHALL navigate to the existing detail surface for that data set
- **AND** nested existing links, such as camera preview tiles, alert rows, and FieldSurvey AP markers, SHALL continue to navigate to their more specific detail targets
- **AND** a range-enabled chart SHALL expose general navigation through a separate accessible View all action rather than making its direct-manipulation surface a navigation link

#### Scenario: NetFlow map stat strip opens flow detail views
- **GIVEN** the dashboard renders the NetFlow map stat strip with Window, Conversations, Flow Records, Traffic, and Geo Mapped stats
- **WHEN** the operator activates any stat
- **THEN** the UI SHALL navigate to an existing NetFlow or observability route with enough query state to show the relevant flow window or visualization mode
- **AND** the stat SHALL render with the same compact layout as before while exposing hover and focus states

#### Scenario: Empty states still offer useful navigation
- **GIVEN** a dashboard card or panel has no current data
- **WHEN** that card still has a useful detail or setup destination
- **THEN** the UI SHALL keep a non-range-enabled card clickable and navigate to that destination
- **AND** a range-enabled chart's empty state SHALL instead provide useful navigation through its separate accessible View all action without requiring the empty chart surface to be clickable
- **AND** the empty state copy SHALL remain readable without overlapping the clickable affordance
