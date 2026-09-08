## Context

The current `UserGroup` resource is reusable by dashboard grants but has no role-profile
association. `Identity.RBAC` selects exactly one profile: an explicit user profile or the system
profile corresponding to the user's built-in role. Normal UI checks can use permissions captured
when a scope or socket was created, while `CurrentUserAuthority` is the boundary intended for
sensitive operations.

The Policy Editor currently edits role-profile permission matrices only. Authored dashboards use
`DashboardAccessGrant`; packaged dashboard instances use `DashboardInstanceAccessGrant`. Those
resources deliberately differ in target and visibility semantics, so a central dashboard editor
must coordinate them rather than replace them with a generic ACL.

## Goals

- Let an administrator assign zero or one role profile to each user group.
- Make every current group membership contribute that group's profile permissions.
- Make privilege changes visible immediately after commit and auditable without letting audit
  delivery veto the business transaction.
- Let an administrator manage a group's explicit view access to both dashboard kinds from the
  Policy Editor.
- Preserve stronger dashboard grants, enforce actor authorization, and reject stale browser state.
- Keep LiveView memory and queries bounded as the dashboard catalog grows.

## Non-Goals

- Multiple role profiles on one group.
- A generic cross-resource ACL table or a role-profile dashboard-grant subject.
- A dashboard allowlist that overrides `:public` visibility or administrative bypass permissions.
- Changing authored-dashboard edit semantics or package-dashboard local sharing semantics.
- Encoding group-derived permissions into the future tenant-control-plane JWT contract.
- Migrating existing users or groups to new role-profile assignments automatically.

## Decisions

### Decision 1: One nullable role-profile reference on `UserGroup`

Add nullable `role_profile_id` to `platform.user_groups`, backed by a restrictive foreign key to
`platform.role_profiles`, and expose the corresponding Ash relationship. One group therefore
contributes at most one profile, while a user may receive many group profiles by belonging to many
groups.

This is the smallest model matching the approved product contract. A join table would add
many-to-many policy composition that the issue does not request. Profile deletion is coordinated by
the application boundary: references from users and groups are cleared in the same transaction
before the profile is destroyed. The database constraint prevents an uncoordinated delete from
leaving a dangling reference.

### Decision 2: Effective permissions are a deterministic set union

The existing base profile remains either the user's explicit profile or the system profile for the
user's built-in role. The resolver then loads every non-null profile attached to the user's current
group memberships and unions every permission key into one `MapSet`. Duplicate keys and duplicate
paths to the same profile have no additional effect. Query ordering is stable for reproducible
diagnostics, but authorization depends only on set membership.

A group profile augments the base profile; it does not replace it. A user with no associated group
profiles receives the same permissions as before this change.

Every security-sensitive adapter that currently asks for one effective profile moves to the strict
effective-authority resolver. The shared snapshot shape is `%{permissions: MapSet.t(),
profile_versions: [%{id: String.t(), updated_at: DateTime.t()}]}`, with profile versions sorted by
ID. `CurrentUserAuthority` returns that shape alongside the reloaded user, and callback/secure
execution issue and recheck paths preserve it end to end. Where an authorization grant digest must
describe the snapshot, it includes all profile versions plus the permission-set digest; a
single-profile timestamp is no longer sufficient.

### Decision 3: Sensitive decisions rebuild complete current authority

`CurrentUserAuthority` remains the canonical boundary for sensitive actions. It reloads the active
user, memberships, groups, referenced profiles, and profile permissions from persistence for the
decision. It must not use permissions stored in the incoming scope/socket or the process-dictionary
level of the RBAC cache as evidence. A failure or inactive user fails closed.

The indefinitely lived process-dictionary (L1) permission cache is removed. Ordinary checks may
continue using permissions already present in a scope for display and the shared TTL-bounded ETS
cache as the resolver fast path. Removing L1 makes a cross-process invalidation effective rather
than leaving stale values inside unrelated LiveView processes. Mutations invalidate ETS and notify
subscribers after commit:

- membership add/remove invalidates the affected user;
- group profile assign/clear invalidates every current member;
- profile permission changes invalidate direct assignees and members of associated groups; and
- profile deletion invalidates every user whose direct or group assignment was cleared.

Tests exercise two processes: one populates ordinary cached authority and another commits a
revocation. The first process must miss the invalidated shared cache on its next resolver call.

### Decision 4: Privilege-bearing mutations own their transaction

Add three public boundaries:

- `ServiceRadar.Identity.GroupPolicy` for assigning or clearing a group's profile and for deleting
  a group whose cascading memberships may revoke derived permissions;
- `ServiceRadar.Identity.RoleProfilePolicy` for creating, updating, and deleting role profiles,
  including coordinated clearing of direct-user and user-group references during deletion; and
- `ServiceRadar.Identity.PrivilegedMembership` for adding, removing, and reconciling memberships.

Each boundary accepts the real actor and performs authorized Ash operations inside a transaction it
owns. User-facing paths must not substitute `SystemActor`; trusted IdP synchronization may use its
existing system actor. Calling any public boundary while `Repo.in_transaction?/0` is true returns
the stable error `{:error, :outer_transaction_not_supported}` before any write, audit publication,
or cache mutation.

After the owned transaction commits, the boundary invalidates affected caches and emits an
append-only audit event containing actor, target, operation, and assignment identifiers. Those side
effects never occur for a rollback. Audit-delivery failure is logged and observable but cannot
reject or undo the committed authorization change.

Audit submission is best effort after commit, matching the current audit transport. This change
does not claim crash-proof exactly-once delivery; a transactional audit outbox would be a separate
capability.

All first-party membership, group-profile, and role-profile mutation callers, including LiveView
and HTTP API paths, route through these boundaries. Raw resource actions remain internal
implementation details rather than alternate public mutation paths.

Boundary-owned changeset context is required by the custom-profile, group-profile, membership, and
group-destroy resource actions. Unsupported direct calls fail before persistence. Trusted system
profile seeding uses separate explicit create/update-system actions and remains covered by a
regression test; it does not reopen the human mutation actions.

`GroupPolicy` assignment/clear requires fresh `settings.rbac.manage` and
`identity.user_groups.manage`; loading the assignment surface additionally requires
`identity.user_groups.view`. Dedicated assignment actions enforce that conjunction rather than
relying on the generic `UserGroup.update` policy alone.

IdP reconciliation keeps its existing availability and provenance contract. The reconciliation is
best effort across groups, and each individual IdP-created add/remove owns its own transaction.
Failure for one mapping is logged and skipped without blocking sign-in or rolling back successful
independent mappings. An existing manual membership is never converted to `:idp`, overwritten by an
IdP upsert, or removed when an IdP claim disappears; withdrawal selects only memberships whose
persisted `source` is `:idp`.

### Decision 5: Dashboard audiences reuse the two canonical grant resources

The central editor is group-centric. Selecting a user group shows independently paginated authored
dashboards and packaged dashboard instances. Toggling explicit view access writes a group-subject
grant to the existing resource for that dashboard kind:

- authored dashboard -> `DashboardAccessGrant`;
- packaged dashboard instance -> `DashboardInstanceAccessGrant`.

No role-profile subject and no third grant table are introduced. Local dashboard sharing controls
remain available and call the same group view operations, so local and central surfaces cannot
silently diverge.

### Decision 6: View mutations are monotonic and visibility-aware

The dashboard access service exposes target-typed `ensure_group_view/4` and
`revoke_group_view/4` operations under a transaction it owns.

`ensure_group_view` creates a `:view` grant when none exists and leaves an existing `:edit` grant
unchanged. It must remain monotonic under concurrent view/edit requests; a stale view write cannot
downgrade a committed edit grant. For a private packaged dashboard, the same transaction changes
visibility to `:shared` before making the group grant effective. A public target is already
available and renders read-only in this view, so the central editor does not create a redundant
grant.

`revoke_group_view` deletes only an exact `:view` group grant. It does not delete or downgrade
`:edit`, and it does not change a packaged dashboard back to private after the last view grant is
removed. Visibility tightening remains an explicit dashboard-owner operation.

Every first-party group-grant create/update/destroy, including local `:edit` changes, routes through
the same coordinator. The coordinator takes a transaction-scoped PostgreSQL advisory lock derived
from `(source, target_id, group_id)` before rereading the target/grant fingerprint. This serializes
the absent-grant case that a target row lock alone cannot protect. Group-specific resource actions
require boundary-owned context; user-subject grant actions remain unchanged.

The Policy Editor entry actions require these exact conjunctions:

- authored: fresh `settings.rbac.manage` AND `analytics.dashboards.share` AND one target-management
  path (owner, explicit `:edit` grant, or `analytics.dashboards.edit`);
- packaged: fresh `settings.rbac.manage` AND `dashboards.packages.share` AND one target-management
  path (owner, explicit `:edit` grant, or `dashboards.packages.view_all`).

Dedicated authored/package resource actions encode these conjunctions; the central service does not
rely on the generic package grant or visibility actions whose existing policy clauses are
alternatives. Dashboard-local controls use their existing local authorization entry actions. Both
entry paths call the same internal monotonic mutation primitive, so authorization context can
differ without grant semantics drifting. Authorized Ash reads/writes remain the enforcement
boundary; user-facing operations never use `SystemActor`.

The dashboard service rejects `Repo.in_transaction?/0` with
`{:error, :outer_transaction_not_supported}` before work, then owns its transaction. This is needed
for the same post-commit audit guarantee as the identity mutation boundaries.

After a dashboard group-view transaction commits, the shared service emits an append-only audit
event for ensure/revoke (and any package visibility transition). Audit failure is logged and cannot
reject or undo the committed grant. Rolled-back and denied attempts do not emit a success event.

### Decision 7: Independent keyset pages and bounded streams

Authored and packaged targets use separate stable keysets ordered by normalized title and target ID.
Each cursor is opaque to the browser and bound to its source. Moving one source does not reset or
advance the other.

Each source page resets only that source's LiveView stream and replaces only that source's
server-side expected-state window. Each source retains only the current page's before/after keysets,
not an accumulating navigation history. The window contains at most the current page and maps an opaque
row token to the selected group identity, a monotonically changed group-selection epoch, target
identity, and a canonical fingerprint (target visibility/version and explicit group-grant
identity/access/version). Rows paged out of the stream are removed from the expected window.

### Decision 8: The browser requests intent; the server owns expected state

A toggle event contains only the selected group token, opaque row token, and requested operation.
It does not contain a dashboard ID, current grant state, visibility, timestamp, or expected version
that the server treats as canonical.

Before writing, the server resolves both tokens from server state, requires the row entry's group
identity and selection epoch to match the currently selected group, reloads the authorized target
and group grant, and compares the new canonical fingerprint with the stored one. A missing token,
cross-group/old-epoch token, unauthorized target, or mismatch performs no mutation, reloads the
affected page/row, and renders a visible stale-state notice. This prevents a delayed or forged
browser event from applying an operation to a different group or newly changed resource.

### Decision 9: Connected async loading distinguishes failure from emptiness

The group/profile controls begin their database work only after the LiveView is connected, using a
stable `assign_async` name so late results cannot overwrite a newer load. Loading, empty, success,
and error states are distinct. Errors render a generic retryable message and are logged with their
internal cause; internal error terms are never sent to the browser and a failed query is never
rendered as an empty group list.

The two dashboard sources have independent loading/error/page state, so a package query failure does
not erase an authored-dashboard page or vice versa.

## Migration and Rollout

1. Add the nullable `role_profile_id` foreign key and index to `platform.user_groups`.
2. Deploy the resolver and mutation boundaries with no automatic assignments. Existing effective
   permissions remain unchanged because every existing group reference is null.
3. Deploy the Policy Editor controls and dashboard audience editor.
4. Verify migrations and policies against a database created only from repository-owned synthetic
   fixtures using `mix serviceradar.db.migrate` through the guarded Bazel integration lifecycle.
5. Rollback may leave the nullable column in place; older code ignores it. Clear new assignments
   before a long-term downgrade if group-derived permissions must stop immediately.

## Risks and Mitigations

- **Stale permission survives a mutation.** Post-commit invalidation covers membership, group
  assignment, profile update, and profile deletion; the unbounded L1 cache is removed, and sensitive
  actions rebuild authority regardless of cache state.
- **A failed transaction publishes a misleading audit event.** Public boundaries own transactions
  and do all external side effects only after successful commit.
- **Concurrent view assignment downgrades edit.** The shared ensure-view action performs a
  monotonic database update and is covered by a concurrent integration test.
- **Large catalogs exhaust LiveView memory.** Independent keyset pages reset bounded streams and
  expected-state windows.
- **The UI appears to promise exclusive access.** Public visibility, stronger edit grants, and
  source-specific base read gates, stronger edit grants, and generic global-bypass guidance are
  shown explicitly; the editor labels its toggles as explicit group view grants and does not claim
  to enumerate every member's effective permission sources.

## Rejected Alternatives

- **Many-to-many group/profile assignments:** adds unrequested composition and a second assignment
  resource.
- **Dashboard IDs stored on role profiles:** conflates permission bundles with row-level resource
  grants and bypasses existing authorization policies.
- **One generic dashboard grant table:** loses target foreign-key integrity and duplicates shipped
  resource semantics.
- **Offset pagination or full lists:** creates unstable pages and unbounded socket memory.
- **Client-supplied expected versions:** makes the browser an authority over state it can forge or
  delay.
- **Audit inside the database transaction:** lets an append-only observation become a write veto or
  records work that later rolls back.

## Open Questions

None. The product choices above reflect the approved recommendation for issue #4153.
