## 1. Group role-profile model and authority resolution

- [ ] 1.1 Add nullable `role_profile_id` and its restrictive foreign key/index to
      `platform.user_groups`, expose the Ash relationship, and generate a synthetic migration.
- [ ] 1.2 Resolve effective permissions as the set union of the existing base profile and every
      role profile attached to the user's current group memberships.
- [ ] 1.3 Make `CurrentUserAuthority` reload the complete user/membership/group/profile graph and
      bypass stale scope and process-local permission evidence for sensitive decisions.
- [ ] 1.4 Remove the indefinite process-dictionary permission cache, retain the shared bounded ETS
      cache, and make cross-process invalidation observable after commit.
- [ ] 1.5 Invalidate affected direct and group-derived permission caches after profile permission
      updates and profile deletion.
- [ ] 1.6 Add tests for no-group compatibility, multi-group union, duplicate permissions, assignment
      removal, membership removal, inactive users, lookup failure, a deliberately stale scope, and
      cross-process ETS invalidation.

## 2. Transactional privilege mutation boundaries

- [ ] 2.1 Add `ServiceRadar.Identity.GroupPolicy` for authorized assign/clear operations requiring
      fresh `settings.rbac.manage` and `identity.user_groups.manage` authority.
- [ ] 2.2 Add `ServiceRadar.Identity.PrivilegedMembership` for authorized add/remove/reconcile
      operations, preserving best-effort IdP sign-in behavior and manual membership provenance.
- [ ] 2.3 Add `ServiceRadar.Identity.RoleProfilePolicy` with fresh current-user authority and route
      all first-party LiveView/API create/update/delete operations through it; coordinate direct-user
      and group references on delete.
- [ ] 2.4 Reject caller-owned outer transactions with exactly
      `{:error, :outer_transaction_not_supported}` before writes or side effects.
- [ ] 2.5 Route first-party web and IdP group-membership mutations through the new boundary; do not
      use `SystemActor` in user-facing paths.
- [ ] 2.6 Emit append-only audit events and invalidate caches only after a successful commit; log
      audit-delivery failure without rolling back the committed mutation.
- [ ] 2.7 Add transaction tests proving rollback has no audit/cache effect, outer transactions are
      rejected, successful writes apply effects once, profile deletion clears direct and group
      assignments atomically, failed IdP mappings do not block sign-in, and manual memberships are
      never converted or withdrawn.

## 3. Monotonic dashboard group-access service

- [ ] 3.1 Add authorized, target-typed keyset queries for authored dashboards and packaged dashboard
      instances, with stable normalized-title/ID ordering and opaque source-bound cursors.
- [ ] 3.2 Add shared `ensure_group_view` and `revoke_group_view` operations backed by the existing
      authored/package grant resources.
- [ ] 3.3 Preserve `:edit` under view ensure/revoke operations, including concurrent view/edit
      requests; never create a redundant grant for a public target.
- [ ] 3.4 Change a private packaged target to `:shared` in the same transaction that ensures its
      group view; do not auto-tighten visibility on revoke.
- [ ] 3.5 Add dedicated Policy Editor resource actions requiring fresh `settings.rbac.manage` AND
      source-specific share permission AND canonical target authorization under the real actor;
      do not rely on generic package-action OR policies.
- [ ] 3.6 Route equivalent local group-view mutations through the same service and add focused unit
      plus guarded database/concurrency tests.
- [ ] 3.7 Emit dashboard ensure/revoke audit events only after commit, including package visibility
      transitions, and prove audit failure cannot veto the committed grant.

## 4. Policy Editor group/profile controls

- [ ] 4.1 Load group/profile assignment data only on connected mount with stable `assign_async`
      names and distinct loading, empty, success, generic error, and retry states.
- [ ] 4.2 Render a group-to-role-profile assignment control and persist assign/clear operations
      through `GroupPolicy` after fresh authorization.
- [ ] 4.3 Refresh affected UI state after success and stale/authorization failures without exposing
      internal error details.
- [ ] 4.4 Add LiveView tests for connected loading, empty state, generic error/retry, assign/clear,
      revoked authority, and late async results.

## 5. Policy Editor dashboard audiences

- [ ] 5.1 Add a group-centric dashboard access panel with independent authored/package loading,
      errors, opaque keyset cursors, stream resets, and bounded expected-state windows.
- [ ] 5.2 Label public and administrative-bypass availability explicitly; render public rows
      read-only and distinguish explicit `:view`, stronger `:edit`, and no group grant.
- [ ] 5.3 Send only operation and opaque row/group tokens from browser events; re-read authorized
      canonical state and compare a server-held fingerprint bound to the selected group and
      group-selection epoch before every write.
- [ ] 5.4 On missing/stale/unauthorized state, make no mutation, reload the affected source, and show
      a visible stale-state or authorization notice.
- [ ] 5.5 Add LiveView tests for independent pagination, bounded streams/windows, public read-only
      rows, edit preservation, malformed/forged tokens, stale rows, revoked authority, and one
      source failing without erasing the other.

## 6. Verification and documentation

- [ ] 6.1 Apply migrations with `mix serviceradar.db.migrate` and run policy/concurrency coverage
      through the guarded Bazel database-test lifecycle using only synthetic fixtures.
- [ ] 6.2 Run focused Bazel tests during each red/green loop, then the canonical full remote unit
      suite with `make test`.
- [ ] 6.3 Run repository-required Elixir formatting/quality checks for both affected applications
      and confirm their actual output is clean.
- [ ] 6.4 Validate `improve-rbac-policy-editor`, `add-dashboard-creator`, and
      `add-dashboard-package-access-control` with `openspec validate --strict`.
- [ ] 6.5 Update operator-facing documentation and CHANGELOG only where the implemented UI or
      migration behavior requires it, using wholly synthetic examples.
