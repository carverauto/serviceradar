## ADDED Requirements

### Requirement: Security Page Shows Actionable Scanner Findings
The Security page SHALL show concrete scanner findings and detections with extracted evidence, not only aggregate report events or links to raw Event Details pages.

#### Scenario: Trivy aggregate report drills into vulnerabilities
- **GIVEN** Trivy ingests a `VulnerabilityReport` with multiple vulnerability results
- **WHEN** an operator clicks the Trivy finding or report row on `/security`
- **THEN** the UI SHALL show the individual vulnerability rows from that report
- **AND** each row SHALL include CVE or advisory id, package or artifact name, installed version, fixed version where available, severity, affected workload/resource, image or target scope, namespace or cluster where available, and references or remediation fields where available
- **AND** the raw parent event SHALL be available as secondary audit context, not the only destination

#### Scenario: Falco detection drills into runtime evidence
- **GIVEN** Falco ingests a runtime alert
- **WHEN** an operator opens the detection from `/security`
- **THEN** the UI SHALL show rule name, priority/severity, source, output message, host, Kubernetes namespace/workload/pod/container where available, process and command evidence where available, user evidence where available, file or network evidence where available, and runbook/reference fields where available
- **AND** the raw event payload SHALL remain accessible for audit/replay

#### Scenario: Empty extracted fields are explicit
- **GIVEN** a scanner payload lacks fields required for the preferred finding display
- **WHEN** the finding detail renders
- **THEN** the UI SHALL show which evidence fields are unavailable
- **AND** it SHALL NOT silently collapse the finding to an unhelpful raw JSON page

### Requirement: Security Page Separates Report Lifecycle From Security Outcomes
The Security page SHALL distinguish scanner lifecycle or report summary events from concrete vulnerability, compliance, posture, and detection findings.

#### Scenario: Trivy report summary does not hide child findings
- **GIVEN** a Trivy report summary says it contains a count of findings
- **WHEN** the Security page renders the summary
- **THEN** it SHALL show the child finding count and worst severity
- **AND** it SHALL provide a direct drill-down to the child finding list

#### Scenario: Scanner failure is not counted as vulnerability
- **GIVEN** a scanner emits an error or failed scan activity event
- **WHEN** the Security page computes vulnerability totals
- **THEN** the failed scan SHALL be counted in scan health or coverage
- **AND** it SHALL NOT be counted as an active vulnerability unless a concrete finding exists

### Requirement: Security Page And Security Findings Dashboard Are Differentiated
The `/security` page and `/dashboards/security-findings` authored dashboard SHALL serve different operator workflows while sharing the same normalized security data.

#### Scenario: Security page is tactical
- **GIVEN** an operator opens `/security`
- **WHEN** active findings or scanner reports exist
- **THEN** the page SHALL prioritize actionable investigation queues, worst active findings, affected devices/workloads/images/packages, remediation fields, scanner health, stale coverage, and direct drill-down actions
- **AND** it SHALL NOT behave primarily as a customizable analytics dashboard

#### Scenario: Security findings dashboard is customizable posture
- **GIVEN** an operator opens `/dashboards/security-findings`
- **WHEN** normalized security data exists
- **THEN** the dashboard SHALL provide customizable posture and trend panels for severity distribution, finding class/source mix, KEV/exploit exposure, scan coverage, stale scanner data, top affected resources, and historical trends
- **AND** it SHALL link to `/security` for tactical investigation of selected findings or cohorts

#### Scenario: Surfaces do not duplicate each other
- **GIVEN** both `/security` and `/dashboards/security-findings` are available
- **WHEN** an operator compares them
- **THEN** `/security` SHALL provide workflow actions and prioritized drill-downs
- **AND** the authored dashboard SHALL provide configurable analytics panels
- **AND** both SHALL use the same underlying normalized finding and scan activity query surfaces

### Requirement: Security Summary Cards Drill Into Details
Security summary cards on `/security` and `/dashboards/security-findings` SHALL be actionable drill-down entry points unless there is a documented reason for a card to be informational only.

#### Scenario: Tactical security card opens scoped queue
- **GIVEN** `/security` displays a card such as critical findings, KEV exposure, stale scanner coverage, failed scans, top affected resource, Trivy vulnerabilities, or Falco detections
- **WHEN** an operator clicks the card
- **THEN** the page SHALL open or filter to the corresponding finding, scanner, device, workload, image, package, or coverage queue
- **AND** the resulting view SHALL preserve the card scope as visible filter context

#### Scenario: Dashboard card opens filtered analytics or investigation
- **GIVEN** `/dashboards/security-findings` displays a posture card or chart summary
- **WHEN** an operator clicks a card, segment, or row
- **THEN** the dashboard SHALL either drill into a filtered dashboard panel or link to `/security` with the corresponding investigation filters applied
- **AND** the destination SHALL use normalized finding and scan activity fields, not a raw event-only view

#### Scenario: Disabled card explains why
- **GIVEN** a card cannot drill down because no underlying rows exist or the data source is unavailable
- **WHEN** the card renders
- **THEN** it SHALL show an empty, unavailable, or disabled state with the reason
- **AND** it SHALL NOT appear as an active clickable control that leads to an empty generic page

### Requirement: Security Findings Link To Devices And Resources
Security findings SHALL provide investigation pivots to the affected device, workload, image, package, process, or raw event where available.

#### Scenario: Trivy vulnerability links to affected resource
- **GIVEN** a Trivy vulnerability finding has workload, image, package, and device correlation metadata
- **WHEN** the finding detail renders
- **THEN** the UI SHALL provide pivots to the affected device or workload, package/software context where available, image scope, and raw source event

#### Scenario: Falco detection links to affected resource
- **GIVEN** a Falco detection has host, Kubernetes, container, or process metadata
- **WHEN** the finding detail renders
- **THEN** the UI SHALL provide pivots to the affected device or workload, related process/container evidence, and raw source event

### Requirement: Event Viewer Renders Signal Display Contracts
The Event Viewer SHALL render integration-owned display contracts for scanner and add-on events before falling back to generic raw JSON.

#### Scenario: Trivy report uses display contract
- **GIVEN** a Trivy sidecar package or integration registers an event display contract
- **AND** an operator opens a Trivy report event
- **WHEN** the Event Viewer renders the event
- **THEN** it SHALL show a report summary with scanner name/version, resource, namespace, cluster, artifact repository/tag, update timestamp, severity counts, and worst severity
- **AND** it SHALL show child vulnerability rows when the payload contains a vulnerability list
- **AND** raw JSON SHALL remain available behind a secondary raw-data section

#### Scenario: Display contract highlights remediation
- **GIVEN** a Trivy vulnerability row has installed version, fixed version, severity, title, and references
- **WHEN** the Event Viewer or Security page renders the row
- **THEN** it SHALL surface those fields as actionable remediation data
- **AND** critical/high rows and rows with known exploit or KEV enrichment SHALL sort ahead of lower priority rows

#### Scenario: Missing display contract falls back safely
- **GIVEN** an event has no display contract or the contract does not match the payload
- **WHEN** the Event Viewer renders the event
- **THEN** it MAY fall back to the generic event layout and raw JSON
- **AND** it SHALL record a bounded diagnostic that the source did not provide a usable display contract
