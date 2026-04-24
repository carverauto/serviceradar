## MODIFIED Requirements
### Requirement: Default Zen Rules and Reconciliation
The system SHALL seed baseline Zen rules into each tenant schema during onboarding (including the platform tenant), SHALL reconcile stored Zen rules to datasvc KV from core-elx, and SHALL reconcile shipped built-in Zen rule definitions into stored default rules when the stored rule still matches the built-in template contract.

#### Scenario: Tenant onboarding seeds Zen rules
- **WHEN** a tenant is created
- **THEN** the default Zen rules SHALL be inserted into the tenant schema
- **AND** each rule SHALL be eligible for KV sync without manual tooling

#### Scenario: Core-elx reconciles Zen rules
- **WHEN** core-elx starts or performs a scheduled reconciliation
- **THEN** active Zen rules in the database SHALL be re-published to KV

#### Scenario: Built-in SNMP rule definition changes
- **GIVEN** a deployment already contains the default `snmp_severity` Zen rule for `logs.snmp`
- **AND** that stored rule still uses the built-in template contract rather than a user-authored override
- **WHEN** the platform ships an updated built-in SNMP rule definition
- **THEN** the stored rule SHALL be updated to the new compiled definition without manual database edits
- **AND** subsequent SNMP traps SHALL use the corrected normalization behavior
