## ADDED Requirements

### Requirement: Settings Navigation Groups
The web-ng Settings tree SHALL group pages by what they control, without
changing any page's route or permission:
- System → Platform: Cluster Status, Jobs, Data retention, Endpoint Inventory, Mail.
- System → Security: *Users & Access*; *Credentials* (API Credentials, MCP
  Sessions, Credentials and Rules); *Remote Access* (Session Recordings, Host
  Keys, Desktop Targets); *Threat Intelligence* (Threat Intel, Vulnerability Feeds).
- System → Alerts: Rules, Anomaly Detection, Notifications.
- System → Dashboards: Dashboard Packages, FieldSurvey.
- System → Personal: Profile, opened from the account menu.
- Network Services → Discovery: Composite Checks next to Availability Sources.
- Edge Ops → Sites & Collectors: Edge Sites, Data Collectors, Telemetry Onboarding.

#### Scenario: Remote access pages share one section
- **GIVEN** an operator permitted to see Session Recordings, Host Keys and Desktop Targets
- **WHEN** they open System → Security in the Settings tree
- **THEN** the three pages SHALL appear together under one *Remote Access* heading

#### Scenario: A moved page keeps its URL
- **GIVEN** a bookmark to `/settings/networks/credentials`
- **WHEN** an operator opens it after the regrouping
- **THEN** the Credentials and Rules page SHALL load
- **AND** the tree SHALL highlight it under System → Security → *Credentials*

#### Scenario: A moved page keeps its status cards
- **GIVEN** a page the regrouping moved, such as Credentials and Rules
- **WHEN** an operator opens it
- **THEN** it SHALL show the same status cards it showed before the move

#### Scenario: Subgroups do not split
- **WHEN** the catalog is validated in CI
- **THEN** every subgroup SHALL render as a single section of its parent group
