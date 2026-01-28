## MODIFIED Requirements
### Requirement: Default Zen Rules and Reconciliation
The system SHALL seed baseline Zen rules into each tenant schema during onboarding (including the platform tenant)
and SHALL reconcile stored Zen rules to datasvc KV from core-elx.
During reconciliation, the system SHALL treat datasvc connectivity issues as transient and avoid per-rule warning spam,
while still reporting actionable rule failures with rule identifiers and reasons.

#### Scenario: Tenant onboarding seeds Zen rules
- **WHEN** a tenant is created
- **THEN** the default Zen rules SHALL be inserted into the tenant schema
- **AND** each rule SHALL be eligible for KV sync without manual tooling

#### Scenario: Core-elx reconciles Zen rules
- **WHEN** core-elx starts or performs a scheduled reconciliation
- **THEN** active Zen rules in the database SHALL be re-published to KV

#### Scenario: Datasvc unavailable during reconcile
- **GIVEN** datasvc is unavailable or not ready
- **WHEN** core-elx runs Zen rule reconciliation
- **THEN** the system SHALL skip per-rule KV sync attempts
- **AND** the system SHALL log a single reconcile message indicating the transient failure

#### Scenario: Actionable rule failure during reconcile
- **GIVEN** datasvc is available
- **WHEN** a specific Zen rule fails to sync during reconciliation
- **THEN** the system SHALL log a warning that includes the rule identifier and error reason
- **AND** the reconcile cycle SHALL report a summary of failed rules
