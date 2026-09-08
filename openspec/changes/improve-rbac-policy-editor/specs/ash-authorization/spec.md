## ADDED Requirements

### Requirement: Local User Groups Grant One Role Profile

Each reusable local user group SHALL reference zero or one role profile. Assigning a role profile to
a group SHALL grant that profile's permissions to every current member in addition to the member's
existing direct or built-in role profile. No assignment SHALL preserve existing behavior.

#### Scenario: Group profile augments the base profile

- **GIVEN** a user whose base profile grants `devices.view`
- **AND** a current group membership whose group profile grants `services.update`
- **WHEN** the user's effective permissions are resolved
- **THEN** the result SHALL include both `devices.view` and `services.update`

#### Scenario: Group without a profile changes nothing

- **GIVEN** a user belongs to a local group with no role profile
- **WHEN** the user's effective permissions are resolved
- **THEN** the result SHALL equal the user's existing base-profile permissions

### Requirement: Effective Permission Union Across Current Memberships

The authorization resolver SHALL union permission keys from the user's base profile and from the
role profile attached to every current group membership. The result SHALL use set semantics,
independent of query ordering and duplicate paths to a permission.

The strict authority snapshot SHALL contain the effective permission set and every contributing
profile's ID/update version in deterministic ID order. Current-user, callback-grant, secure
execution, and child-launch issue/recheck paths SHALL preserve this same snapshot shape end to end.

#### Scenario: Multiple group profiles are combined

- **GIVEN** a user belongs to two groups with different role profiles
- **WHEN** current authority is resolved
- **THEN** permissions from both group profiles SHALL be present
- **AND** a permission present in both profiles SHALL occur only once in the effective set

#### Scenario: Membership removal revokes its contribution

- **GIVEN** a user's permission is contributed only by one group profile
- **WHEN** that user's membership is removed and the mutation commits
- **THEN** a subsequent current-authority check SHALL deny the permission

#### Scenario: Security adapter uses the complete union

- **GIVEN** a security-sensitive adapter previously resolved one effective profile
- **AND** a required permission is supplied only by a current group profile
- **WHEN** the adapter resolves current authority
- **THEN** it SHALL use the complete effective-permission union
- **AND** any authority snapshot digest SHALL include every contributing profile deterministically

#### Scenario: Issue and recheck use the same multi-profile snapshot

- **GIVEN** an authorization token or approval captures current authority from multiple profiles
- **WHEN** a callback, secure execution, or child launch rechecks that authority
- **THEN** both issuance and recheck SHALL compare the same sorted profile-version list and
  permission digest

### Requirement: Current Authority Reloads Group-Derived Permissions

Sensitive authorization SHALL reload the active user, current memberships, groups, referenced role
profiles, and permission sets from persistence. It MUST NOT trust scope/socket permissions or
process-local cached permission values as evidence for the decision. Failure to rebuild complete
authority SHALL deny the action.

#### Scenario: Stale scope cannot retain a revoked group permission

- **GIVEN** a socket scope and process-local cache still contain a permission formerly contributed
  by a group profile
- **AND** the group assignment or membership has since been removed in persistence
- **WHEN** a sensitive action calls current-authority authorization
- **THEN** the action SHALL be denied

#### Scenario: Authority reload failure fails closed

- **GIVEN** the persistence lookup for memberships or group profiles fails
- **WHEN** a sensitive action requests current authority
- **THEN** authorization SHALL return an error or denial
- **AND** it SHALL NOT fall back to cached permissions

### Requirement: Group-Derived Permission Cache Invalidation

After a privilege mutation commits, ordinary permission caches SHALL be invalidated for every user
whose effective set may have changed. Membership mutations affect that member; group-profile
mutations affect current group members; profile changes and deletion affect direct assignees and
members of every associated group. No invalidation SHALL occur for a rolled-back mutation.

The resolver MUST NOT retain permission values indefinitely in arbitrary process dictionaries.
Ordinary shared-cache invalidation SHALL be observable across processes.

#### Scenario: Group profile replacement invalidates every member

- **GIVEN** multiple users are current members of a group
- **WHEN** an administrator replaces the group's role profile and the transaction commits
- **THEN** cached permissions for every current member SHALL be invalidated

#### Scenario: Failed mutation leaves caches untouched

- **GIVEN** a group-profile or membership mutation fails and rolls back
- **WHEN** the public mutation boundary returns
- **THEN** it SHALL NOT invalidate any permission cache

#### Scenario: Revocation invalidates another process

- **GIVEN** one process has populated the shared permission cache for a user
- **WHEN** another process commits a mutation that revokes that user's group-derived permission
- **THEN** the first process's next resolver call SHALL NOT receive the invalidated permission

#### Scenario: Group deletion invalidates cascaded members

- **GIVEN** a group profile contributes permissions to current members
- **WHEN** an authorized actor deletes the group and its memberships cascade in the owned transaction
- **THEN** every former member's ordinary permission cache SHALL be invalidated after commit

### Requirement: Privilege Mutations Own Transaction And Audit Boundaries

The system SHALL run group-profile assignment, membership mutation, and role-profile
create/update/coordinated-delete through public boundaries that own their database transaction. A public boundary invoked
inside a caller-owned transaction SHALL return `{:error, :outer_transaction_not_supported}` before
any write, audit event, or cache effect. Audit and cache effects SHALL occur only after commit, and
an audit-delivery failure SHALL NOT reject or undo the committed mutation.

The underlying custom-profile, group-profile, membership, and group-destroy resource actions SHALL
require boundary-owned changeset context so an unsupported direct call fails before persistence.
Trusted system-profile seeding SHALL use separate explicit create/update-system actions.

#### Scenario: Caller-owned outer transaction is rejected

- **GIVEN** application code has already opened a repository transaction
- **WHEN** it invokes a public group-policy, role-profile-policy, or privileged-membership mutation
- **THEN** the mutation SHALL return `{:error, :outer_transaction_not_supported}`
- **AND** persistence, audit delivery, and caches SHALL remain unchanged

#### Scenario: Successful membership mutation is observed after commit

- **GIVEN** an authorized actor adds a user to a privilege-bearing group
- **WHEN** the owned transaction commits
- **THEN** the membership SHALL be persisted
- **AND** the affected user's cache SHALL be invalidated
- **AND** an append-only audit event SHALL describe the actor, target, and operation

#### Scenario: Audit delivery cannot veto a committed mutation

- **GIVEN** an authorized group-policy mutation commits successfully
- **AND** audit delivery subsequently fails
- **WHEN** the boundary returns
- **THEN** the authorization change SHALL remain committed
- **AND** the delivery failure SHALL be logged for operators

#### Scenario: Profile update invalidates direct and group users after commit

- **GIVEN** a role profile is assigned directly to one user and through a group to another user
- **WHEN** an authorized actor updates that profile's permissions and the transaction commits
- **THEN** both users' ordinary caches SHALL be invalidated
- **AND** the audit event SHALL describe the committed profile change

#### Scenario: Direct resource mutation cannot bypass the boundary

- **GIVEN** application code calls a guarded membership or policy resource action without
  boundary-owned context
- **WHEN** Ash evaluates the mutation
- **THEN** it SHALL fail before persistence
- **AND** no audit or cache side effect SHALL occur

#### Scenario: Trusted system profile seeding remains available

- **GIVEN** startup reconciliation needs to create or update a built-in role profile
- **WHEN** the trusted role-profile seeder uses its explicit system action
- **THEN** the system profile SHALL be reconciled
- **AND** the human mutation boundary SHALL remain unavailable to a system actor pretending to be a
  user

### Requirement: IdP Membership Reconciliation Preserves Provenance And Availability

IdP group reconciliation SHALL be best effort across mapped groups, with each individual
IdP-created add/remove mutation owning its transaction. A failed mapping SHALL be logged and skipped
without blocking sign-in or rolling back successful independent mappings. Reconciliation MUST NOT
overwrite, convert, or withdraw a membership whose persisted source is `:manual`; withdrawal SHALL
target only memberships whose source is `:idp`.

#### Scenario: Manual membership survives matching IdP reconciliation

- **GIVEN** an operator-created membership already exists for a user and group
- **WHEN** an IdP claim also maps that user to the group
- **THEN** the existing membership SHALL remain sourced as `:manual`

#### Scenario: IdP withdrawal leaves manual membership

- **GIVEN** a user's persisted membership is sourced as `:manual`
- **WHEN** the corresponding IdP claim is absent during reconciliation
- **THEN** the membership SHALL remain present and unchanged

#### Scenario: One failed IdP mapping does not block sign-in

- **GIVEN** one mapped group mutation fails and another can succeed
- **WHEN** IdP memberships are reconciled during sign-in
- **THEN** the successful independent mutation SHALL commit
- **AND** sign-in SHALL continue
- **AND** the failed mapping SHALL be logged without being reported as successful

### Requirement: User-Facing Privilege Mutations Use The Real Actor

The system SHALL authorize user-facing group-profile, role-profile create/update/delete,
membership, and dashboard-audience mutations through the canonical current-user authority and
authorized Ash actions. They MUST NOT substitute a system actor. Trusted identity-provider
synchronization MAY use its existing internal system actor.

#### Scenario: Revoked administrator cannot reuse an open editor

- **GIVEN** an administrator opened the Policy Editor before `settings.rbac.manage` was revoked
- **WHEN** they submit a group-profile, role-profile, or dashboard-audience mutation afterward
- **THEN** the operation SHALL re-resolve current authority and reject the mutation
- **AND** no write, audit success event, or cache invalidation SHALL occur
