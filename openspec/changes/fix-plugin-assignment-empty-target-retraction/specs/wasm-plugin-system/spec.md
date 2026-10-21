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

### Requirement: Owner Lifecycle Retracts Plugin Assignments
The control plane SHALL disable the enabled policy-derived plugin assignments of a credential rule or plugin target policy, in the same transaction as the owner action, when that owner is disabled, deleted, or changed so that it no longer covers the assignment's agent. Each disabled assignment SHALL record the reason (`owner_disabled`, `owner_deleted` or `owner_scope_narrowed`), the acting operator, and the time.
The retraction SHALL run for every caller of the owner's update and destroy actions (UI, API, MCP), and SHALL NOT require the operator to hold the plugin-management permission. A credential rule covers an assignment when its edge scope matches the assignment's agent, the agent's gateway, or the assignment's authenticated partition. A target policy covers an assignment when its input definitions resolve to a row owned by the assignment's agent; when they resolve zero rows, no assignment SHALL be disabled, and when resolving them fails, the owner change SHALL fail. Enabling an assignment again SHALL clear its recorded reason, actor and time. A reconcile that loaded the owner before the change SHALL NOT write the assignment back enabled: the assignment store SHALL check, in the same transaction and under a lock on the owner row, that the owner still exists, is enabled, and (for a credential rule) covers the agent before it writes an enabled policy-owned assignment.

#### Scenario: Disabling a credential rule
- **GIVEN** an enabled credential rule with enabled assignments on agents `agent-a` and `agent-b`
- **WHEN** an operator disables the rule
- **THEN** both assignments are disabled in the same transaction
- **AND** each records the reason `owner_disabled` and that operator

#### Scenario: Deleting a target policy
- **GIVEN** a target policy with an enabled assignment on agent `agent-a`
- **WHEN** an operator deletes the policy
- **THEN** the assignment is disabled with the reason `owner_deleted`

#### Scenario: A stale reconcile does not undo the retraction
- **GIVEN** a reconcile that loaded target policy `p` while it was enabled
- **WHEN** an operator disables `p`, its assignment is retracted, and the reconcile then writes the assignment back enabled
- **THEN** the write is refused and the assignment stays disabled with the reason `owner_disabled`

#### Scenario: Narrowing an owner's scope
- **GIVEN** an enabled credential rule scoped to partition `site-1` with enabled assignments on `agent-a` and `agent-b` in that partition
- **WHEN** an operator changes the rule's scope to agent `agent-a`
- **THEN** the assignment on `agent-b` is disabled with the reason `owner_scope_narrowed`
- **AND** the assignment on `agent-a` remains enabled

### Requirement: Orphaned Plugin Assignments Are Reported, Not Retracted Automatically
The control plane SHALL report every enabled policy-derived plugin assignment whose credential rule or target policy is missing or disabled, or whose credential rule no longer covers the agent, with the owner's kind, id and state, the agent, the plugin and the package. No upgrade, migration or periodic job SHALL disable such an assignment on its own. An operator with the plugin-management permission SHALL be able to retract a selected set of reported assignments, or all of them, in one action; each is disabled with the reason `orphaned_owner_cleanup` and the operator recorded, and an assignment that is no longer an orphan when the action runs SHALL be left unchanged. The plugins page SHALL show the report and the retract action only to operators with the plugin-management permission.

#### Scenario: Orphan left by an earlier disable
- **GIVEN** an enabled assignment whose credential rule was disabled before lifecycle retraction existed
- **WHEN** the periodic reconcilers run
- **THEN** the assignment remains enabled
- **AND** the orphan report lists it with the owner state `disabled`

#### Scenario: Operator retracts reported orphans
- **GIVEN** the orphan report lists assignments `a1` and `a2`
- **WHEN** an operator retracts `a1` and an assignment that is not an orphan
- **THEN** `a1` is disabled with the reason `orphaned_owner_cleanup` and that operator recorded
- **AND** `a2` and the non-orphan assignment remain enabled
