# Task 3 Report: Transactional Role Profile Lifecycle

## Outcome

Implemented the owned transactional lifecycle for custom role profiles. Human
create, update, and delete operations now reconstruct current authority through
`CurrentUserAuthority`; raw custom-profile actions require the private boundary
context; trusted system-profile create/update actions remain distinct for the
seeder. Update and delete gather direct and group-derived affected users inside
the transaction, and cache/audit effects run only after commit.

## RED evidence

Command:

```text
bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_identity //elixir/web-ng:unit_tests_phoenix_controllers //elixir/web-ng:unit_tests_phoenix_live --test_output=errors
```

Result: exit 3. The identity shard executed 94 tests and reported 2 failures
(70 excluded): the resource contract could not find RoleProfile
`:update_system` or User `:clear_role_profile_for_boundary`. The web shards
compiled the new database-backed stale-authority cases but excluded them; they
did not constitute executed RED coverage.

## GREEN evidence

The exact focused command above passed all three targets:

```text
//elixir/serviceradar_core:unit_tests_serviceradar_identity PASSED in 18.4s
//elixir/web-ng:unit_tests_phoenix_controllers              PASSED in 13.8s
//elixir/web-ng:unit_tests_phoenix_live                     PASSED in 34.4s
Executed 3 out of 3 tests: 3 tests pass.
```

A final no-cache LiveView shard after removing an obsolete duplicate success
clause also passed 1/1. The four reported web-ng dependency-boundary warnings
are pre-existing and unrelated.

Registration/selection gates passed:

```text
//build:integration_selection_formatter_test   PASSED
//build:integration_selection_equivalence_test PASSED
Executed 1 out of 2 tests: 2 tests pass.
```

Changed Elixir sources were formatted, BUILD/Starlark files were run through
buildifier, and `git diff --check` passed.

## Pending guarded database cases

Per the task ruling, no workstation database lifecycle, direct migration, or
focused database test was run.

- `privilege_mutation_boundaries_db_test.exs` is registered at exactly 22
  selected cases (13 existing plus 9 role-profile lifecycle cases). New cases
  cover outer transaction rejection, fresh authority for all three mutations,
  post-commit creation audit, direct/group invalidation with a duplicated user
  ID deduplicated to one effect, atomic reference clearing, rollback after
  clearing references, raw-action guards, trusted system actions, and seeder
  update.
- The controller and LiveView stale-authority cases are tagged
  `:web_ng_shared_fixture_db` and `sandbox: :unboxed`, and both files are listed
  in `//elixir/web-ng:networks_live_db_test`. Its exact selection count is 62
  (60 existing plus 2 new). Both register synthetic marker/email cleanup before
  writes. Execution remains pending the Task 7 in-cluster BuildBuddy workflow.
- Web DataCase now honors `sandbox: :unboxed` while its existing default path
  still starts and stops the ordinary rollback owner.

## Caller inventory and changes

- `AdminApi.Local` calls `RoleProfilePolicy` for create/update/delete.
- The HTTP controller calls AdminApi once per mutation and maps current-authority
  denial to the existing forbidden response.
- Policy Editor rename, create, permission persistence, and delete call
  `RoleProfilePolicy` directly.
- `RoleProfileSeeder` uses only trusted `create_system`/`update_system` actions.
- Public custom mutation code interfaces were removed; RoleProfile, User, and
  UserGroup raw mutation actions require `RequirePrivilegeBoundary`.
- RoleProfile and User invalidation changes now use `after_transaction` and are
  suppressed inside the owned boundary transaction.
- The legacy destroy-time assignment-clearing change was deleted. Dedicated
  guarded bulk-clear actions coordinate User and UserGroup references.
- Seventeen ancillary synthetic fixture call sites were mechanically updated to
  set the boundary context because the removed public custom-profile interface
  or new raw-action guard would otherwise break their containing suites.

## Self-review

The review found and fixed the LiveView delete branch still matching the old
`:ok` result instead of `{:ok, profile}`. It also verified the raw custom-profile
caller inventory, the effect-only adapter use, unchanged human authority source,
unboxed cleanup registration before writes, normal DataCase sandbox fallback,
synthetic/email-safe fixture values, and no remaining calls to
`RoleProfile.create_profile/2`, `update_profile/3`, or `delete_profile/2`.

## Concerns

The 11 newly registered guarded DB cases (9 core, 2 web) are intentionally not
executed in this task. Task 7 must run both the core integration selection and
`//elixir/web-ng:networks_live_db_test` in the in-cluster shared-fixture workflow.

## Review fix round 1

Addressed all three Important review findings:

- `:update_system` now validates that the target row is a system profile. The
  existing trusted-actions DB case now also proves a `SystemActor` cannot use it
  to update a custom profile, while the trusted system update still succeeds.
- The deletion-only User bulk-clear action now atomically clears
  `role_profile_id` and resets `role_profile_source` to `:manual`. The existing
  atomic deletion case assigns synthetic `:idp` provenance first and asserts
  both persisted fields after deletion.
- Creation-audit and update cache/audit callbacks now send
  `Repo.in_transaction?()` to the test owner. Assertions outside the rescued
  callbacks require the observed value to be `false`, so swallowed callback
  assertions cannot create a false pass. The duplicate-user invalidation check
  also rejects any third transaction-observation message.

The changes extend existing guarded cases, so the exact registered core count
remains 22. No workstation database test was run.

Formatter:

```text
mix format lib/serviceradar/identity/role_profile.ex \
  lib/serviceradar/identity/user.ex \
  test/serviceradar/identity/privilege_mutation_boundaries_db_test.exs
exit 0
```

Focused DB-free verification:

```text
bazel test -c opt --config=remote \
  //elixir/serviceradar_core:unit_tests_serviceradar_identity \
  --nocache_test_results --test_output=errors
//elixir/serviceradar_core:unit_tests_serviceradar_identity PASSED in 15.8s
Executed 1 out of 1 test: 1 test passes.
```

Bazel retained its existing size advisory: `There were tests whose specified
size is too big.` No new compiler warning was emitted.
