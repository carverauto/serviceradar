## MODIFIED Requirements

### Requirement: KV sync for Zen rules
The system SHALL sync Zen rule JDM definitions to the datasvc KV store after create/update/delete, and SHALL also publish the effective rule bundle for the rule's subject to the NATS rules bucket after create/update/delete.

#### Scenario: Rule update sync
- **WHEN** a Zen rule is updated
- **THEN** the KV entry for the rule SHALL be updated with the rule’s JDM definition
- **AND** the bundle for the rule's subject SHALL be republished to the rules bucket
