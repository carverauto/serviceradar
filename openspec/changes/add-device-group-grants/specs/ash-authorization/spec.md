## MODIFIED Requirements

### Requirement: Device Resource Authorization
Device authorization SHALL evaluate a fleet-wide permission check first and,
only when that check does not authorize, a resource-scoped check against the
actor's granted device groups. The scoped check MUST be expressible as an Ash
`expr()` over the device's `group_id` so it composes as a filter and not only as
a check on an already-loaded record. Read, create, destroy, and bulk actions
retain their existing fleet-wide-only behavior under this change.

#### Scenario: Fleet-wide operator short-circuits the scoped check
- **GIVEN** an actor holding fleet-wide `devices.update`
- **WHEN** they update a device
- **THEN** authorization SHALL succeed on the fleet-wide check
- **AND** the scoped check SHALL NOT need to be evaluated

#### Scenario: Actor with no grants is unaffected
- **GIVEN** an actor with neither fleet-wide `devices.update` nor any grant
- **WHEN** they update a device
- **THEN** the request SHALL be rejected as forbidden, as before this change

#### Scenario: Scoped authorization composes as a filter
- **GIVEN** a scoped actor with a grant on one device group
- **WHEN** a bulk update is run across devices spanning several groups
- **THEN** only devices inside the granted group SHALL be affected

### Requirement: Actor Authorization Context Loading
The actor's authorization context SHALL carry the granted device group ids
alongside the effective permission set, loaded and cached on the same path.
Cache invalidation SHALL cover grant lifecycle changes and user group membership
changes in addition to the existing role and profile changes.

#### Scenario: Granted group ids load with permissions
- **GIVEN** a user who is a member of a user group holding a grant
- **WHEN** their authorization context is loaded
- **THEN** it SHALL include both their effective permission set and the granted
  device group ids
- **AND** a second load within the cache TTL SHALL NOT re-query the database

#### Scenario: Grant change invalidates the cached context
- **GIVEN** a user whose authorization context is cached
- **WHEN** a grant affecting their user group is created, updated, or deleted
- **THEN** their cached context SHALL be invalidated
