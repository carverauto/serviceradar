## ADDED Requirements
### Requirement: SNMP profile list shows target counts
The web-ng SNMP Profiles list SHALL display a target count for each profile based on executing the normalized SRQL `target_query`. When a count cannot be computed, the UI SHALL show "Unknown" instead of a misleading zero and surface the error state.

#### Scenario: List shows computed target counts
- **GIVEN** an admin viewing Settings → SNMP Profiles
- **WHEN** the list renders
- **THEN** each profile row shows "N targets" based on the SRQL target query

#### Scenario: Invalid query shows unknown
- **GIVEN** a profile with an invalid SRQL `target_query`
- **WHEN** the list renders
- **THEN** the targets column shows "Unknown"
- **AND** the UI indicates that the query could not be evaluated

### Requirement: Target preview labels align with targeting mode
The SNMP profile editor SHALL label target preview counts as device targets and indicate whether the SRQL query targets devices or interfaces. Empty or missing queries SHALL default to device targeting.

#### Scenario: Empty query defaults to device targeting
- **GIVEN** an SNMP profile with no `target_query`
- **WHEN** the editor renders the preview count
- **THEN** the UI indicates device targeting and displays the device target count

#### Scenario: Interface targeting indicator
- **GIVEN** an SNMP profile with `target_query: "in:interfaces type:ethernet"`
- **WHEN** the editor renders the preview count
- **THEN** the UI indicates interface targeting while still reporting device target counts
