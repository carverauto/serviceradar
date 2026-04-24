## ADDED Requirements

### Requirement: Store NetFlow Application Classification Rules
The system SHALL store NetFlow application classification override rules in CNPG in the `platform` schema.

#### Scenario: Rules are stored in the platform schema
- **WHEN** migrations are applied
- **THEN** a table exists at `platform.netflow_app_classification_rules`
- **AND** it supports partition-scoped rules with enable/disable and priority ordering

