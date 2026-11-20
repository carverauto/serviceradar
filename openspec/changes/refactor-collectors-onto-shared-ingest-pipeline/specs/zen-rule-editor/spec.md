## MODIFIED Requirements

### Requirement: KV sync for Zen rules
The system SHALL publish the effective rule bundle for a rule's subject to the NATS rules bucket after create/update/delete.

#### Scenario: Rule update sync
- **WHEN** a Zen rule is updated
- **THEN** the bundle for the rule's subject SHALL be republished with the rule's JDM definition
