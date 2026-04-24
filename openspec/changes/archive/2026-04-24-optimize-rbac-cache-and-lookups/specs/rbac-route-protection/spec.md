## ADDED Requirements

### Requirement: RBAC permissions are cached in a shared ETS table with TTL
The RBAC system SHALL maintain a shared ETS-based permission cache accessible by all BEAM processes. Cached entries SHALL expire after a configurable TTL (default 5 minutes). The cache SHALL be keyed by user ID and store permissions as a MapSet for O(1) membership lookups.

#### Scenario: Cache hit avoids database query
- **GIVEN** a user's permissions are cached in the ETS table and the entry has not expired
- **WHEN** any process calls `permissions_for_user/2` for that user
- **THEN** the cached MapSet is returned without querying the database

#### Scenario: Cache miss triggers database query and caches result
- **GIVEN** a user's permissions are not in the ETS cache (or the entry has expired)
- **WHEN** `permissions_for_user/2` is called for that user
- **THEN** the system queries the database for the user's effective profile
- **AND** stores the result as a MapSet in the ETS cache with the configured TTL

#### Scenario: Cache entries expire after TTL
- **GIVEN** a cached permission entry with a 5-minute TTL
- **WHEN** more than 5 minutes have elapsed since the entry was cached
- **THEN** the next lookup for that user triggers a fresh database query

### Requirement: Permission membership checks use O(1) MapSet lookups
The RBAC system SHALL store permissions as `MapSet.t(String.t())` rather than `[String.t()]`. All permission membership checks (`has_permission?`, `can?`, `ActorHasPermission.match?`) SHALL use `MapSet.member?/2` for constant-time lookups.

#### Scenario: has_permission? uses MapSet.member?
- **WHEN** `RBAC.has_permission?(user, "devices.view")` is called
- **THEN** the check completes in O(1) time using `MapSet.member?/2`

#### Scenario: ActorHasPermission reads from enriched actor map directly
- **GIVEN** an Ash actor map contains a `:permissions` key with a MapSet
- **WHEN** `ActorHasPermission.match?/3` evaluates a policy
- **THEN** it reads `MapSet.member?(actor.permissions, permission)` directly
- **AND** does not call `RBAC.has_permission?/2`

### Requirement: Permission cache is invalidated on role or profile changes
The RBAC cache SHALL be invalidated when a user's permissions may have changed. Invalidation SHALL occur via PubSub broadcast so all nodes in a cluster are notified.

#### Scenario: User role change invalidates cache
- **GIVEN** a user's permissions are cached
- **WHEN** that user's `role` or `role_profile_id` is updated
- **THEN** the cached entry for that user is immediately removed
- **AND** the next permission check triggers a fresh database query

#### Scenario: RoleProfile change invalidates affected users
- **GIVEN** multiple users are assigned to a RoleProfile
- **WHEN** that RoleProfile's permissions are updated
- **THEN** cached entries for all affected users are invalidated
