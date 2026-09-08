## ADDED Requirements

### Requirement: Scanner Signals Preserve Extracted Evidence
Scanner integrations SHALL extract source-specific evidence into normalized OCSF fields and ServiceRadar metadata before events are stored, queried, or displayed.

#### Scenario: Trivy vulnerability report extracts child findings
- **GIVEN** a Trivy `VulnerabilityReport` payload contains multiple vulnerability results
- **WHEN** the report is ingested
- **THEN** the system SHALL preserve the report as scan/report context
- **AND** it SHALL create queryable child vulnerability findings for each result with CVE or advisory id, package/artifact, installed version, fixed version where available, severity, CVSS where available, target/image/workload scope, namespace/cluster metadata where available, references, and source report identity
- **AND** the parent report SHALL expose child finding counts and child finding query links instead of being the only user-visible record

#### Scenario: Trivy raw report fields are promoted
- **GIVEN** a Trivy payload contains `report.report.artifact`, `report.report.scanner`, `report.report.summary`, and `report.report.vulnerabilities`
- **WHEN** the report is ingested
- **THEN** repository, tag, scanner name/version, severity counts, update timestamp, vulnerability id, title, installed version, fixed version, links, references, and severity SHALL be available as normalized query/display fields
- **AND** operators SHALL NOT need to inspect raw JSON to learn what packages or versions need remediation

#### Scenario: Trivy compliance and posture results map to specific finding classes
- **GIVEN** a Trivy payload contains policy, benchmark, compliance, misconfiguration, secret, or application posture results
- **WHEN** the result is ingested
- **THEN** the system SHALL map it to the most specific OCSF finding class available
- **AND** it SHALL preserve rule id, title, resource, severity, expected/actual state where available, and remediation text where available

#### Scenario: Falco alert extracts runtime evidence
- **GIVEN** a Falco alert payload includes rule output and output fields
- **WHEN** the alert is ingested
- **THEN** the system SHALL create a Detection Finding with rule name, priority, source, output message, process/container/Kubernetes/host/user/file/network evidence where available, and ServiceRadar producer metadata
- **AND** raw output fields SHALL remain available for audit without being the primary UI contract

### Requirement: Scanner Findings Are Device And Resource Correlated
Scanner findings SHALL be correlated to inventory devices and affected resources whenever source metadata makes that possible.

#### Scenario: Trivy finding correlates to workload and device
- **GIVEN** a Trivy finding includes cluster, namespace, workload, pod, node, image, or package metadata
- **WHEN** the finding is normalized
- **THEN** the system SHALL populate affected resource metadata
- **AND** it SHALL attempt deterministic correlation to the canonical device, workload, or image identity before falling back to source-only identifiers

#### Scenario: Falco finding correlates to host and workload
- **GIVEN** a Falco alert includes hostname, node, Kubernetes, container, or process metadata
- **WHEN** the finding is normalized
- **THEN** the system SHALL populate affected resource metadata
- **AND** it SHALL attempt deterministic correlation to the canonical device or workload before falling back to source-only identifiers

### Requirement: Scanner Finding Identity And Dedupe Are Stable
Scanner findings SHALL use stable identities so repeated reports or replayed events do not inflate active finding counts.

#### Scenario: Replayed Trivy report does not duplicate findings
- **GIVEN** the same Trivy report revision is ingested more than once
- **WHEN** child vulnerability findings are normalized
- **THEN** their identities SHALL be stable for the same source report, affected resource, CVE or rule id, package/artifact, and installed version
- **AND** active finding counts SHALL NOT increase from replay alone

#### Scenario: Replayed Falco alert preserves occurrence history
- **GIVEN** Falco emits repeated alerts for the same rule and resource
- **WHEN** detections are normalized
- **THEN** the system SHALL use stable grouping fields for active finding or incident correlation
- **AND** it SHALL preserve occurrence timestamps without losing the latest evidence

### Requirement: Scanner Producers Ship Display Contracts
Scanner integrations SHALL provide display contracts that describe how scanner events and findings should be summarized in Event Viewer and security drill-down surfaces.

#### Scenario: Trivy contributes display contract
- **GIVEN** the Trivy sidecar or package is installed
- **WHEN** its signal contracts are registered
- **THEN** it SHALL include a display contract for Trivy vulnerability reports and child findings
- **AND** the contract SHALL describe report summary fields, vulnerability list path, remediation fields, resource pivots, severity ordering, and raw fallback behavior

#### Scenario: Falco contributes display contract
- **GIVEN** the Falco integration is installed
- **WHEN** its signal contracts are registered
- **THEN** it SHALL include a display contract for Falco detection findings
- **AND** the contract SHALL describe rule, priority, source, output fields, host/workload/container/process evidence, reference/runbook fields, and raw fallback behavior

#### Scenario: Display contract is versioned with source schema
- **GIVEN** a scanner integration updates its emitted payload schema
- **WHEN** it registers processor or display contracts
- **THEN** the display contract SHALL include a stable id, version, source schema reference, and compatibility rules
- **AND** Event Viewer SHALL be able to select the matching contract for stored events
