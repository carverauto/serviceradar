## ADDED Requirements
### Requirement: OCSF findings are durable state
The system SHALL represent OCSF security findings as durable, stateful records distinct from event occurrences. Each finding SHALL have a stable `finding_info.uid`, class/category/type/activity identifiers, current status, severity, first-seen and last-seen timestamps, occurrence count, source identity, affected entity references, and the full OCSF finding payload needed to reconstruct the class-specific record.

#### Scenario: Repeated detection updates one finding
- **GIVEN** two Falco observations describe the same rule, device, and runtime entity
- **WHEN** both observations are promoted as security signals
- **THEN** the system SHALL keep one detection finding with the same `finding_info.uid`
- **AND** it SHALL update that finding's `last_seen` and occurrence count
- **AND** it SHALL retain separate event occurrences for the two observations

#### Scenario: Distinct vulnerabilities remain separate findings
- **GIVEN** one endpoint has two affected packages or CVEs
- **WHEN** vulnerability signals are ingested for both
- **THEN** the system SHALL create or update separate vulnerability findings keyed by their distinct vulnerability/package/entity dimensions

### Requirement: OCSF finding classes are modeled explicitly
The system SHALL support OCSF 1.9 finding classes 2002 vulnerability finding, 2003 compliance finding, 2004 detection finding, 2005 incident finding, 2006 data security finding, and 2007 application security posture finding. Class builders SHALL include OCSF-required fields for their class and SHALL preserve class-specific objects such as `vulnerabilities`, `compliance`, `attacks`, `evidences`, `finding_info_list`, `data_security`, `application`, and `remediation` when present.

#### Scenario: Vulnerability finding includes vulnerabilities
- **WHEN** a Trivy, advisory-feed, or endpoint-inventory package match becomes a vulnerability finding
- **THEN** the finding payload SHALL use class_uid `2002`
- **AND** it SHALL include OCSF vulnerability details and affected entity references

#### Scenario: Incident finding references constituent findings
- **WHEN** stateful alert logic groups multiple related findings into an incident
- **THEN** the incident finding payload SHALL use class_uid `2005`
- **AND** it SHALL include `finding_info_list` references for the constituent findings

### Requirement: Finding-producing events reference findings
Events that create, update, or close a security finding SHALL remain in `ocsf_events` as occurrence history and SHALL reference the affected finding through `finding_info.uid` or a structured equivalent. Non-finding activity events SHALL remain event-only and SHALL NOT require a finding record.

#### Scenario: Finding update records occurrence event
- **GIVEN** an existing vulnerability finding is observed again
- **WHEN** the producer processes the new observation
- **THEN** the finding SHALL be updated in the findings store
- **AND** an event occurrence SHALL be written that references the finding uid

#### Scenario: DNS activity stays event-only
- **WHEN** PowerDNS emits DNS Activity events
- **THEN** the system SHALL keep those records in `ocsf_events` as activity events
- **AND** it SHALL NOT create security findings unless a separate finding-producing rule explicitly does so

### Requirement: Security source mappings are class-correct
Security producers SHALL map to their OCSF finding classes by source semantics rather than by a generic event-shaped "finding" label. Falco runtime detections SHALL map to detection findings; Trivy, vulnerability advisory feeds, and endpoint package matches SHALL map to vulnerability findings; stateful incident groupings SHALL map to incident findings; future compliance, data security, and application posture producers SHALL map to their matching finding classes.

#### Scenario: Falco MITRE tags become structured ATT&CK data
- **WHEN** a Falco rule includes MITRE ATT&CK tags such as technique identifiers or tactic labels
- **THEN** the resulting detection finding SHALL expose structured ATT&CK `attacks` entries and supporting evidence
- **AND** raw source tags MAY still be preserved in unmapped/source metadata

#### Scenario: Scan activity does not become a finding
- **WHEN** a scanner run starts, succeeds, or fails
- **THEN** scan lifecycle records SHALL remain scan activity events
- **AND** only actual detected issues from that scan SHALL become findings
