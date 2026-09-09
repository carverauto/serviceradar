## ADDED Requirements

### Requirement: Public Ansible configuration lifecycle
ServiceRadar SHALL expose documented authenticated JSON lifecycle APIs for the credentials, controllers, repositories, inventory discovery, membership review, template bindings, and operation status required to configure its AWX integration without database or RPC access.

#### Scenario: Bootstrap through public API
- **GIVEN** running ServiceRadar and AWX endpoints and an authorized automation account
- **WHEN** a client provisions the integration through public APIs
- **THEN** each supported setup step SHALL have a stable resource or operation identity
- **AND** readiness SHALL identify unresolved dependencies or required review
- **AND** missing review SHALL NOT be bypassed by configuration success

### Requirement: Intersected automation authority
Every configuration request and queued external mutation MUST enforce the intersection of current account RBAC, token capabilities, resource scope, and any delegation ceiling, preserving the initiating principal in its audit record.

#### Scenario: Read token belongs to administrator
- **GIVEN** an administrator account authenticates with a read-only token
- **WHEN** it requests a configuration mutation
- **THEN** the API SHALL deny the mutation before persistence or dispatch

#### Scenario: Authority contracts while queued
- **GIVEN** a provisioning operation is queued under an account's authority
- **WHEN** that account is revoked or loses the required permission before dispatch
- **THEN** the worker SHALL reject undispatched mutations
- **AND** SHALL NOT substitute its system authority

### Requirement: Declarative lifecycle semantics
Configuration APIs SHALL provide stable IDs, bounded pagination, idempotent create requests, optimistic concurrency for mutations, explicit import/adoption, and reference-aware deletion.

#### Scenario: Client retries a completed create
- **WHEN** the same authorized client repeats an identical create with the same scoped idempotency key
- **THEN** the API SHALL return the original resource or operation
- **AND** SHALL NOT create another upstream object

#### Scenario: Stale mutation or conflicting retry
- **WHEN** an update carries a stale version or an idempotency key is reused for different content
- **THEN** the API SHALL report a conflict without overwriting current state

#### Scenario: Delete a credential still in use
- **WHEN** a client deletes a credential referenced by a controller or another typed consumer
- **THEN** the canonical usage guard SHALL reject deletion and identify authorized non-secret usage references

### Requirement: Observation ordering preserves unchanged membership authority
ServiceRadar SHALL track the latest accepted AWX controller observation separately from each membership's authority generation, preserve that authority generation when execution evidence is unchanged, and atomically reconcile device state, memberships, and the observation watermark before publishing resulting state events.

#### Scenario: An unchanged observation arrives during an operation
- **WHEN** a newer AWX observation preserves the membership's exact execution authority
- **THEN** ServiceRadar SHALL refresh its observed state without invalidating the operation's membership authority
- **AND** changes to the target identity, address, enabled/current state, source fingerprint, or linkage evidence SHALL still invalidate previous authority

#### Scenario: An older or conflicting observation races with a newer one
- **WHEN** controller observations arrive out of order or reuse a generation with conflicting content
- **THEN** controller serialization SHALL reject the stale or conflicting observation before it changes device or membership state
- **AND** partial and complete-empty observations SHALL participate in the same durable ordering

#### Scenario: Membership reconciliation fails after device updates
- **WHEN** any step in a controller observation's reconciliation fails
- **THEN** its device updates, membership updates, and watermark advancement SHALL roll back together
- **AND** no device-state event or membership notification for those uncommitted changes SHALL be emitted

### Requirement: Typed AWX provisioning through the broker
ServiceRadar SHALL provision managed AWX projects, inventories, inventory sources, execution environments, job templates, and narrowly scoped role assignments through typed edge-agent commands using a distinct provisioning permission and purpose-bound broker grants.

#### Scenario: Configure an upstream job template
- **GIVEN** authorized references to a managed controller, project, inventory, environment, and existing machine credential
- **WHEN** a client requests a supported template configuration
- **THEN** the service SHALL construct an exact bounded upstream request
- **AND** the agent SHALL enforce its host, path, method, and body before resolving credentials
- **AND** the result SHALL contain only the documented non-secret projection

#### Scenario: Attempt an arbitrary upstream request
- **WHEN** a client supplies an unrecognized resource type, arbitrary URL, undeclared body field, or unrelated role grant
- **THEN** the API SHALL reject it without external mutation

### Requirement: Ownership and ambiguous mutation recovery
Upstream reconciliation MUST bind each managed object to an exact controller, resource type, and upstream ID, and MUST reconcile uncertain outcomes before retrying a potentially accepted mutation.

#### Scenario: Existing object has the same display name
- **WHEN** discovery finds an unmanaged object with the requested name
- **THEN** the service SHALL require explicit authorized adoption by upstream identity
- **AND** SHALL NOT overwrite or delete the object based only on its name

#### Scenario: Create response is lost
- **WHEN** an upstream create may have succeeded but its response is lost
- **THEN** the operation SHALL remain visibly unresolved until exact reconciliation proves its outcome
- **AND** SHALL NOT blindly repeat the create

### Requirement: Unified credential custody for declarative clients
New credential material MUST remain write-only at the API boundary and encrypted in the unified credential inventory, with no plaintext or secret-value digest in public responses, audit payloads, Terraform state, plans, or diagnostics.

#### Scenario: Provisioning requires a controller credential
- **WHEN** a client references or creates credential material for upstream provisioning
- **THEN** the controller SHALL use a restrictive tracked reference to the unified credential resource
- **AND** its usage SHALL participate in guarded deletion and navigable usage
- **AND** read responses SHALL return only non-secret metadata and references

### Requirement: Terraform reconciliation uses the public API
A first-party Terraform provider SHALL configure ServiceRadar through its public API, support import and drift detection, and make unchanged repeated applies a no-op.

#### Scenario: Reapply an unchanged bootstrap
- **GIVEN** a completed bootstrap managed by Terraform
- **WHEN** the client refreshes and applies unchanged configuration
- **THEN** no configuration mutation or playbook launch SHALL occur

#### Scenario: Configuration changes outside Terraform
- **WHEN** an operator changes a managed configuration through an authorized ServiceRadar surface
- **THEN** Terraform refresh SHALL report the canonical current state
- **AND** the subsequent plan SHALL show the drift
- **AND** refresh SHALL NOT mutate configuration or approve new execution evidence

### Requirement: Explicit reviewed deployment remains separate
Public execution APIs MUST use the canonical prepare/launch/status/cancel services and preserve current immutable binding review, exact approved target membership, live preflight, holds, and initiating actor authorization; configuration reconciliation MUST NOT confer approval or launch authority.

#### Scenario: Configuration is ready but binding evidence changed
- **WHEN** a client requests deployment after its reviewed binding or target membership has changed
- **THEN** the launch SHALL fail before operation persistence or AWX dispatch
- **AND** the API SHALL identify that new review is required

#### Scenario: Terraform configures a complete integration
- **WHEN** Terraform finishes provisioning all configuration resources
- **THEN** it SHALL expose readiness and pending review references
- **AND** SHALL NOT launch a playbook as a side effect of configuration apply
