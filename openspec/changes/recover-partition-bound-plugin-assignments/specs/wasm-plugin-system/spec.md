## ADDED Requirements

### Requirement: Authenticated partition binding for plugin assignments
The control plane SHALL derive the partition of every enabled plugin assignment from current server-observed mTLS control-session evidence for the selected agent. The assignment API, policy input, plugin configuration, and persisted agent metadata SHALL NOT supply or override that partition.

#### Scenario: Online agent is assigned in its authenticated partition
- **GIVEN** an authorized operator selects an online agent whose current authenticated control session identifies partition `default`
- **WHEN** the operator creates a plugin assignment
- **THEN** the control plane creates the assignment in partition `default`
- **AND** the partition value comes from the server-observed control-session evidence
- **AND** the resulting enabled assignment is scoped by that agent and partition

#### Scenario: Identity evidence is unavailable or inconsistent
- **GIVEN** an authorized operator selects an offline agent or an agent whose current control-session evidence does not identify the selected agent and a nonempty partition
- **WHEN** the operator attempts to create or recover an assignment
- **THEN** the control plane rejects the request without creating or enabling an assignment
- **AND** the response explains that authenticated agent partition evidence is unavailable or inconsistent

#### Scenario: Caller attempts to select a partition
- **GIVEN** a caller supplies a partition identifier in a plugin assignment request or recovered configuration
- **WHEN** the control plane evaluates the request
- **THEN** the caller-supplied value SHALL NOT control the assignment partition
- **AND** the action SHALL use fresh authenticated evidence or fail closed

### Requirement: Legacy manual assignment reapproval
The control plane SHALL provide an explicit, idempotent reapproval path for a disabled plugin assignment with no partition that is manually owned. Reapproval SHALL create a new partition-bound assignment only after current authenticated evidence, package approval, configuration validation, authorization, and conflict checks succeed. The legacy row SHALL remain disabled and unbound as historical evidence.

#### Scenario: Manual legacy assignment is reapproved
- **GIVEN** a manually owned legacy assignment is disabled with no partition
- **AND** its package remains approved and its saved non-secret configuration and secret references validate against the current package schema
- **AND** an authorized operator confirms reapproval while the exact agent has authenticated partition `default`
- **WHEN** the reapproval action completes
- **THEN** a new assignment is created for that agent in partition `default`
- **AND** the old assignment remains disabled with no partition
- **AND** an audit record links the operator, old assignment, new assignment, and authenticated principal tuple
- **AND** the replacement configuration is dispatched only after that recovery transaction commits

#### Scenario: Reapproval conflicts with a current assignment
- **GIVEN** a manually owned legacy assignment is eligible for reapproval
- **AND** an enabled assignment already exists for the resolved partition, agent, and logical plugin
- **WHEN** an authorized operator confirms reapproval
- **THEN** the control plane does not overwrite or disable the current assignment
- **AND** it returns an actionable conflict result
- **AND** a retry after a completed recovery returns the recorded replacement rather than creating a duplicate

#### Scenario: Reapproval identity race rolls back before config delivery
- **GIVEN** manual reapproval has preflight evidence for the selected agent
- **AND** the authenticated control-session partition changes before the replacement can be committed
- **WHEN** the recovery action detects the changed identity
- **THEN** it rolls back the replacement assignment and any related recovery writes
- **AND** it records only the redacted identity-change outcome
- **AND** it does not dispatch configuration to an edge agent

#### Scenario: Reapproval preserves only secret references
- **GIVEN** a manually owned legacy assignment contains configuration backed by a secret reference
- **WHEN** the assignment is reapproved
- **THEN** the replacement may retain the secret reference
- **AND** raw secret values SHALL NOT be read into the recovery response, audit record, logs, or UI payload

### Requirement: Policy-owned legacy assignment reconciliation
The control plane SHALL recover a disabled, unbound policy-owned plugin assignment only by re-evaluating its current authoritative policy or credential-rule materializer. It SHALL NOT allow an operator to manually clone the historical policy assignment. Credential-rule recovery SHALL require both current plugin-assignment and credential-management authority. The durable recovery outcome MAY be projected to an authorized legacy-row reader only as a redacted state and replacement count.

#### Scenario: Current policy recreates an eligible assignment
- **GIVEN** a disabled unbound policy-owned assignment has an enabled, authorized source policy or credential rule
- **AND** the source currently resolves the target agent and current authenticated partition
- **WHEN** an authorized operator or the permitted reconciler requests recovery
- **THEN** the materializer creates a fresh partition-bound policy assignment only if current policy, package, schema, and identity checks pass
- **AND** the legacy policy row remains disabled and unbound

#### Scenario: Policy recovery does not alter another partition sharing an agent UID
- **GIVEN** the authenticated recovery agent is in partition `farm01`
- **AND** policy rows for the same agent UID exist in another partition
- **WHEN** the policy-owned legacy assignment is reconciled
- **THEN** creation, update, and stale-row retraction are limited to partition `farm01`
- **AND** rows in the other partition remain unchanged

#### Scenario: Policy is no longer authoritative
- **GIVEN** a disabled unbound policy-owned assignment has a missing, disabled, or no-longer-matching source policy or credential rule
- **WHEN** recovery is requested
- **THEN** no assignment is created
- **AND** the result identifies that the historical policy is no longer authoritative

#### Scenario: Durable policy status is safe to refresh
- **GIVEN** an authorized operator has requested policy recovery for an exact legacy assignment in the current tenant
- **WHEN** the operator refreshes the assignment detail while the materializer is queued, running, or terminal
- **THEN** the control plane returns only a normalized status and replacement count for that legacy row
- **AND** it does not return recovery-request parameters, owner or principal metadata, replacement identifiers, or credential data
