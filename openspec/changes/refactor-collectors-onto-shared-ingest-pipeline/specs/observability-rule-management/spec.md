## MODIFIED Requirements

### Requirement: Zen Rule Persistence and KV Sync
The system SHALL persist Zen rule definitions in the tenant schema and SHALL publish compiled JDM payloads and the ordered rule index for the rule's subject to the datasvc KV store on create, update, and delete. The system SHALL also publish the effective rule bundle for each affected subject to the NATS rules bucket defined by `collector-rule-distribution` on create, update, and delete.

#### Scenario: Publish a new Zen rule
- **WHEN** a Zen rule is created
- **THEN** the compiled JDM SHALL be written to the KV path for the tenant
- **AND** the ordered rule index for its subject SHALL be updated
- **AND** the rule record SHALL store the KV revision metadata
- **AND** the bundle for its subject SHALL be written to the rules bucket with a digest that identifies its contents

#### Scenario: Disable a Zen rule
- **WHEN** a Zen rule is disabled
- **THEN** the KV entry SHALL be removed or marked inactive
- **AND** the rule record SHALL reflect the disabled state
- **AND** the bundle for its subject SHALL be republished to the rules bucket without that rule

#### Scenario: Delete a Zen rule
- **WHEN** a Zen rule is deleted
- **THEN** the KV entry SHALL be removed and the ordered rule index for its subject updated
- **AND** the bundle for its subject SHALL be republished to the rules bucket without that rule

### Requirement: Default Zen Rules and Reconciliation
The system SHALL seed baseline Zen rules into each tenant schema during onboarding (including the platform tenant)
and SHALL reconcile stored Zen rules to datasvc KV from core-elx.
Reconciliation SHALL also republish the effective rule bundle for each subject to the NATS rules bucket. It SHALL
keep republishing bundles to datasvc as well until no consumer reads bundles from datasvc, and not before one release
after the collector's NATS rules reader ships. Per-rule keys and the subject index are unaffected.
During reconciliation, the system SHALL treat datasvc connectivity issues as transient and avoid per-rule warning spam,
while still reporting actionable rule failures with rule identifiers and reasons.

#### Scenario: Tenant onboarding seeds Zen rules
- **WHEN** a tenant is created
- **THEN** the default Zen rules SHALL be inserted into the tenant schema
- **AND** each rule SHALL be eligible for KV sync without manual tooling

#### Scenario: Core-elx reconciles Zen rules
- **WHEN** core-elx starts or performs a scheduled reconciliation
- **THEN** active Zen rules in the database SHALL be re-published to KV
- **AND** the bundle for each subject SHALL be republished to the rules bucket
- **AND** when a consumer still reads bundles from datasvc, or one release has not yet passed since the collector's NATS rules reader shipped, the bundle SHALL also be republished to datasvc

#### Scenario: Rules bucket lost a bundle
- **GIVEN** a subject's bundle is missing from the rules bucket
- **WHEN** core-elx runs Zen rule reconciliation
- **THEN** the bundle for that subject SHALL be written to the rules bucket again

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

### Requirement: Default Passthrough Rules
The system SHALL seed a default passthrough rule and template for every supported Zen subject and SHALL label them
as the baseline option. The SNMP trap subject (`logs.snmp`) stops being a supported Zen subject in the release that
stops EventWriter evaluating Zen on it, one release after the trap daemon's binary publisher ships. In that release the
system SHALL remove the seeded trap passthrough rule and template and the seeded `snmp_severity` rule, and SHALL no
longer seed them. The rule editor SHALL stop offering the trap subject in the earlier release, when the trap daemon's
binary publisher ships.

#### Scenario: Passthrough defaults are seeded
- **WHEN** a tenant is onboarded
- **THEN** each supported Zen subject SHALL have a passthrough rule
- **AND** each supported Zen subject SHALL have a passthrough template

#### Scenario: Passthrough defaults are labeled
- **WHEN** an operator reviews Zen rules or templates
- **THEN** passthrough defaults SHALL be labeled as the baseline option via name or description

#### Scenario: The trap daemon's binary publisher ships
- **WHEN** the release that ships the trap daemon's binary publisher is installed
- **THEN** the rule editor SHALL NOT offer to create a rule for the SNMP trap subject
- **AND** the seeded trap passthrough rule and template and the seeded `snmp_severity` rule SHALL remain

#### Scenario: Zen stops on the trap subject
- **WHEN** the release that stops EventWriter evaluating Zen on `logs.snmp` is installed
- **THEN** the seeded trap passthrough rule and template and the seeded `snmp_severity` rule SHALL be removed
- **AND** no passthrough rule, template or `snmp_severity` rule SHALL be seeded for the SNMP trap subject when a tenant is onboarded
