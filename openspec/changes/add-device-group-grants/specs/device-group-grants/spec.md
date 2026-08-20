## ADDED Requirements

### Requirement: Device Group Grant Resource
The system SHALL provide a `DeviceGroupGrant` resource linking one
`Identity.UserGroup` to one `Inventory.DeviceGroup` together with the set of
permission keys the grant confers. Grant permission keys MUST be validated
against the canonical RBAC permission catalog. A given user group and device
group pair MUST be unique.

#### Scenario: Admin grants a team write access to its devices
- **GIVEN** an authenticated admin
- **AND** a user group "RIDS Team" and a device group "RIDS Displays"
- **WHEN** the admin creates a grant linking them with permission `devices.update`
- **THEN** the grant SHALL persist
- **AND** members of "RIDS Team" SHALL be able to update devices whose `group_id`
  is "RIDS Displays"

#### Scenario: Grant with an unknown permission key is rejected
- **GIVEN** an authenticated admin
- **WHEN** they create a grant carrying the permission key `devices.frobnicate`
- **THEN** the request SHALL be rejected with a validation error
- **AND** no grant SHALL be persisted

#### Scenario: Only admins manage grants
- **GIVEN** an authenticated operator without `settings.rbac.manage`
- **WHEN** they attempt to create, update, or delete a device group grant
- **THEN** the request SHALL be rejected as forbidden

### Requirement: Scoped Device Write Authorization
An actor SHALL be authorized to update a device when it holds the fleet-wide
permission for that action, **or** when the device's `group_id` matches a device
group the actor has been granted that same permission on. Devices outside every
granted group MUST remain unwritable by a scoped actor. The scoped path SHALL
only widen access; no actor authorized before this change may lose access.

#### Scenario: Scoped user updates a device inside its grant
- **GIVEN** a user in "RIDS Team", holding no fleet-wide `devices.update`
- **AND** a grant of `devices.update` on device group "RIDS Displays"
- **WHEN** they update a device assigned to "RIDS Displays"
- **THEN** the update SHALL succeed

#### Scenario: Scoped user cannot update a device outside its grant
- **GIVEN** the same user and grant
- **WHEN** they update a device assigned to a different device group, or to no group
- **THEN** the request SHALL be rejected as forbidden

#### Scenario: A grant confers only the permissions it lists
- **GIVEN** a user whose only grant lists `devices.update`
- **WHEN** they attempt to delete a device inside that granted device group
- **THEN** the request SHALL be rejected as forbidden

#### Scenario: Existing fleet-wide operators are unaffected
- **GIVEN** a user holding fleet-wide `devices.update` and no grants
- **WHEN** they update any device, in any group or none
- **THEN** the update SHALL succeed exactly as before this change

### Requirement: Grant Revocation Takes Effect Immediately
Revoking a grant, removing a user from a granted user group, or deleting a
granted device group SHALL invalidate the affected users' cached authorization
context so the change applies on the user's next request rather than after a
cache TTL.

#### Scenario: Revoked grant stops authorizing writes
- **GIVEN** a scoped user who can currently update devices in a granted group
- **WHEN** an admin deletes that grant
- **THEN** the user's next update to a device in that group SHALL be rejected as
  forbidden

#### Scenario: Removing a user from the group revokes their scope
- **GIVEN** a scoped user authorized through their membership in "RIDS Team"
- **WHEN** an admin removes them from "RIDS Team"
- **THEN** their next update to a device in the granted group SHALL be rejected
  as forbidden

### Requirement: Scoped Users See Their Boundary
The device UI SHALL render write controls a scoped user is not authorized to use
as disabled rather than hidden, so that the boundary between readable and
writable devices is visible.

#### Scenario: Editing a device outside the grant
- **GIVEN** a scoped user viewing a device outside every granted device group
- **WHEN** the device detail page renders
- **THEN** edit controls SHALL be visible and disabled
- **AND** the reason SHALL be indicated to the user
