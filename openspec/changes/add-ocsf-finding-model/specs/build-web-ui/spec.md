## ADDED Requirements
### Requirement: Security dashboard uses canonical findings
The web-ng security dashboard SHALL render security posture from canonical finding rows instead of treating event occurrences as active findings. The dashboard SHALL summarize active findings by severity, class, source, entity correlation, and status, and SHALL provide drilldowns from each finding to its related event occurrences.

#### Scenario: Active finding count is deduplicated
- **GIVEN** one Falco detection finding has ten event occurrences
- **WHEN** an operator opens the security dashboard
- **THEN** the active finding count SHALL include that detection once
- **AND** the finding detail SHALL expose the ten related occurrences through drilldown

#### Scenario: Finding detail preserves event access
- **GIVEN** an operator opens a detection finding detail view
- **WHEN** related event occurrences exist
- **THEN** the UI SHALL provide access to the raw occurrence events
- **AND** it SHALL keep the finding status, severity, evidence, and affected entity visible as the primary context
