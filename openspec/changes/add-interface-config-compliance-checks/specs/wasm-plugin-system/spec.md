## ADDED Requirements

### Requirement: Per-Rule Plugin Assignment Ownership
The control plane SHALL allow an agent to hold more than one enabled assignment for the same plugin when the assignments are owned by different credential rules, and SHALL otherwise keep at most one enabled assignment per (partition, agent, plugin).
Ownership SHALL be derived from the assignment's policy id: `network-credential-rule:<rule id>` with any suffix is owned by that rule; a manual assignment or any other policy id keeps the original single-assignment rule. Reconciliation SHALL NOT adopt an assignment owned by a different credential rule.

#### Scenario: Inventory and interface check rules coexist
- **GIVEN** an agent with an enabled `opentext-nom-inventory` assignment owned by an inventory credential rule
- **WHEN** an interface config check credential rule provisions an assignment for the same plugin on that agent
- **THEN** both assignments are enabled
- **AND** neither assignment is overwritten

#### Scenario: A rule's drifted policy id still converges
- **GIVEN** an enabled assignment owned by a credential rule under an older policy id suffix
- **WHEN** the same rule is reconciled under its current policy id
- **THEN** the existing assignment is adopted and no second enabled assignment is created

#### Scenario: Manual assignments keep the single-assignment rule
- **GIVEN** an enabled manual assignment for a plugin on an agent
- **WHEN** a second enabled assignment for that plugin is created on the agent
- **THEN** the create is rejected

### Requirement: Producer Schedule Target Items
A producer schedule SHALL be able to declare `target_input` naming the schedule params that hold an SRQL device query and an optional list of device fields, and the dispatcher SHALL resolve that query when the schedule runs and deliver the resulting device items as `target_items` on each run.
Delivered items SHALL be the normalized device rows, capped at the declared `max_items` (at most 1000) with the total and a truncation flag reported. A run whose configured query is missing SHALL fail rather than dispatch with no targets.

#### Scenario: Endpoints are delivered with their attachment
- **GIVEN** a schedule declaring `target_input` with `query_param: target_query` and `fields_param: target_fields`
- **AND** params `target_query: in:devices switch_port_attachment.switch_hostname:%` and `target_fields: [switch_port_attachment]`
- **WHEN** the schedule dispatches
- **THEN** each run payload carries `target_items.items` with each matched device and its `fields.switch_port_attachment`

#### Scenario: Missing query
- **GIVEN** a schedule declaring `target_input` whose params have no target query
- **WHEN** the schedule dispatches
- **THEN** the dispatch fails with `missing_target_query`

### Requirement: Projected Target Fields
Device target inputs SHALL accept a list of fields to copy from each SRQL device row into the item under `fields`, where each field is a top-level device column or `metadata.<key>`.
The whole `metadata` map and any other path form SHALL be rejected, and non-device inputs SHALL NOT accept fields.

#### Scenario: A metadata key is projected
- **GIVEN** fields `["metadata.armis_access_switch"]`
- **WHEN** a device row whose metadata has `armis_access_switch: switch01.example.com:gi1/0/7` is normalized
- **THEN** the item carries `fields["metadata.armis_access_switch"]` and no other metadata

#### Scenario: Whole metadata is rejected
- **GIVEN** fields `["metadata"]`
- **WHEN** the input is resolved
- **THEN** it is rejected with an invalid-field error
