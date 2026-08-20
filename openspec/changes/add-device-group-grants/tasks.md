## 1. Data model
- [ ] 1.1 Add `ServiceRadar.Identity.DeviceGroupGrant` (user_group_id, device_group_id, permissions, metadata) with a unique identity on (user_group_id, device_group_id).
- [ ] 1.2 Validate grant permission keys against the RBAC catalog, reusing `Identity.Validations.PermissionKeys`.
- [ ] 1.3 Add the migration for the grants table with FKs to user groups and device groups, both `on_delete: :delete`.
- [ ] 1.4 Register the resource on the `Identity` domain; policies restrict management to `settings.rbac.manage`.

## 2. Authorization
- [ ] 2.1 Extend the actor authorization context to carry granted device group ids beside the permission `MapSet`.
- [ ] 2.2 Load grants on the same path as `RBAC.permissions_for_user/2`; keep them in the same cache entry and bump the cache key namespace so stale entries from the old format cannot be read.
- [ ] 2.3 Update every reader of the cached value for the new entry shape.
- [ ] 2.4 Add a `granted_device_group` policy helper to `ServiceRadar.Policies`, alongside `partition_matches`.
- [ ] 2.5 Add the scoped `authorize_if` branch to `Inventory.Device`'s `:update` policy, after the existing fleet-wide check.
- [ ] 2.6 Extend cache invalidation to grant create/update/delete, user group membership changes, and device group deletion.

## 3. Interfaces
- [ ] 3.1 Admin API endpoints for grant CRUD under the existing role-profile admin surface.
- [ ] 3.2 Settings UI for managing grants (pick a user group, a device group, and the permissions).
- [ ] 3.3 Disable rather than hide device write controls for devices outside the actor's scope, with the reason surfaced.

## 4. Tests
- [ ] 4.1 Scoped user updates a device inside the grant; is forbidden outside it and on a device with no group.
- [ ] 4.2 A grant listing only `devices.update` does not confer `devices.delete`.
- [ ] 4.3 Existing fleet-wide operators and admins retain identical access (regression).
- [ ] 4.4 Revoking a grant, and removing a user from the granted group, both take effect on the next request.
- [ ] 4.5 Bulk update across mixed groups touches only granted rows (the filter-composition case).
- [ ] 4.6 Grant creation rejects permission keys outside the catalog.

## 5. Docs
- [ ] 5.1 Document scoped device access in `docs/docs/rbac-and-roles.md`, including that it widens rather than narrows and that reads stay fleet-wide.
