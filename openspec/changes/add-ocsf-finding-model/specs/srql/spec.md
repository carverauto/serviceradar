## ADDED Requirements
### Requirement: SRQL security findings entity
SRQL `in:security_findings` SHALL query the canonical OCSF findings entity rather than event-shaped occurrence rows. Results SHALL expose finding-level fields including `finding_info.uid`, `class_uid`, `class_name`, `status_id`, `status`, `severity_id`, `risk_score`, `confidence_id`, `source`, affected entity identifiers, `first_seen`, `last_seen`, `occurrence_count`, title/message, and class-specific payload summaries. SRQL SHALL support filtering security findings by class, source, severity, status, affected entity, and time.

#### Scenario: Security findings query returns deduplicated findings
- **GIVEN** three event occurrences update the same detection finding
- **WHEN** a client queries `in:security_findings source:falco`
- **THEN** SRQL SHALL return one finding row for that logical detection
- **AND** the row SHALL include occurrence count and first/last seen timestamps

#### Scenario: Class filter selects vulnerability findings
- **GIVEN** vulnerability and detection findings exist
- **WHEN** a client queries `in:security_findings class_uid:2002 sort:last_seen:desc`
- **THEN** SRQL SHALL return only vulnerability findings ordered by `last_seen`

### Requirement: SRQL finding event drilldown
SRQL or the web query layer SHALL provide a way to fetch event occurrences related to a specific finding without requiring clients to hand-parse OCSF JSON payloads.

#### Scenario: Related events fetched for finding
- **GIVEN** a finding with uid `finding:f1` has five referencing events
- **WHEN** a client requests the finding's related event drilldown
- **THEN** the response SHALL include those event occurrences ordered by time
- **AND** unrelated events SHALL be excluded
