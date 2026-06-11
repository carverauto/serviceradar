## ADDED Requirements

### Requirement: Trivy Vulnerability Reports Expose Child Findings
Trivy report ingestion SHALL expose individual vulnerability findings from each report, not only the aggregate report event.

#### Scenario: VulnerabilityReport has child vulnerabilities
- **GIVEN** a Trivy Operator `VulnerabilityReport` includes `report.vulnerabilities`
- **WHEN** the sidecar or downstream processor ingests the report
- **THEN** the aggregate report SHALL retain report lifecycle, resource, artifact, scanner, summary, and revision metadata
- **AND** each vulnerability entry SHALL be available as a child finding linked to the parent report
- **AND** the parent report SHALL include a stable way to query or navigate to those child findings

#### Scenario: Child vulnerability keeps remediation fields
- **GIVEN** a Trivy vulnerability entry includes `vulnerabilityID`, `severity`, `title`, `installedVersion`, `fixedVersion`, `links`, or `references`
- **WHEN** the child finding is normalized
- **THEN** those fields SHALL be preserved as first-class fields for query, sorting, alerting, display, and remediation workflows

### Requirement: Trivy Findings Preserve Workload And Image Scope
Trivy child findings SHALL preserve enough Kubernetes and artifact metadata for an operator to know what to fix.

#### Scenario: Workload and artifact metadata is available
- **GIVEN** a Trivy report includes resource labels, owner refs, namespace, container name, image repository, image tag, or Kubernetes UID
- **WHEN** child findings are normalized
- **THEN** each child finding SHALL carry the affected cluster, namespace, resource kind/name, owner kind/name/uid, container name, image repository/tag, and source report UID where available
- **AND** missing fields SHALL be explicitly absent rather than buried only in raw JSON

#### Scenario: Trivy finding prioritization is queryable
- **GIVEN** a Trivy report contains mixed critical, high, medium, low, and unknown vulnerabilities
- **WHEN** the findings are stored
- **THEN** operators SHALL be able to query and sort by severity, fixed-version availability, artifact/image, namespace, resource, CVE id, and KEV/exploit enrichment when available

### Requirement: Trivy Sidecar Publishes Signal Contracts
The Trivy sidecar package SHALL ship processor and display contracts for the Trivy report shapes it emits.

#### Scenario: VulnerabilityReport contract registered
- **GIVEN** the Trivy sidecar package is imported or installed
- **WHEN** the platform registers its signal contracts
- **THEN** the package SHALL provide a processor contract for `VulnerabilityReport`
- **AND** it SHALL provide a display contract that identifies report summary fields, child vulnerability path, resource pivots, remediation fields, and raw fallback behavior

#### Scenario: Unsupported report shape is diagnosable
- **GIVEN** Trivy emits a report kind or schema version without a registered contract
- **WHEN** the report is ingested or displayed
- **THEN** the system SHALL keep the raw report as audit data
- **AND** it SHALL surface a bounded diagnostic that no normalized contract was available
