## MODIFIED Requirements

### Requirement: Per-Rule Plugin Assignment Ownership
The control plane SHALL allow an agent to hold more than one enabled assignment for the same plugin when the assignments are owned by different credential rules, and SHALL otherwise keep at most one enabled assignment per (partition, agent, plugin).
Ownership SHALL be derived from the assignment's policy id: `network-credential-rule:<rule id>` with any suffix is owned by that rule; a manual assignment or any other policy id keeps the original single-assignment rule. Reconciliation SHALL NOT adopt an assignment owned by a different credential rule, and SHALL adopt the assignment of its own rule even when other rules' assignments for the plugin are enabled on the same agent. When a same-rule row and a manual or other non-rule row both collide, reconciliation SHALL adopt the same-rule row.
The database SHALL enforce same-owner duplicates with a unique index on (partition, agent, plugin, owner key) over enabled assignments, where the owner key is the credential rule id for a rule-owned assignment and one shared value for every other assignment. That index cannot express a manual or other non-rule assignment beside a rule-owned assignment; `NoDuplicateEnabledAssignment` refuses that pairing.
Config delivery SHALL deliver every enabled assignment of a plugin that does not conflict with a more recently updated one, each under its own assignment id and with credentials resolved from its own parameters, and the agent SHALL run one plugin instance per assignment id.

#### Scenario: Inventory and interface check rules coexist
- **GIVEN** an agent with an enabled `opentext-nom-inventory` assignment owned by an inventory credential rule
- **WHEN** an interface config check credential rule provisions an assignment for the same plugin on that agent
- **THEN** both assignments are enabled
- **AND** neither assignment is overwritten

#### Scenario: Two rules' assignments of one plugin are both delivered
- **GIVEN** two credential rules, each owning an enabled assignment of the same plugin on one agent with a different credential
- **WHEN** the agent's config is generated
- **THEN** the config contains both assignments under their own assignment ids
- **AND** each assignment carries the credential of its own rule

#### Scenario: The database refuses a second enabled assignment of one rule
- **GIVEN** an enabled assignment of a plugin owned by a credential rule on an agent
- **WHEN** another enabled assignment of that plugin owned by the same rule, under any policy id suffix, is written for that agent
- **THEN** the write violates the per-owner unique index

#### Scenario: A rule's drifted policy id still converges
- **GIVEN** an enabled assignment owned by a credential rule under an older policy id suffix
- **AND** an enabled assignment of the same plugin owned by another credential rule on the same agent
- **WHEN** the first rule is reconciled under its current policy id
- **THEN** the first rule's existing assignment is adopted and no second enabled assignment is created
- **AND** the other rule's assignment is left unchanged

#### Scenario: Manual assignments keep the single-assignment rule
- **GIVEN** an enabled manual assignment for a plugin on an agent
- **WHEN** a second enabled assignment for that plugin is created on the agent
- **THEN** the create is rejected

#### Scenario: Agent runs two instances of one plugin
- **GIVEN** an agent config with two enabled assignments of the same plugin under different assignment ids
- **WHEN** the agent applies the config
- **THEN** the agent schedules one runner for each assignment id
