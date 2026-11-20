## MODIFIED Requirements

### Requirement: Zen Rule Persistence and KV Sync
The system SHALL persist Zen rule definitions in the tenant schema and SHALL publish the effective rule bundle for each affected subject to the NATS rules bucket on create, update, and delete.

#### Scenario: Publish a new Zen rule
- **WHEN** a Zen rule is created
- **THEN** the bundle for its subject SHALL be written to the rules bucket
- **AND** the bundle SHALL carry a digest that identifies its contents

#### Scenario: Disable a Zen rule
- **WHEN** a Zen rule is disabled
- **THEN** the bundle for its subject SHALL be republished without that rule
- **AND** the rule record SHALL reflect the disabled state

#### Scenario: A subject a collector no longer evaluates
- **WHEN** an operator opens the rule editor for SNMP traps
- **THEN** the system SHALL NOT offer to create a rule for that subject
