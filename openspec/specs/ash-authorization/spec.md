# ash-authorization Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.

## Requirements

### Requirement: Actor-Based Authorization
The system SHALL enforce authorization based on the actor (user, API token, or system) performing actions.

#### Scenario: Actor propagation
- **WHEN** a web request is processed
- **THEN** the authenticated user SHALL be set as the actor
- **AND** all Ash actions SHALL receive the actor for policy evaluation

#### Scenario: Anonymous actor handling
- **GIVEN** an unauthenticated request
- **WHEN** accessing a protected resource
- **THEN** the system SHALL deny access
- **AND** return a 401 Unauthorized response

### Requirement: Role-Based Access Control
The system SHALL implement RBAC with roles: super_user, admin, operator, and viewer.

#### Scenario: Super user bypass
- **GIVEN** a user with super_user role
- **WHEN** the user performs any action
- **THEN** all policy checks SHALL be bypassed
- **AND** full access SHALL be granted

#### Scenario: Admin role permissions
- **GIVEN** a user with admin role
- **WHEN** the user accesses resources within their tenant
- **THEN** the user SHALL have full CRUD permissions
- **AND** the user SHALL NOT access other tenants' data

#### Scenario: Operator role permissions
- **GIVEN** a user with operator role
- **WHEN** the user attempts to modify resources
- **THEN** the user SHALL be able to create and update resources
- **AND** the user SHALL NOT be able to delete resources

#### Scenario: Viewer role permissions
- **GIVEN** a user with viewer role
- **WHEN** the user attempts to modify resources
- **THEN** the action SHALL be denied
- **AND** the user SHALL only have read access

### Requirement: Tenant Isolation Policy
All tenant-scoped resources SHALL enforce tenant isolation via Ash policies.

#### Scenario: Cross-tenant access prevention
- **GIVEN** a user belonging to tenant A
- **WHEN** the user attempts to access a resource belonging to tenant B
- **THEN** the system SHALL deny the action
- **AND** log the unauthorized access attempt

#### Scenario: Global resource access
- **GIVEN** a resource with tenant_id = nil (global)
- **WHEN** any authenticated user queries the resource
- **THEN** the resource SHALL be visible
- **AND** tenant isolation SHALL not apply

### Requirement: Partition Isolation Policy
Resources scoped to partitions SHALL enforce partition-based access control.

#### Scenario: Partition-aware device query
- **GIVEN** a user with access to partition P1
- **WHEN** the user queries devices
- **THEN** only devices in partition P1 or with no partition SHALL be returned
- **AND** devices in other partitions SHALL be excluded

### Requirement: Field-Level Authorization
Sensitive fields SHALL be protected by field-level policies.

#### Scenario: Hidden sensitive field
- **GIVEN** a viewer role user
- **WHEN** the user queries a user resource
- **THEN** the hashed_password field SHALL be returned as %Ash.ForbiddenField{}
- **AND** the email field SHALL be visible

### Requirement: Authorization Audit Logging
Authorization failures SHALL be logged for security monitoring.

#### Scenario: Policy violation logging
- **WHEN** an authorization policy denies an action
- **THEN** the system SHALL log the actor, action, resource, and reason
- **AND** the log entry SHALL include timestamp and request ID

### Requirement: User-Initiated Requests MUST NOT Execute as SystemActor
For any HTTP request initiated by an authenticated user or API token, the system MUST execute Ash actions as that principal and MUST NOT substitute a system actor for authorization evaluation. SystemActor execution is reserved for internal/background operations and explicitly token-gated flows.

#### Scenario: Admin API executes as user actor, not system actor
- **GIVEN** a user makes a request to `GET /api/admin/collectors`
- **WHEN** the request is authorized
- **THEN** Ash reads are evaluated with the user actor (or equivalent service-account actor)
- **AND** the request MUST NOT be evaluated as a system actor

### Requirement: Context Modules MUST NOT Default to SystemActor for User-Facing Operations
Context modules used by controllers and LiveViews MUST require an explicit actor for user-facing operations. If a system actor is required, it MUST be explicitly opted into (for example by calling a dedicated internal function).

#### Scenario: OnboardingPackages.list requires explicit actor
- **GIVEN** a request to load edge onboarding packages in the admin UI
- **WHEN** the list operation is executed
- **THEN** the call includes an explicit user actor
- **AND** omission of actor MUST NOT result in implicit system-privileged access

### Requirement: Internal Scheduled Actions MUST NOT Use Unconditional Authorization
Scheduled/internal Ash actions MUST NOT be authorized by unconditional rules (for example `authorize_if always()`). They MUST use explicit internal authorization conditions (system actor role, or nil actor check intended for schedulers).

#### Scenario: Expire action cannot be invoked by a non-admin actor
- **GIVEN** a non-admin actor attempts to invoke an internal scheduled action (for example package expiration)
- **WHEN** the action is executed via Ash
- **THEN** the action is denied
- **AND** the action can only be executed by an explicit internal actor/check

### Requirement: IdP Group Claims Map To Permission Sets
The system MUST allow an operator to bind an identity-provider group claim to a role profile, so
that a group grants a specific permission set rather than only one of the built-in roles.

#### Scenario: A group claim grants a custom profile
- **GIVEN** a role profile holding `plugins.stage` but not `plugins.approve`
- **AND** a mapping binding the IdP group `SR-Plugin-Authors` to that profile
- **WHEN** a user carrying that group claim signs in through OIDC or SAML
- **THEN** the user's role profile is set to that profile
- **AND** the user holds `plugins.stage`
- **AND** the user does not hold `plugins.approve`

#### Scenario: Existing role-only mappings keep working
- **GIVEN** a mapping that names a role and no profile
- **WHEN** a user matching it signs in
- **THEN** the user's role is set exactly as it was before this change
- **AND** no role profile is assigned by the mapping

#### Scenario: A mapping naming a deleted profile fails safe
- **GIVEN** a mapping referencing a role profile that no longer exists
- **WHEN** a user matching it signs in
- **THEN** the mapping does not grant that profile
- **AND** the condition is recorded so an operator can find it
- **AND** the sign-in does not grant more permissions than the remaining mappings allow

### Requirement: Deterministic Resolution Of Multiple Matching Mappings
When several mappings match one sign-in, the system MUST resolve them deterministically and
independently of the order in which the mappings are stored.

#### Scenario: Permissions union across matched groups
- **GIVEN** a user carrying two group claims bound to two different role profiles
- **WHEN** the user signs in
- **THEN** the resulting permission set is the union of both profiles
- **AND** reordering the mappings does not change the outcome

#### Scenario: Highest matched role is applied
- **GIVEN** matching mappings that name different roles
- **WHEN** the user signs in
- **THEN** the highest-privilege matched role is applied

#### Scenario: No matching mapping falls back to the default
- **GIVEN** a user whose claims match no mapping
- **WHEN** the user signs in
- **THEN** the configured default role is applied
- **AND** the outcome is the same on every subsequent sign-in with the same claims

#### Scenario: Removal from a mapped group revokes what it granted
- **GIVEN** a user whose role profile was granted by an identity-provider mapping
- **WHEN** the user signs in and no mapping matches their claims
- **THEN** that role profile is revoked
- **AND** the configured default role is applied

#### Scenario: A manually assigned profile survives a no-match sign-in
- **GIVEN** a user whose role profile was assigned by an operator
- **AND** whose claims match no mapping
- **WHEN** the user signs in
- **THEN** the profile is retained
- **AND** revocation applies only to identity-provider-granted profiles

### Requirement: Operator Verification Of Claim Mappings
The system MUST let an operator determine why a mapping did or did not apply, without performing a
sign-in.

#### Scenario: Dry-run resolution of a claim set
- **GIVEN** an operator viewing the authorization settings
- **WHEN** the operator submits a sample claim set
- **THEN** the system reports which mappings matched, the resulting role, the resulting profile, and
  the resulting permission set

#### Scenario: Group mapping configured without the group scope is flagged
- **GIVEN** a mapping whose source is a group claim
- **AND** an OIDC configuration whose requested scopes do not include groups
- **WHEN** the operator views the authorization settings
- **THEN** the system warns that group claims will not arrive
- **AND** names the scope that is missing

#### Scenario: Last-login match is visible for a user
- **GIVEN** a user who has signed in through an identity provider
- **WHEN** an operator inspects that user
- **THEN** the system reports which mappings matched at that sign-in

### Requirement: IdP-Managed Group Membership
The system MUST support placing a user into a ServiceRadar user group from an identity-provider
group claim, and MUST distinguish those memberships from ones an operator created.

#### Scenario: Membership is created from a claim
- **GIVEN** a mapping binding an IdP group to a ServiceRadar user group
- **WHEN** a user carrying that claim signs in
- **THEN** the user becomes a member of that group
- **AND** the membership is marked as identity-provider managed

#### Scenario: Membership is withdrawn when the claim stops arriving
- **GIVEN** a user whose identity-provider-managed membership was created from a claim
- **WHEN** the user signs in without that claim
- **THEN** the membership is removed

#### Scenario: Operator-created membership is not removed
- **GIVEN** a user placed into a group by an operator
- **WHEN** that user signs in without a matching claim
- **THEN** the membership is retained
