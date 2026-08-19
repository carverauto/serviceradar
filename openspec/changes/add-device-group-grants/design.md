# Design: device group grants

## Context

Authorization today is a membership test over a flat set:

```elixir
# elixir/serviceradar_core/lib/serviceradar/identity/rbac.ex
def has_permission?(user, permission, opts \\ []) do
  MapSet.member?(permissions_for_user(user, opts), permission)
end
```

`Inventory.Device` consumes that directly:

```elixir
policies do
  read_with_permission(@devices_view_check)
  action_type_with_permission(:update, @devices_update_check)
  ...
end
```

There is no resource in the decision, so the answer is the same for every row.

The pieces needed to change that mostly exist:

| Piece | Status |
| --- | --- |
| "a list of devices" | `Inventory.DeviceGroup`, `has_many :devices` via `Device.group_id` |
| "a group of users" | `Identity.UserGroup` + `Identity.UserGroupMembership` |
| row-scoped policy expressions in Ash | precedent: `ServiceRadar.Policies.partition_matches/0` builds an `expr()` comparing a resource attribute to `^actor(:partition_id)` |
| user group → device group grant | **missing — this change** |

## Goals / Non-Goals

**Goals**
- Let an admin grant a user group write access to a device group.
- Keep every existing operator/admin capability byte-for-byte unchanged.
- Keep the decision expressible as an Ash `expr()` so it also works as a read
  filter, not only as a yes/no check on a loaded record.

**Non-Goals**
- Scoping *read* access. Devices stay readable fleet-wide under `devices.view`;
  this change is about writes. Restricting reads is a much larger blast radius
  (every list, every rollup, every SRQL query) and should be its own change.
- Per-device grants. The unit is the device group; a one-device group is the
  degenerate case.
- Reworking the permission catalog. Grants carry existing keys.

## Decisions

### Grant on device *group*, not on tags

The obvious cheap alternative is to authorize from a tag —
`tags.rids_owner == "team-x"` — since the RIDS import already writes tags.

Rejected: `tags` is writable by anyone holding `devices.update`. An actor with
scoped write access on one device could retag *that* device, or any device it
can already write, to widen its own scope. **Authorization must not read a field
that the authorized action can write.** `group_id` is a structural attribute
managed by group assignment, not free-form user input, which is why it is the
right key.

### Additive policy, not a replacement

```elixir
policy action_type(:update) do
  authorize_if @devices_update_check                       # unchanged
  authorize_if expr(group_id in ^actor(:granted_device_group_ids))
end
```

Ash `authorize_if` short-circuits on the first passing check, so a fleet-wide
operator never pays for the second branch, and no existing user loses access.
A user with *no* grants gets `[]`, and `group_id in []` is false — devices with
a `nil` `group_id` are unaffected either way.

### Load grants beside permissions, in the same cache

`RBAC.permissions_for_user/2` already runs a two-tier cache (process dictionary
→ shared ETS via `RBAC.Cache`, TTL'd, falling back to a DB query), and
`invalidate_user_cache/1` already broadcasts invalidation when a user's role or
profile changes.

Granted device group ids are looked up on the same path and cached in the same
entry, so the cache value becomes a struct rather than a bare `MapSet`. That is
the only breaking-ish detail in the change: anything reading the cached value
directly must be updated, and the cache entry format change means stale entries
must be invalidated on deploy (bump the cache key namespace).

Invalidation must additionally fire when:
- a grant is created, updated, or deleted,
- a user's membership in a granted user group changes,
- a device group is deleted.

### Why not `partition_id`

`partition_matches()` is the closest existing primitive, but partitions are
one-per-actor (an address-space context), whereas ownership is many-to-many — a
user can be in two teams, a device group can be granted to several groups. It
also would not survive a user belonging to two owning teams.

## Risks

- **Widening rather than narrowing.** This change only adds access. The failure
  mode to test for is a grant conferring more than its permission list says —
  e.g. a grant of `devices.update` must not enable `devices.delete`. The grant's
  permission list has to be checked, not just its existence.
- **Read/write asymmetry is deliberate but surprising**: a scoped user can see
  devices it cannot edit. The UI must disable rather than hide, so the boundary
  is legible.
- **Cache correctness.** A missed invalidation on grant revocation leaves write
  access live for the TTL. Revocation tests should assert the cache is cleared,
  not just that the row is gone.
