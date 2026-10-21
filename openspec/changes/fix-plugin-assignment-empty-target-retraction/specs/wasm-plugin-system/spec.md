## ADDED Requirements
### Requirement: Unresolved Policy Targets Do Not Retract Assignments
The control plane SHALL keep the enabled policy-derived plugin assignments of an enabled policy or credential rule unchanged when the policy's target query resolves zero rows, and SHALL report that reconcile with the reason `targets_unresolved`.
An empty resolution means the targets are unknown, not that there are none. The reconcile SHALL log a warning naming the policy id and the affected agents, SHALL emit telemetry, and SHALL include the held count and the `targets_unresolved` reason in its summary. A resolver error SHALL NOT disable any assignment. Retraction SHALL still happen when the policy is disabled, and when the query resolves at least one row and an assignment is not in the resulting desired set. A reconciler whose input rows are themselves the authoritative list, rather than a target query result, MAY retract on an empty list.

#### Scenario: Target query resolves empty
- **GIVEN** an enabled credential rule with an enabled assignment on agent `agent-a`
- **WHEN** the rule's target query resolves zero rows during a reconcile
- **THEN** the assignment remains enabled and unchanged
- **AND** the reconcile summary reports the reason `targets_unresolved`
- **AND** a warning names the rule's policy id and `agent-a`

#### Scenario: Target query resolves other rows
- **GIVEN** an enabled policy with an enabled assignment on agent `agent-a`
- **WHEN** the policy's target query resolves rows only for agent `agent-b`
- **THEN** the assignment on `agent-a` is disabled

#### Scenario: Disabled policy still retracts
- **GIVEN** a disabled policy with an enabled assignment on agent `agent-a`
- **WHEN** the policy is reconciled and its target query resolves zero rows
- **THEN** the assignment on `agent-a` is disabled

#### Scenario: Resolver error writes nothing
- **GIVEN** an enabled policy with an enabled assignment
- **WHEN** resolving the policy's target query fails
- **THEN** the reconcile returns an error
- **AND** no assignment is created, updated, or disabled
