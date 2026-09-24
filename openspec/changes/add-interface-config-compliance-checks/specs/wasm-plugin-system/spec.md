## ADDED Requirements

### Requirement: Per-Source Plugin Assignment Uniqueness
The control plane SHALL allow an agent to hold more than one enabled assignment for the same plugin when the assignments come from different provisioning sources, and SHALL keep exactly one enabled assignment per (partition, agent, plugin, provisioning source key).
A target-policy assignment's source key SHALL identify its policy, input and chunk; manual and producer-schedule assignments SHALL share one fixed source key. Reconciliation SHALL adopt an existing enabled assignment only when it has the same source key.

#### Scenario: Inventory and target policy coexist
- **GIVEN** an agent with an enabled producer-schedule assignment for `opentext-nom-inventory`
- **WHEN** a target-policy credential rule provisions a config check assignment for the same plugin on that agent
- **THEN** both assignments are enabled and delivered to the agent
- **AND** neither assignment is overwritten

#### Scenario: Duplicate within one source is rejected
- **GIVEN** an enabled target-policy assignment for a policy input chunk
- **WHEN** a second enabled assignment with the same source key is created
- **THEN** the create is rejected

### Requirement: Target Policy Projected Input Fields
A target-policy input definition SHALL accept an optional `fields` list of device field paths, and the payload builder SHALL copy those fields from each SRQL device row into the item under `fields`.
Allowed paths SHALL be a top-level SRQL device column name or `metadata.<key>`; any other path SHALL be rejected when the policy is built. Existing item and chunk size limits SHALL still apply.

#### Scenario: Attachment field is delivered
- **GIVEN** an input definition with `fields: ["switch_port_attachment"]`
- **WHEN** the payload is built for a device whose `switch_port_attachment` is `{"switch_hostname":"switch01.example.com","port":"gi1/0/7"}`
- **THEN** the item carries `fields.switch_port_attachment` with that value

#### Scenario: Unsupported path is rejected
- **GIVEN** an input definition with `fields: ["metadata"]`
- **WHEN** the policy is built
- **THEN** it is rejected with an invalid-field error

### Requirement: Target Policy Poll Interval Control
Target-policy credential rules SHALL expose the poll interval as an operator-editable control, bounded to a minimum of 60 seconds and a maximum of 86400 seconds, and the planned assignment SHALL use it as its schedule.

#### Scenario: Operator sets an hourly interval
- **GIVEN** a target-policy rule with interval 3600
- **WHEN** assignments are planned
- **THEN** each planned assignment runs every 3600 seconds
