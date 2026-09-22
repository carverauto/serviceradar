## 1. Group role-profile model and authority resolution

- [x] 1.1 Add nullable `role_profile_id` and its restrictive foreign key/index to
      `platform.user_groups`, expose the Ash relationship, and generate a synthetic migration.
- [x] 1.2 Resolve effective permissions as the set union of the existing base profile and every
      role profile attached to the user's current group memberships.
- [x] 1.3 Make `CurrentUserAuthority` reload the complete user/membership/group/profile graph and
      bypass stale scope and process-local permission evidence for sensitive decisions.
- [x] 1.4 Remove the indefinite process-dictionary permission cache, retain the shared bounded ETS
      cache, and make cross-process invalidation observable after commit.
- [x] 1.5 Invalidate affected direct and group-derived permission caches after profile permission
      updates and profile deletion.
- [x] 1.6 Add tests for no-group compatibility, multi-group union, duplicate permissions, assignment
      removal, membership removal, inactive users, lookup failure, a deliberately stale scope, and
      cross-process ETS invalidation.
- [x] 1.7 Move every single-profile security adapter to the strict union resolver and make authority
      snapshots use `%{permissions: MapSet.t(), profile_versions: [...]}` end to end; update callback
      and secure-execution issuers, source behaviours, adapters, rechecks, and digests.

## 2. Transactional privilege mutation boundaries

- [x] 2.1 Add `ServiceRadar.Identity.GroupPolicy` for authorized assign/clear/delete operations
      requiring fresh `settings.rbac.manage` and `identity.user_groups.manage` authority, including
      post-commit invalidation for memberships cascaded by group deletion.
- [x] 2.2 Add `ServiceRadar.Identity.PrivilegedMembership` for authorized add/remove/reconcile
      operations, preserving best-effort IdP sign-in behavior and manual membership provenance.
- [x] 2.3 Add `ServiceRadar.Identity.RoleProfilePolicy` with fresh current-user authority and route
      all first-party LiveView/API create/update/delete operations through it; coordinate direct-user
      and group references on delete.
- [x] 2.4 Reject caller-owned outer transactions with exactly
      `{:error, :outer_transaction_not_supported}` before writes or side effects.
- [x] 2.5 Route first-party web and IdP group-membership mutations through the new boundary; do not
      use `SystemActor` in user-facing paths.
- [x] 2.6 Emit append-only audit events and invalidate caches only after a successful commit; log
      audit-delivery failure without rolling back the committed mutation.
- [x] 2.7 Add transaction tests proving rollback has no audit/cache effect, outer transactions are
      rejected, successful writes apply effects once, profile deletion clears direct and group
      assignments atomically, failed IdP mappings do not block sign-in, and manual memberships are
      never converted or withdrawn.
- [x] 2.8 Require boundary-owned changeset context on membership, group-profile, role-profile, and
      group-destroy resource actions so unsupported direct mutation calls fail before persistence;
      preserve explicit trusted create/update-system actions for role-profile seeding.

## 3. Monotonic dashboard group-access service

- [x] 3.1 Add authorized, target-typed keyset queries for authored dashboards and packaged dashboard
      instances, with stable normalized-title/ID ordering and opaque source-bound cursors.
- [x] 3.2 Add shared `ensure_group_view` and `revoke_group_view` operations backed by the existing
      authored/package grant resources.
- [x] 3.3 Preserve `:edit` under view ensure/revoke operations, including concurrent view/edit
      requests; never create a redundant grant for a public target.
- [x] 3.4 Change a private packaged target to `:shared` in the same transaction that ensures its
      group view; do not auto-tighten visibility on revoke.
- [x] 3.5 Add dedicated Policy Editor resource actions requiring fresh `settings.rbac.manage` AND
      source-specific share permission AND canonical target authorization under the real actor;
      do not rely on generic package-action OR policies.
- [x] 3.6 Route equivalent local group-view mutations through the same service and add focused unit
      plus guarded database/concurrency tests.
- [x] 3.7 Emit dashboard ensure/revoke audit events only after commit, including package visibility
      transitions, and prove audit failure cannot veto the committed grant.
- [x] 3.8 Reject caller-owned outer transactions with
      `{:error, :outer_transaction_not_supported}` before dashboard writes or side effects.
- [x] 3.9 Route every first-party group-grant create/update/destroy, including local `:edit`, through
      one `(source, target, group)` transaction-scoped advisory-lock coordinator before fingerprint
      comparison; require boundary-owned context on group-subject resource actions.

## 4. Policy Editor group/profile controls

- [x] 4.1 Load group/profile assignment data only on connected mount with stable `assign_async`
      names and distinct loading, empty, success, generic error, and retry states.
- [x] 4.2 Render a group-to-role-profile assignment control and persist assign/clear operations
      through `GroupPolicy` after fresh authorization.
- [x] 4.3 Refresh affected UI state after success and stale/authorization failures without exposing
      internal error details.
- [x] 4.4 Add LiveView tests for connected loading, empty state, generic error/retry, assign/clear,
      revoked authority, and late async results.

## 5. Policy Editor dashboard audiences

- [x] 5.1 Add a group-centric dashboard access panel with independent authored/package loading,
      errors, opaque keyset cursors, stream resets, and bounded expected-state windows.
- [x] 5.2 Label public and administrative-bypass availability explicitly; render public rows
      read-only and distinguish explicit `:view`, stronger `:edit`, and no group grant.
- [x] 5.3 Send only operation and opaque row/group tokens from browser events; re-read authorized
      canonical state and compare a server-held fingerprint bound to the selected group and
      group-selection epoch before every write.
- [x] 5.4 On missing/stale/unauthorized state, make no mutation, reload the affected source, and show
      a visible stale-state or authorization notice.
- [x] 5.5 Add LiveView tests for independent pagination, bounded streams/windows, public read-only
      rows, edit preservation, malformed/forged tokens, stale rows, revoked authority, and one
      source failing without erasing the other.

## 6. Verification and documentation

Items 1.1-5.5 record implemented and reviewed code with focused DB-free unit/contract coverage and
guarded runtime evidence.

- [x] 6.1 Apply migrations with `mix serviceradar.db.migrate` and run policy/concurrency coverage
      through the guarded Bazel database-test lifecycle using only synthetic fixtures.
      Evidence: the landing-state BazelCI lifecycle at `0c0d04fd85` provisioned its generated
      database, applied migrations through `20260905130000` (invocation
      `6ee2a12e-8a25-4481-b966-c9bc612ddf16`), passed the guarded core/policy/concurrency wave
      (`4e36671e-6543-4afc-81e5-6abc58697a6e`), passed the guarded web/LiveView wave
      (`729766e5-3a25-4596-8f63-637fb094b6c9`), and tore the database down
      (`c9192a29-8642-43ad-b7af-5928360e67b3`).
- [x] 6.2 Run focused Bazel tests during each red/green loop, then the canonical full remote unit
      suite with `make test`.
      Evidence: `make test` at `4038b43f64` passed all 214 targets (24 executed, 190 cached),
      exit 0; invocation `fb3ee81b-2f92-4fa3-973e-44cdcc1a2f76`.
- [x] 6.3 Run repository-required Elixir formatting/quality checks for both affected applications
      and confirm their actual output is clean.
      Evidence: both `./scripts/elixir_quality.sh --lint-only` invocations passed at the final
      worktree state (`--project elixir/web-ng --phoenix`: 1,306 files; `--project
      elixir/serviceradar_core`: 2,380 files), with no Credo issues and clean format checks.
      A supplemental changed-path analyzer audit found no Dialyzer warning in a changed web-ng
      file. Core's repository-wide run retained its existing warning baseline and emitted seven
      changed-path warnings, all Dialyzer opaque-type false positives for ordinary `MapSet`
      equality in three authority modules; Dialyxir cannot render those OTP 28 warnings in strict
      ignore-file format. Sobelow likewise reported only three findings outside the PR delta.
      Per the repository analyzer policy, the false positives are recorded rather than replacing
      idiomatic calls with runtime shape or opacity barriers.
- [x] 6.4 Validate `improve-rbac-policy-editor`, `add-dashboard-creator`, and
      `add-dashboard-package-access-control` with `openspec validate --strict`.
- [x] 6.5 Update operator-facing documentation and CHANGELOG only where the implemented UI or
      migration behavior requires it, using wholly synthetic examples.
