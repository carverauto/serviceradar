## MODIFIED Requirements

### Requirement: RBAC Permission Evaluation
The system SHALL cache user permissions per-process using the Erlang process dictionary to prevent repeated database queries for the same user's RoleProfile within a single request or LiveView session.

The system SHALL pre-load permissions during authentication scope creation (`create_scope/1`) and store them in the `%Scope{}` struct, ensuring all downstream consumers (plugs, LiveView mounts, template renders, Ash policy checks) can access permissions without additional database queries.

The system SHALL pass pre-loaded permissions through the Ash actor by enriching the actor map with a `permissions` key when permissions are available in the Scope, preventing `ActorHasPermission` policy checks from triggering database lookups.

The `WebRBAC.can?/2` helper SHALL check `scope.permissions` directly when available, falling back to `RBAC.has_permission?/2` only when permissions are not pre-loaded in the scope.

#### Scenario: First page load after authentication
- **WHEN** a user authenticates and their scope is created
- **THEN** `permissions_for_user/2` is called exactly once (1 DB query to RoleProfile)
- **AND** the result is stored in `%Scope{permissions: [...]}`
- **AND** all subsequent `RBAC.can?/2` calls in the same process use the cached permissions
- **AND** all Ash policy evaluations via `ActorHasPermission` use the enriched actor map

#### Scenario: LiveView navigation within same session
- **WHEN** a user navigates between pages within an existing LiveView session
- **THEN** no additional RoleProfile database queries are executed
- **AND** permissions remain cached in the process dictionary for the lifetime of the LiveView process

#### Scenario: Template rendering with multiple permission checks
- **WHEN** a template renders with 14-23 conditional `RBAC.can?/2` checks
- **THEN** all checks resolve from in-memory permissions (scope or process cache)
- **AND** zero database queries are executed during the render phase

#### Scenario: Ash operation with ActorHasPermission policy
- **WHEN** an Ash read/create/update/destroy operation is authorized via ActorHasPermission
- **AND** the actor map contains a pre-loaded `permissions` list
- **THEN** the permission check resolves from the actor map directly
- **AND** no database query for RoleProfile is executed
