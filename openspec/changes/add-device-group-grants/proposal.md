# Change: Scope device write access to device groups

## Why
- RBAC permissions are a flat set of keys with no resource dimension:
  `RBAC.has_permission?/3` takes a permission string and no resource, and no
  call site passes one. `devices.update` therefore means **every device or
  none**.
- Teams that own a subset of the fleet cannot be given write access to only
  their own devices. The concrete driver is the RIDS fleet (~420 airport
  display devices owned by one team), but the shape is general: any customer
  with per-site or per-team operational ownership hits the same wall.
- Today the only way to let that team retag or update its own displays is to
  grant `devices.update` fleet-wide, which also lets them edit every other
  device in inventory.

## What Changes
- Add `ServiceRadar.Identity.DeviceGroupGrant`: a join between an existing
  `Identity.UserGroup` and an existing `Inventory.DeviceGroup`, carrying the
  permission keys the grant confers.
- Extend the actor's loaded RBAC context with the device group ids the actor
  holds a grant for, alongside the existing permission `MapSet`, reusing the
  existing two-tier cache and its invalidation hooks.
- Add a scoped authorization path to `Inventory.Device` policies: an actor may
  update a device if it holds the global permission **or** the device's
  `group_id` is one it has been granted.
- Add admin UI and API for managing grants.
- **Not breaking**: the global permission check is retained as the first
  `authorize_if`, so every existing operator and admin keeps exactly the access
  they have today. The scoped path only ever *adds* access.

## Impact
- Affected specs: new `device-group-grants` (added), `ash-authorization`
  (modified — device policies gain a resource-scoped branch).
- Affected systems: core authorization policies, RBAC actor loading and cache,
  database schema (one new table), web-ng settings UI, admin API.
- Depends on nothing new: `Inventory.DeviceGroup` (with `has_many :devices` via
  `Device.group_id`), `Identity.UserGroup`, and `Identity.UserGroupMembership`
  all already exist. This change adds only the grant that links them and the
  policy that reads it.
