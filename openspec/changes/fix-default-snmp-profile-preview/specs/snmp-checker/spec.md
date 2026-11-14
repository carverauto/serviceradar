## MODIFIED Requirements
### Requirement: SNMP profile target counts use SRQL evaluation
The system SHALL compute SNMP profile target counts by executing the normalized SRQL `target_query` and returning a distinct device count. The settings preview SHALL evaluate the same query the compiler compiles, so the preview count equals the compile count; only a failed inventory read renders as unknown.

#### Scenario: Device query count
- **GIVEN** a profile with `target_query: "in:devices tags.role:core"`
- **WHEN** the target count is evaluated
- **THEN** the count equals the number of devices that match the SRQL query

#### Scenario: Interface query reduces to distinct devices
- **GIVEN** a profile with `target_query: "in:interfaces type:ethernet"`
- **WHEN** the target count is evaluated
- **THEN** the count equals the number of distinct devices that have matching interfaces

#### Scenario: Preview equals compile count
- **GIVEN** a profile with `target_query: "in:devices tags.role:core"`
- **WHEN** the operator views the target preview in settings
- **THEN** the preview shows the same count the compiler would compile

#### Scenario: Unparseable or invalid query counts nothing
- **GIVEN** a profile with a `target_query` the SRQL parser rejects, or a filter value that cannot be cast
- **WHEN** the target count is evaluated
- **THEN** the count is zero, matching the compiler's match-nothing semantics
- **AND** the profile remains saveable

#### Scenario: Failed read stays unknown
- **GIVEN** a `target_query` that parses but whose inventory read fails
- **WHEN** the target count is evaluated
- **THEN** the preview reports unknown rather than a count

## ADDED Requirements
### Requirement: Seeded default SNMP profile targets all devices
The system SHALL seed a fresh install with exactly one enabled default SNMP profile whose `target_query` is `in:devices`, so every device no targeting profile claims is polled. Growth past the per-agent target limit is handled by the save-time and compile-time limit refusals plus the settings preview, never by silently narrowing the seed.

#### Scenario: Fresh install polls everything discovered
- **GIVEN** a fresh install with no SNMP profiles
- **WHEN** the seed migration runs
- **THEN** one enabled default profile exists with `target_query: "in:devices"`

### Requirement: Inline-credential SNMP targets keep resolving
The system SHALL continue to resolve SNMP targets and profiles whose credentials are stored as inline Cloak-encrypted fields, without requiring migration to reusable credential secrets. No automatic migration SHALL invent credential rule scopes the operator never approved.

#### Scenario: Legacy inline community still compiles
- **GIVEN** an SNMP target with an inline encrypted v2c community and no credential secret reference
- **WHEN** SNMP config is compiled
- **THEN** the target compiles with its stored community
