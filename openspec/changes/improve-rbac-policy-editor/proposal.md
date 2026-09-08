# Change: Improve the RBAC policy editor

## Why

GitHub issue #4153 asks for two related administration workflows that the current policy editor
does not provide. Administrators cannot attach a role profile to a reusable user group, so the
same policy must be assigned user by user. They also cannot manage which dashboards a group can
view from the central RBAC surface, even though authored and packaged dashboards already have
canonical group-grant resources.

These workflows change effective authorization, not just presentation. Membership changes,
profile deletion, cache invalidation, concurrent dashboard-grant edits, and stale LiveView state
must therefore be defined together so that a successful UI action cannot leave an actor with
permissions that were revoked in persistence.

## What Changes

- Add one optional role-profile association to each reusable `Identity.UserGroup`.
- Resolve a user's effective permissions as the set union of the existing direct or built-in role
  profile and the role profiles attached to every current group membership.
- Make sensitive authorization reload the complete current authority from persistence instead of
  trusting permissions captured in a session, socket, or process-local cache.
- Remove the indefinitely lived process-dictionary permission cache so a committed cross-process
  invalidation can actually revoke ordinary cached authority; keep the shared ETS cache as the
  bounded fast path.
- Introduce transaction-owning group-policy and privileged-membership mutation boundaries. They
  authorize the caller, reject caller-owned outer transactions, and publish audit/cache effects
  only after a successful commit.
- Route role-profile create, update, and delete through the same fresh-authority/post-commit
  discipline, including coordinated clearing of direct-user and user-group references on delete.
- Extend the Policy Editor with an asynchronously loaded user-group/profile assignment surface.
- Add a central dashboard-audience surface for a selected user group. It reuses
  `DashboardAccessGrant` for authored dashboards and `DashboardInstanceAccessGrant` for packaged
  dashboards rather than adding another ACL table or making role profiles dashboard principals.
- Make group `:view` changes monotonic: an existing `:edit` grant is never downgraded or removed by
  a view-only operation. A private packaged dashboard becomes shared transactionally when view is
  granted; removing the final group view does not automatically make it private again.
- Add dedicated Policy Editor resource actions whose checks combine RBAC management,
  source-specific sharing, and target authorization with AND semantics instead of relying on the
  more permissive generic package-grant action.
- Paginate authored and packaged dashboards independently with stable keyset cursors, bounded
  LiveView streams, server-owned expected state, and explicit stale-state handling.
- Clarify the pending dashboard-creator proposal so dashboard-local sharing remains available while
  a central administrator mirror may also exist.
- Replace a pending real-deployment migration check with a wholly synthetic pre-upgrade fixture, in
  accordance with the repository's captured-data prohibition.

## Impact

- Affected specs: `ash-authorization` (added requirements), `rbac-policy-management` (restored as a
  current capability), and coordinated wording in the active `dashboard-creator` change.
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/identity/**`
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live.ex`
  - focused core, web-ng, and guarded database tests
- Existing users without group profile assignments keep their current effective permissions.
- Existing dashboard visibility and administrative bypass rules remain authoritative. The central
  editor manages explicit group grants; it is not a strict allowlist and does not conceal global
  access supplied by `:public` visibility or `view_all` permissions.
- The change is scoped to the current instance-local database authority path. Propagating
  group-derived permissions through a future coarse-role tenant JWT is explicitly out of scope.
