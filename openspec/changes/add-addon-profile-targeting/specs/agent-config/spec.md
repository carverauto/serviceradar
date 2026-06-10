## ADDED Requirements
### Requirement: Native Add-On Profiles
The agent configuration system SHALL support reusable native add-on profiles that target agents through SRQL-evaluated inventory scope instead of only manual per-agent assignment.

#### Scenario: Profile targets agents through SRQL
- **GIVEN** an enabled add-on profile with target query `in:devices hostname:"%ns%"`
- **AND** the query matches devices associated with enrolled agents
- **WHEN** add-on profile reconciliation runs
- **THEN** the system SHALL materialize add-on assignments for the matched eligible agents
- **AND** the next `AgentConfigResponse` for each matched agent SHALL include the add-on assignment.

#### Scenario: Profile precedence is deterministic
- **GIVEN** two enabled add-on profiles match the same agent and add-on id
- **WHEN** add-on profile reconciliation runs
- **THEN** the system SHALL choose the winning profile using deterministic priority and tie-break rules
- **AND** the selected profile id SHALL be inspectable from the resulting assignment.

#### Scenario: Ineligible agent is skipped with a reason
- **GIVEN** an add-on profile matches an agent whose platform or base agent version is incompatible with the selected package
- **WHEN** add-on profile reconciliation runs
- **THEN** the system SHALL NOT materialize a broken assignment for that agent
- **AND** the reconcile summary SHALL record the skipped agent and reason.

### Requirement: Native Add-On Artifact Delivery Boundary
The agent configuration system SHALL deliver native add-on and add-on catalog artifact references that agents fetch only through agent-gateway artifact delivery.

#### Scenario: Agent receives gateway artifact download material
- **GIVEN** a profile-derived add-on assignment uses a pushed artifact package
- **WHEN** the assignment is compiled into agent config
- **THEN** the config SHALL include a gateway artifact URL and short-lived token
- **AND** the agent SHALL NOT be required to contact web-ng or JetStream directly.
