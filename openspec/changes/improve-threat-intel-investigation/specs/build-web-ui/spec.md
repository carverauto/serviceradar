## ADDED Requirements

### Requirement: Dashboard Threat Intel Summary Opens Evidence

The operations dashboard Threat Intel summary SHALL navigate to the dedicated
threat-intelligence investigation workspace, while provider configuration remains
available through a separate, explicit management action.

#### Scenario: Operator activates threat summary

- **GIVEN** the dashboard displays imported IOCs or current matches
- **WHEN** the operator activates the Threat Intel summary body
- **THEN** the UI SHALL navigate to `/security/threat-intel`
- **AND** it SHALL preserve the dashboard time context when applicable

#### Scenario: Administrator activates Manage

- **GIVEN** the operator can manage plugin assignments
- **WHEN** the operator activates the Threat Intel `Manage` command
- **THEN** the UI SHALL navigate to `/settings/networks/threat-intel`
- **AND** the investigation action and management action SHALL have distinct
  accessible labels and focus targets

### Requirement: Threat Intel Investigation UI Is Actionable And Bounded

The web UI SHALL render current matches, match detail, imported inventory, and
retrohunt evidence as bounded, paginated investigation views with URL-backed
filters and actionable flow pivots.

#### Scenario: Operator selects a matched endpoint

- **GIVEN** a current match row is visible
- **WHEN** the operator selects the row
- **THEN** the UI SHALL open match detail without losing page and filter state
- **AND** detail SHALL provide commands to view normal and attributed matching
  flows

#### Scenario: More matches exist than one page

- **GIVEN** the result set exceeds the configured page size
- **WHEN** the operator navigates pages
- **THEN** the UI SHALL use deterministic keyset pagination
- **AND** it SHALL NOT load the full match corpus into LiveView assigns

#### Scenario: Settings shows evidence summary

- **GIVEN** an administrator opens threat-intel settings
- **WHEN** current or historical matches exist
- **THEN** settings SHALL show concise operational counts and a link to
  `/security/threat-intel`
- **AND** it SHALL NOT duplicate the full paginated investigation workspace

### Requirement: Threat Intel Max IOC Controls Are Removed

The Threat Intel settings and assignment UI SHALL NOT expose an independent
`Max IOCs`, `max_iocs`, `max_indicators`, or `otx_max_indicators` control.

#### Scenario: Administrator edits OTX settings

- **GIVEN** the current release supports resumable page-based OTX collection
- **WHEN** an administrator opens deployment OTX settings or an OTX assignment
- **THEN** neither form SHALL display a Max IOCs field
- **AND** the forms SHALL continue to expose page, page-count, timeout, retry,
  interval, and other applicable safety controls

#### Scenario: Legacy assignment is edited

- **GIVEN** a stored assignment contains `max_iocs` or `max_indicators`
- **WHEN** an administrator loads and successfully saves the assignment
- **THEN** the assignment SHALL remain valid and retain all unrelated values
- **AND** the obsolete cap key SHALL be omitted from the newly persisted config
