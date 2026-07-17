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

### Requirement: Logical legacy recovery orchestration
The control plane SHALL reconcile legacy assignments as idempotent logical
desired-state items keyed by tenant, ownership source, agent UID, and logical
plugin rather than as independent user tasks for every historical database row.
It SHALL deduplicate equivalent history, run a bounded scan after upgrade, retry
when relevant current state changes, and preserve every historical row disabled
and unbound as audit evidence.

#### Scenario: Duplicate historical rows produce one recovery item
- **GIVEN** a tenant has multiple disabled unbound rows for the same owner, agent UID, and logical plugin
- **WHEN** the recovery planner scans the tenant
- **THEN** it creates or updates one stable logical recovery item
- **AND** concurrent scans and retries do not create duplicate replacement assignments or duplicate operator tasks

#### Scenario: Offline agent waits without operator action
- **GIVEN** a logical recovery item otherwise passes current owner, package, and schema checks
- **AND** the exact agent has no current authenticated control session
- **WHEN** the planner evaluates the item
- **THEN** it records a non-actionable waiting state without creating or enabling an assignment
- **AND** agent reconnection schedules an idempotent retry automatically

#### Scenario: Current state change retries a blocked item safely
- **GIVEN** a logical recovery item is blocked by package approval, schema compatibility, credential policy, or owner state
- **WHEN** the relevant current package, configuration, credential rule, or owner changes
- **THEN** the planner re-evaluates the item using fresh state
- **AND** it does not copy stale authority, credentials, partition data, or configuration from the historical row

### Requirement: Tenant-scoped legacy manual assignment adoption
The control plane SHALL recover compatible manually owned legacy assignments
through one immutable, tenant-scoped adoption plan unless an allowlisted
immutable principal-continuity proof independently authorizes automatic
recovery. A plan SHALL require one authorized confirmation for all eligible
items, not one confirmation per assignment. Every item SHALL create a new
partition-bound assignment only after fresh authenticated evidence, package
approval, current-schema validation, initiating-principal reauthorization, plan
fingerprint, expiry, and conflict checks succeed. Historical rows SHALL remain
disabled and unbound.

#### Scenario: One plan adopts multiple compatible manual assignments
- **GIVEN** an authorized operator previews a tenant plan containing multiple compatible manual assignments
- **AND** the plan has immutable membership and fingerprints for its legacy source, package schema, configuration references, and target agent
- **WHEN** the operator confirms the plan once
- **THEN** each eligible item is scheduled under that initiating principal and tenant scope
- **AND** the browser is not required to confirm each item separately
- **AND** each successful item creates one fresh assignment in its exact current mTLS-derived partition

#### Scenario: Waiting plan item completes on reconnect
- **GIVEN** an approved unexpired adoption plan contains an item whose exact agent is offline
- **WHEN** that agent establishes a current authenticated control session
- **THEN** the executor reauthorizes the initiating principal and rechecks the item fingerprint and all current safety conditions
- **AND** it completes the item automatically if the checks pass
- **AND** it requires no second per-agent confirmation

#### Scenario: Stale, expired, or unauthorized plan item fails closed
- **GIVEN** a plan expires, its item fingerprint changes, its initiating principal loses assignment authority, or its authenticated principal changes before commit
- **WHEN** the executor attempts fulfillment
- **THEN** it does not create, enable, or dispatch an assignment
- **AND** it records only a redacted actionable outcome

#### Scenario: Manual adoption conflicts with a current assignment
- **GIVEN** an adoption-plan item is otherwise eligible
- **AND** an enabled assignment already exists for the resolved partition, agent, and logical plugin
- **WHEN** the executor evaluates the item
- **THEN** it does not overwrite or disable the current assignment
- **AND** it records an actionable conflict
- **AND** a retry after successful recovery converges on the recorded replacement rather than creating a duplicate

#### Scenario: Automatic manual recovery requires immutable continuity
- **GIVEN** a manual legacy assignment has an allowlisted immutable record that binds its historical principal to the exact current authenticated principal
- **WHEN** the recovery planner verifies that proof and all ordinary plan-item safety checks
- **THEN** it may create the replacement without operator confirmation
- **AND** a matching agent UID, current inventory row, cached partition, or connection alone SHALL NOT satisfy the continuity requirement

#### Scenario: Manual adoption preserves only secret references
- **GIVEN** a manual legacy assignment contains configuration backed by a secret reference
- **WHEN** an adoption item is planned or fulfilled
- **THEN** the replacement may retain the authorized secret reference
- **AND** raw secret values SHALL NOT be read into the plan, recovery response, audit record, logs, or UI payload

#### Scenario: Fresh manual intent is independent of quarantined history
- **GIVEN** an agent has one or more disabled unbound historical assignments for a logical plugin
- **AND** no current bound assignment or authoritative policy conflicts with a new manual assignment
- **WHEN** an authorized operator creates a new assignment with current configuration
- **THEN** the control plane evaluates it through the ordinary create path using fresh mTLS-derived partition evidence
- **AND** the historical rows neither block the create nor become update targets
- **AND** the historical rows remain disabled and unbound without supplying configuration or authority

### Requirement: Automatic policy-owned legacy assignment reconciliation
The control plane SHALL recover a disabled, unbound policy-owned plugin
assignment automatically by re-evaluating its current authoritative policy or
credential-rule materializer under narrow controller authority. It SHALL NOT
require a browser event, use a historical row as authority, or allow an operator
to clone historical policy configuration. The durable outcome MAY be projected
to an authorized tenant reader only as aggregate progress or a normalized
exception reason.

#### Scenario: Current policy recreates an eligible assignment automatically
- **GIVEN** a disabled unbound policy-owned assignment has an enabled current authoritative policy or credential rule
- **AND** the source currently resolves the target agent and current authenticated partition
- **WHEN** deployment scan, agent connection, owner change, package change, or periodic reconciliation schedules the logical item
- **THEN** the materializer creates a fresh partition-bound policy assignment only if current owner, package, schema, credential, and identity checks pass
- **AND** no operator request or confirmation is required
- **AND** the legacy policy rows remain disabled and unbound

#### Scenario: Controller authority is limited to current desired state
- **GIVEN** automatic recovery is evaluating a policy-owned item
- **WHEN** the restricted controller materializes it
- **THEN** its authority derives from the enabled current policy or credential rule and the ordinary reconciler action
- **AND** it may create only the targets, configuration, credential references, and plugin produced by that current owner
- **AND** the existence or contents of a historical row cannot expand that authority

#### Scenario: Policy recovery does not alter another partition sharing an agent UID
- **GIVEN** the authenticated recovery agent is in partition `farm01`
- **AND** policy rows for the same agent UID exist in another partition
- **WHEN** the policy-owned logical item is reconciled
- **THEN** creation, update, and stale-row retraction are limited to partition `farm01`
- **AND** rows in the other partition remain unchanged

#### Scenario: Recovered service state retains the assignment partition
- **GIVEN** a recovered assignment is bound to authenticated partition `farm01`
- **AND** mutable inventory metadata for the same agent UID reports `tonka01`
- **WHEN** the control plane seeds the recovered assignment's service-state placeholder
- **THEN** the placeholder uses partition `farm01` from the immutable assignment
- **AND** mutable agent metadata does not override or redirect that service identity

#### Scenario: Current owner cannot materialize the assignment
- **GIVEN** a historical policy row has a missing, disabled, unsupported, no-longer-matching, schema-incompatible, or credential-policy-invalid current owner
- **WHEN** automatic reconciliation evaluates the logical item
- **THEN** no assignment is created
- **AND** the item becomes a normalized current-owner exception or remains non-actionably absent when the owner no longer expresses desired state
- **AND** the UI does not offer a policy-reconcile button or permit a forged recovery event

#### Scenario: Aggregate policy status is safe to read
- **GIVEN** automatic policy recovery has restored, waiting, or actionable logical items in the current tenant
- **WHEN** an authorized tenant reader requests the recovery overview
- **THEN** the control plane returns only allowlisted aggregate counts and normalized exception groups
- **AND** it does not return request parameters, owner or principal metadata, replacement identifiers, credential data, or raw audit payloads
