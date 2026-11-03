## ADDED Requirements
### Requirement: Security dashboard uses canonical findings
The web-ng security dashboard SHALL render security posture from canonical finding rows instead of treating event occurrences as active findings. The dashboard SHALL summarize active findings by severity, class, source, entity correlation, and status, and SHALL provide drilldowns from each finding to its related occurrences. Falco occurrence drilldown is specified by `add-falco-runtime-findings` (`in:runtime_security_occurrences`), not by a per-occurrence `ocsf_events` row.

#### Scenario: Active finding count is deduplicated
- **GIVEN** one Falco detection finding has ten occurrences
- **WHEN** an operator opens the security dashboard
- **THEN** the active finding count SHALL include that detection once
- **AND** the finding detail SHALL expose the ten related occurrences through drilldown

#### Scenario: Finding detail preserves event access
- **GIVEN** an operator opens a detection finding detail view
- **WHEN** related occurrences exist
- **THEN** the UI SHALL provide access to the related occurrences
- **AND** it SHALL keep the finding status, severity, evidence, and affected entity visible as the primary context
