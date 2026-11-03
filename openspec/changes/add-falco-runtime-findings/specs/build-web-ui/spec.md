## ADDED Requirements

### Requirement: Device page shows runtime security findings
The device detail page SHALL provide a Runtime security tab listing runtime findings whose subject or node is bound to the device, ordered active first, then by severity and last seen, with rule, subject, status, severity, occurrence counts, last seen and binding method.
The tab SHALL load only after the LiveView socket connects, SHALL page through SRQL, and SHALL render its list with LiveView streams.

#### Scenario: Workload finding appears on its node's page
- **GIVEN** a workload finding whose occurrences ran on a node bound to device `sr:00000000-0000-4000-8000-000000000001`
- **WHEN** an operator opens that device's Runtime security tab
- **THEN** the finding SHALL be listed with its workload subject and the node relationship

#### Scenario: Ambiguous finding is absent from device pages
- **GIVEN** a finding with `binding_status = ambiguous`
- **WHEN** an operator opens any device page
- **THEN** the finding SHALL NOT be listed there

### Requirement: Security page lists runtime findings by workload
The `/security` area SHALL provide a Runtime findings view filterable by cluster, namespace, owner, rule, status and binding status, grouping findings by workload, with an Unbound filter that shows ambiguous and unbound findings and their candidate counts.

#### Scenario: Operator finds every finding for one workload
- **WHEN** an operator filters the Runtime findings view to namespace `shop` and owner `cart`
- **THEN** the view SHALL list each rule firing on that workload as one row

### Requirement: Runtime finding detail explains the finding
The UI SHALL provide a runtime finding detail page showing the subject and its binding status, method and device link, attribution status, bounded samples, an hourly occurrence timeline, the latest occurrences with typed fields, a raw evidence viewer per occurrence (inline or streamed from the object store), lifecycle transitions, and resolve and suppress actions restricted by RBAC.
Alert detail SHALL link to the runtime finding detail when the alert's source event carries a runtime finding uid.

#### Scenario: Operator inspects raw evidence
- **GIVEN** a finding with stored occurrences
- **WHEN** an operator opens an occurrence's raw evidence
- **THEN** the UI SHALL display the stored raw payload and its digest
- **AND** for an occurrence stored out-of-line the UI SHALL stream the object through core and verify it against the referenced digest

#### Scenario: Missing evidence object is visible
- **GIVEN** an occurrence whose referenced evidence object is missing or fails its digest check
- **WHEN** an operator opens its raw evidence
- **THEN** the UI SHALL state that the evidence object is missing or corrupt with its key and digest
- **AND** the system SHALL raise a health event

#### Scenario: Alert links to its finding
- **GIVEN** an alert created by `falco_runtime_finding`
- **WHEN** an operator opens the alert detail
- **THEN** the UI SHALL link to the runtime finding detail page

#### Scenario: Unauthorized user cannot suppress
- **GIVEN** a user without the security management permission
- **WHEN** the user opens a runtime finding detail page
- **THEN** the resolve and suppress actions SHALL NOT be available
