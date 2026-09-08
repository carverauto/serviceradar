# RBAC Policy Editor Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let administrators attach one role profile to a reusable user group and manage that group's explicit authored/package dashboard view grants from the Policy Editor without stale authority, privilege-downgrade races, or unbounded LiveView state.

**Architecture:** A strict identity authority resolver unions the existing base profile with profiles attached to current group memberships and uses one bounded ETS cache. Three transaction-owning identity boundaries and one dashboard group-access boundary perform fresh authorization, database writes, and post-commit effects. The LiveView delegates domain behavior to those boundaries, loads data asynchronously, pages each dashboard source independently, and treats server-held row fingerprints as the only expected state.

**Tech Stack:** Elixir, Ash/AshPostgres, Ecto/PostgreSQL, Phoenix LiveView streams and async assigns, ExUnit, Bazel remote execution, BuildBuddy guarded database tests, OpenSpec.

**Spec:** `openspec/changes/improve-rbac-policy-editor/`

## Global Constraints

- `Identity.UserGroup` has zero or one `role_profile_id`; do not introduce a group/profile join table.
- Effective permissions are the set union of the direct-or-built-in base profile and every profile attached to a current group membership.
- Remove the indefinitely lived process-dictionary RBAC cache. The shared TTL-bounded ETS cache is the only resolver cache.
- Sensitive authority reads are strict and fail closed; stale scope permissions and ETS entries are never fallback evidence.
- Public identity and dashboard mutation boundaries return exactly `{:error, :outer_transaction_not_supported}` when called inside a caller-owned repository transaction.
- Cache invalidation and audit submission occur only after the owned transaction commits. Audit failure is logged and does not undo the committed write; crash-proof exactly-once audit delivery is out of scope.
- User-facing mutations authorize the reconstructed human actor. `SystemActor` is allowed only for the existing trusted IdP/system-seeding paths.
- IdP reconciliation stays best effort across mappings and never converts, overwrites, or withdraws a persisted `:manual` membership.
- Dashboard access continues to use `DashboardAccessGrant` and `DashboardInstanceAccessGrant`; do not add a generic ACL or role-profile grant subject.
- A Policy Editor authored mutation requires `settings.rbac.manage` AND `analytics.dashboards.share` AND owner, explicit `:edit`, or `analytics.dashboards.edit` target authority.
- A Policy Editor package mutation requires `settings.rbac.manage` AND `dashboards.packages.share` AND owner, explicit `:edit`, or `dashboards.packages.view_all` target authority.
- Ensuring `:view` and revoking exact `:view` never downgrade or delete `:edit`, including under concurrency.
- A private package becomes `:shared` in the grant transaction; revocation never automatically tightens visibility.
- Public authored rows say they are available to users with analytics access; public package rows say they are available to authenticated users. Both are read-only in the group audience editor.
- Authored and package pages use independent required keysets with a maximum page size of 50, bounded streams, and bounded server-only expected-state maps.
- A row token is bound to its source, selected group, and group-selection epoch. Browser fields beyond group token, row token, and operation are ignored.
- Tests and examples use values invented from scratch. Never copy, sanitize, or reshape captured deployment data.
- Do not add or extend shell scripts. Build, test, migration, and verification operations remain Bazel targets or existing repository commands.
- Apply database changes with `mix serviceradar.db.migrate`, never `mix ecto.migrate`.

---

### Task 1: Strict Effective Authority and Shared Cache

**Files:**

- Create: the timestamped file emitted by `mix ecto.gen.migration add_role_profile_to_user_groups` under `elixir/serviceradar_core/priv/repo/migrations/`
- Create: `elixir/serviceradar_core/test/serviceradar/identity/user_group_role_profile_contract_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/identity/effective_permissions_db_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/user_group.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/role_profile.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/rbac.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/rbac/cache.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/current_user_authority.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/awx_membership_approval.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/secure_child_launcher/ash_adapter.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/secure_child_launcher/adapter.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/secure_child_launcher.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/secure_execution_current_authority.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/secure_execution_current_authority/source.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/secure_execution_current_authority/ash_source.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/callback_grants/current_authority.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/callback_grants/current_authority_source.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/callback_grants/current_authority_ash_source.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/identity/current_user_authority_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/automation/callback_grants/current_authority_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/automation/ansible/awx_membership_approval_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/automation/ansible/secure_launch_authorization_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/automation/ansible/secure_child_launcher_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/automation/ansible/secure_execution_current_authority_test.exs`
- Modify: `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`
- Modify: `build/integration_test_dispositions.bzl`

**Interfaces:**

- Produces: `RBAC.effective_authority(user, actor) :: {:ok, %{permissions: MapSet.t(String.t()), profile_versions: [%{id: String.t(), updated_at: DateTime.t()}]}} | {:error, term()}`.
- Produces: `RBAC.effective_permissions(user, actor) :: {:ok, MapSet.t(String.t())} | {:error, term()}`.
- Preserves: `RBAC.effective_profile/2` as the singular base-profile compatibility helper.
- Produces: nullable `UserGroup.role_profile_id` and `belongs_to :role_profile`.
- Consumers in later tasks rely on `CurrentUserAuthority.authorize/3` returning `%{user: user, permissions: permissions, profile_versions: profile_versions}` without using ETS.

- [ ] **Step 1: Add a failing DB-free resource contract test**

Mark `user_group_role_profile_contract_test.exs` `@moduletag :db_free` and add literal assertions that the resource exposes the relationship:

```elixir
test "user groups expose one optional role profile" do
  assert Ash.Resource.Info.attribute(UserGroup, :role_profile_id).allow_nil?
  assert Ash.Resource.Info.relationship(UserGroup, :role_profile).destination == RoleProfile
end

```

- [ ] **Step 2: Add failing strict-union and cache tests**

Cover a direct base profile plus two group profiles, duplicate permission keys, a group without a profile, removal, lookup failure, and cross-process invalidation. The guarded cross-process test must use the unboxed sandbox, supervise/monitor the resolver process, and observe the second resolved permission set rather than merely an invalidation message:

```elixir
assert {:ok, permissions} = RBAC.effective_permissions(user, store_actor)
assert permissions == MapSet.new(["devices.view", "services.update", "alerts.acknowledge"])

resolver_spec =
  Task.child_spec(fn ->
    receive_loop = fn receive_loop ->
      receive do
        {:resolve, reply_to} ->
          send(reply_to, {:resolved, RBAC.permissions_for_user(user)})
          receive_loop.(receive_loop)

        :stop ->
          :ok
      end
    end

    receive_loop.(receive_loop)
  end)
  |> Supervisor.child_spec(id: make_ref())

resolver = start_supervised!(resolver_spec)
resolver_ref = Process.monitor(resolver)

send(resolver, {:resolve, self()})
assert_receive {:resolved, before_revoke}
assert MapSet.member?(before_revoke, "services.update")

ServiceRadar.Repo.update_all(
  from(g in "user_groups", prefix: "platform", where: g.id == ^group.id),
  set: [role_profile_id: nil]
)

assert :ok = RBAC.invalidate_user_cache(user.id)
send(resolver, {:resolve, self()})
assert_receive {:resolved, after_revoke}
refute MapSet.member?(after_revoke, "services.update")
send(resolver, :stop)
assert_receive {:DOWN, ^resolver_ref, :process, ^resolver, :normal}
```

For the RED assertion, plant `Process.put({:rbac_permissions, user.id}, stale)` and call ordinary `RBAC.permissions_for_user/2`; baseline must return the stale value. Separately prove strict `CurrentUserAuthority` reloads group-derived permissions and denies graph-load errors.

- [ ] **Step 3: Run the focused tests and capture RED evidence**

Run the DB-free RED first:

```bash
bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_identity //elixir/serviceradar_core:unit_tests_serviceradar_automation --test_output=errors
```

Expected: failures because `role_profile_id`, `effective_authority/2`, and group-derived permission loading do not exist and the process-dictionary value is still accepted by ordinary resolution.

Register `effective_permissions_db_test.exs` in both integration disposition manifests, then run its assigned guarded BuildBuddy lane with `--nocache_test_results` before implementation. Expected: the database cases fail because the column and strict union do not exist. The ordinary unit target is not evidence for this DB file.

- [ ] **Step 4: Generate and implement the nullable group-profile migration**

From `elixir/serviceradar_core`, invoke the repository-required generator and record the exact emitted path:

```bash
unbuffer -p mix ecto.gen.migration add_role_profile_to_user_groups
```

Implement the migration with synthetic schema-only data:

```elixir
alter table(:user_groups, prefix: "platform") do
  add :role_profile_id,
      references(:role_profiles,
        prefix: "platform",
        type: :uuid,
        on_delete: :restrict
      )
end

create index(:user_groups, [:role_profile_id], prefix: "platform")
```

Now add a migration contract test that proves exactly one generator result exists without hard-coding a collision-prone timestamp:

```elixir
test "migration uses a restrictive role-profile foreign key" do
  pattern = Path.expand("../../../priv/repo/migrations/*_add_role_profile_to_user_groups.exs", __DIR__)
  assert [path] = Path.wildcard(pattern)
  sql = File.read!(path)
  assert sql =~ "references(:role_profiles"
  assert sql =~ "on_delete: :restrict"
  assert sql =~ "create index(:user_groups, [:role_profile_id]"
end
```

Expose the public attribute and `belongs_to` relationship on `UserGroup`, but do not add the field to the generic create/update accepted fields. Add reverse `has_many` relationships on `RoleProfile` for affected-user queries.

- [ ] **Step 5: Implement the strict authority graph**

Keep the base-profile lookup and load group contributions in bounded queries/preloads. Return contributing profiles in deterministic ID order:

```elixir
@spec effective_authority(User.t(), map()) ::
        {:ok,
         %{
           permissions: MapSet.t(String.t()),
           profile_versions: [%{id: String.t(), updated_at: DateTime.t()}]
         }} |
          {:error, term()}
def effective_authority(%User{} = user, actor) do
  with {:ok, base} <- effective_profile(user, actor),
       {:ok, memberships} <- UserGroupMembership.list_by_user(user.id, actor: actor),
       {:ok, groups} <- load_groups_with_profiles(memberships, actor) do
    profiles =
      [base | Enum.map(groups, & &1.role_profile)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&to_string(&1.id))

    {:ok,
     %{
       permissions: union_permissions(profiles),
       profile_versions: Enum.map(profiles, &profile_version/1)
     }}
  end
end
```

Treat a truly absent built-in/custom base as an error in the strict API. `permissions_for_user/2` may preserve the existing built-in fallback for ordinary rendering, but its cache miss uses the group-aware union.

- [ ] **Step 6: Remove L1 and make current authority strict**

Delete every `Process.get/put({:rbac_permissions, ...})` branch. Keep `clear_process_cache/0` temporarily as a documented compatibility no-op. Update cache documentation to describe ETS as the only resolver cache. Replace the current-user dependency with `load_authority`, whose default calls `RBAC.effective_authority/2` directly and never reads or populates ETS; return both `permissions` and `profile_versions` with the reloaded user. Keep `effective_permissions/2` as the convenience API for callers that do not persist an authority snapshot.

- [ ] **Step 7: Thread one authority snapshot through all security paths**

Replace singular-profile permission reads in the AWX, callback-grant, secure-execution, and child-launch adapters. Update both source behaviours plus issue/recheck consumers so they exchange `%{permissions: MapSet.t(), profile_versions: [%{id: String.t(), updated_at: DateTime.t()}]}` rather than a singular profile. Update persisted issuance fields/contracts to carry the deterministic profile-version list and keep backward decoding only where existing unexpired records require it. Where authority is digested, use a stable structure:

```elixir
profile_versions = Enum.map(authority.profile_versions, &{&1.id, DateTime.to_iso8601(&1.updated_at)})

snapshot = %{profile_versions: profile_versions, permissions: Enum.sort(authority.permissions)}
authority_digest = :crypto.hash(:sha256, :erlang.term_to_binary(snapshot))
```

Preserve the existing callback/secure-execution digest encoding and output types. Add literal tests showing that changing either contributing profile invalidates recheck, while reordered input profile rows produce the same digest.

- [ ] **Step 8: Register and run database RED/GREEN coverage through the guarded lane**

Classify `effective_permissions_db_test.exs` in `INTEGRATION_SOURCE_DISPOSITIONS.tsv` and `integration_test_dispositions.bzl` with exact module/test counts. Use the `srql-fixtures-db-tests` guarded BuildBuddy lifecycle, `--nocache_test_results`, and teardown after a red run. Apply the migration with `mix serviceradar.db.migrate` inside that lifecycle.

- [ ] **Step 9: Run focused GREEN verification and commit**

Run the command from Step 3 plus the integration selection-equivalence gates. Expect all selected tests to pass with no warnings:

```bash
bazel test -c opt --config=remote //build:integration_selection_equivalence_test //:ci_heavy_gate_contract_test --test_output=errors
```

Commit:

```bash
git add elixir/serviceradar_core build/integration_test_dispositions.bzl
git commit -m "feat(rbac): resolve group-derived authority"
```

### Task 2: Transactional Group and Membership Boundaries

**Files:**

- Create: `elixir/serviceradar_core/lib/serviceradar/identity/privilege_mutation_effects.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/identity/changes/require_privilege_boundary.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/identity/group_policy.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/identity/privileged_membership.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/identity/privilege_mutation_boundaries_db_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/user_group.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/user_group_membership.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/idp_group_memberships.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/dashboards/authored/sharing.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/identity/idp_group_permission_mapping_db_test.exs`
- Modify: `elixir/web-ng/test/phoenix/auth/sso_provisioning_test.exs`
- Modify: integration disposition manifests and relevant Bazel target source lists

**Interfaces:**

- Consumes: strict current authority and `UserGroup.role_profile_id` from Task 1.
- Produces: `GroupPolicy.assign(scope, group_id, profile_id, opts \\ [])`.
- Produces: `GroupPolicy.clear(scope, group_id, opts \\ [])`.
- Produces: `GroupPolicy.delete(scope, group_id, opts \\ [])`.
- Produces: `PrivilegedMembership.add(scope, group_id, user_id, attrs \\ %{}, opts \\ [])`.
- Produces: `PrivilegedMembership.remove(scope, membership_id, opts \\ [])`.
- Produces: `PrivilegedMembership.reconcile_idp(user_id, group_ids, opts \\ [])` preserving `%{added: [], withdrawn: [], kept: []}`.
- Produces: boundary changesets carrying private context `%{privilege_boundary_owned: true}`; guarded raw actions reject calls without it.

- [ ] **Step 1: Write unboxed failing boundary tests**

Use `async: false`, `@moduletag sandbox: :unboxed`, wholly synthetic UUIDs/emails, independent cleanup, and injected audit/cache adapters. Assert exact outer-transaction rejection before any side effect:

```elixir
assert Repo.transaction(fn -> GroupPolicy.assign(scope, group.id, profile.id) end) ==
         {:ok, {:error, :outer_transaction_not_supported}}
refute_receive {:audit, _}
refute_receive {:invalidate, _}
assert {:ok, unchanged} = Ash.get(UserGroup, group.id, actor: actor)
assert is_nil(unchanged.role_profile_id)
```

Also write failures for rollback/no effects, deduplicated member invalidation, group deletion invalidating former members, audit failure preserving the committed write, manual membership preservation, and one failed IdP mapping not blocking another.

- [ ] **Step 2: Run focused tests and capture RED evidence**

Run the relevant guarded serial DB target with `--nocache_test_results`. Expected: missing `GroupPolicy`, `PrivilegedMembership`, and dedicated actions. Run the selection-equivalence gates after registering the new test source.

- [ ] **Step 3: Implement the shared transaction/effects helper**

Use one exact result contract:

```elixir
@type tx_result(result) :: {:ok, result, [String.t()], keyword()} | {:error, term()}

def run(scope_or_actor, permissions, tx_fun, opts \\ []) do
  if Repo.in_transaction?() do
    {:error, :outer_transaction_not_supported}
  else
    with {:ok, authority} <- CurrentUserAuthority.authorize(scope_or_actor, permissions),
         {:ok, {result, user_ids, audit_opts}} <- owned_transaction(authority.user, tx_fun) do
      post_commit(Enum.uniq(user_ids), audit_opts, opts)
      {:ok, result}
    end
  end
end
```

The internal trusted-system variant accepts an explicit system actor but still rejects outer transactions and owns each row transaction. Catch audit returns, raises, and exits; log failures without changing `{:ok, result}`.

Every boundary write sets its resource changeset context before invoking Ash:

```elixir
Ash.Changeset.set_context(changeset, %{privilege_boundary_owned: true})
```

`RequirePrivilegeBoundary` adds a literal validation error when that private context is absent. Do not expose the guarded mutation actions through `code_interface`; separate trusted system actions are added only where the seeder/IdP path needs them.

- [ ] **Step 4: Add dedicated group assignment/delete actions**

Add boundary-guarded assignment actions that accept only `role_profile_id` and two separate Ash policies so both permissions are required. Add guarded coordinated clearing/deletion actions needed by the boundary. Generic update must not accept `role_profile_id`, generic group destroy must require boundary context, and none of these actions is exposed as a public code-interface function.

- [ ] **Step 5: Implement `GroupPolicy`**

For assign/clear, lock/load the group, validate the profile, collect current member IDs, call the dedicated authorized action, then return post-commit effects. For delete, collect member IDs before destroying so cascading memberships cannot erase the invalidation set. Use the real reconstructed actor and require `settings.rbac.manage` plus `identity.user_groups.manage`.

- [ ] **Step 6: Implement conflict-safe privileged membership actions**

Manual add/remove require fresh `identity.user_groups.manage`. IdP add must not convert a concurrent/manual row. Implement an IdP-specific conditional upsert or conflict action whose update branch applies only when persisted `source == :idp`; do not rely on a pre-read race window. IdP withdrawal filters persisted `source == :idp` in the delete predicate.

```elixir
create :create_idp do
  accept [:group_id, :user_id, :metadata]
  change set_attribute(:source, :idp)
  upsert? true
  upsert_identity :unique_group_user
  upsert_condition expr(source == :idp)
  upsert_fields [:metadata, :updated_at]
  return_skipped_upsert? true
end
```

- [ ] **Step 7: Preserve best-effort IdP reconciliation**

Make `IdpGroupMemberships.sync/3` delegate to `PrivilegedMembership.reconcile_idp/3`. Each add/remove owns a separate transaction. Log and skip one failed mapping, retain successful independent results, and leave sign-in available. Return manually held desired groups in `kept` without changing their source.

- [ ] **Step 8: Route first-party manual membership callers**

Replace raw membership creation/removal in `Dashboards.Authored.Sharing`; keep its facade signatures stable. Route group deletion through `GroupPolicy.delete/3`. Update synthetic fixture setup to use the public boundary or a narrowly scoped trusted test helper; unsupported direct resource mutation must fail before persistence.

- [ ] **Step 9: Run GREEN verification and commit**

Run the guarded DB cases, then:

```bash
bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_identity //elixir/web-ng:unit_tests_phoenix_live --test_output=errors
bazel test -c opt --config=remote //build:integration_selection_equivalence_test //:ci_heavy_gate_contract_test --test_output=errors
```

Commit:

```bash
git add elixir/serviceradar_core elixir/web-ng build/integration_test_dispositions.bzl
git commit -m "feat(identity): coordinate privilege-bearing group changes"
```

### Task 3: Transactional Role Profile Lifecycle

**Files:**

- Create: `elixir/serviceradar_core/lib/serviceradar/identity/role_profile_policy.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/role_profile.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/user.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/user_group.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/changes/invalidate_rbac_cache.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/changes/invalidate_user_rbac_cache.ex`
- Delete: `elixir/serviceradar_core/lib/serviceradar/identity/changes/clear_role_profile_assignments.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/identity/role_profile_seeder.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/admin_api/local.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/role_profile_controller.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live.ex`
- Modify: `elixir/web-ng/test/app_domain/rbac_test.exs`
- Modify: `elixir/web-ng/test/phoenix/controllers/api/admin_authorization_test.exs`
- Modify: `elixir/web-ng/test/phoenix/live/settings/rbac_live_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/identity/privilege_mutation_boundaries_db_test.exs`

**Interfaces:**

- Consumes: `PrivilegeMutationEffects` from Task 2.
- Produces: `RoleProfilePolicy.create(scope, attrs, opts \\ [])`.
- Produces: `RoleProfilePolicy.update(scope, profile_id, attrs, opts \\ [])`.
- Produces: `RoleProfilePolicy.delete(scope, profile_id, opts \\ [])`.
- Preserves: trusted `RoleProfile.create_system_profile/2` and adds a distinct trusted update-system action for system-profile seeding.

- [ ] **Step 1: Add failing lifecycle and routing tests**

Assert create/update/delete use fresh authority, unsupported raw custom-profile actions fail, outer transactions are rejected, update invalidates direct and group users after commit, and delete clears both reference kinds atomically. Add a rollback test that injects failure after references are cleared and proves the profile plus both assignments remain. Add a seeder regression proving a changed built-in profile uses the trusted update-system action successfully.

Add controller/LiveView tests that revoke `settings.rbac.manage` after page/request setup and assert the mutation fails instead of using cached scope permissions.

- [ ] **Step 2: Run focused tests and capture RED evidence**

```bash
bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_identity //elixir/web-ng:unit_tests_phoenix_controllers //elixir/web-ng:unit_tests_phoenix_live --test_output=errors
```

Expected: missing `RoleProfilePolicy`, raw mutation call sites still succeed with stale scope, and group references are not coordinated.

- [ ] **Step 3: Make resource hooks transaction-safe**

Move standalone invalidation changes from `after_action` to `Ash.Changeset.after_transaction`. Allow a private changeset context flag such as `:privilege_boundary_owned` to suppress resource-level effects when nested inside the owned `Repo.transaction`; the boundary performs effects only after the outer transaction returns.

Remove `ClearRoleProfileAssignments` from destroy. Add dedicated boundary-guarded bulk-clear actions on `User` and `UserGroup` for coordinated deletion; do not use `authorize?: false` or a user-facing `SystemActor`. Guard custom profile create/update/destroy with `RequirePrivilegeBoundary` and remove their public code-interface definitions. Keep distinct trusted `:create_system` and `:update_system` actions for `RoleProfileSeeder` and test both.

- [ ] **Step 4: Implement `RoleProfilePolicy`**

Create/update/delete require fresh `settings.rbac.manage`. Update collects direct assignees plus members of referencing groups before writing. Delete locks the custom profile, rejects system profiles, gathers affected IDs, clears user and group references, and destroys the profile in one owned transaction:

```elixir
with {:ok, profile} <- lock_custom_profile(profile_id, actor),
     {:ok, affected_ids} <- affected_user_ids(profile.id, actor),
     :ok <- clear_direct_assignments(profile.id, actor),
     :ok <- clear_group_assignments(profile.id, actor),
     :ok <- destroy_profile(profile, actor) do
  {:ok, profile, affected_ids, audit_options(:delete, profile, actor)}
else
  {:error, reason} -> Repo.rollback(reason)
end
```

- [ ] **Step 5: Route every first-party custom-profile mutation**

Make `AdminApi.Local` call the boundary. Make the HTTP controller call the AdminApi/boundary once, not perform a second raw Ash write. Replace the Policy Editor's `create_role_profile`, `update_role_profile`, `persist_profile`, and `delete_role_profile` helpers with `RoleProfilePolicy` calls. Route `RoleProfileSeeder` to the explicit trusted create/update-system actions.

- [ ] **Step 6: Run guarded and focused GREEN verification**

Run the unboxed lifecycle suite through BuildBuddy and the Step 2 targets. Inspect output for excluded/zero-test false greens and warnings.

- [ ] **Step 7: Commit**

```bash
git add elixir/serviceradar_core elixir/web-ng
git commit -m "feat(rbac): coordinate role profile lifecycle"
```

### Task 4: Monotonic Dashboard Group Access

**Files:**

- Create: `elixir/serviceradar_core/lib/serviceradar/dashboards/preparations/policy_editor_audience.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/dashboards/changes/require_group_access_boundary.ex`
- Create: `elixir/web-ng/lib/serviceradar_web_ng/dashboards/group_access.ex`
- Create: `elixir/web-ng/test/app_domain/dashboards/group_access_db_test.exs`
- Modify: `elixir/serviceradar_core/lib/serviceradar/dashboards/authored_dashboard.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/dashboards/dashboard_instance.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/dashboards/dashboard_access_grant.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/dashboards/dashboard_instance_access_grant.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/dashboards.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/dashboards/authored/sharing.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng/dashboards/packages.ex`
- Modify: authored/package dashboard LiveView event handlers for group `:view`
- Modify: `elixir/web-ng/BUILD.bazel`

**Interfaces:**

- Produces: `GroupAccess.page(scope, {:policy_editor, source}, group_id, selector)` where `source` is `:authored | :package` and `selector` carries a raw server-only keyset.
- Produces: `GroupAccess.ensure_group_view(scope, {entrypoint, source}, target_id, group_id, opts \\ [])`.
- Produces: `GroupAccess.revoke_group_view(scope, {entrypoint, source}, target_id, group_id, opts \\ [])`.
- Produces: `GroupAccess.set_group_access(scope, {entrypoint, source}, target_id, group_id, :view | :edit, opts \\ [])` for every first-party group grant create/update.
- `entrypoint` is `:policy_editor | :local`; both converge on the same monotonic resource actions.
- The Policy Editor path accepts `expected_fingerprint:` in opts and compares it while the target row is locked.

- [ ] **Step 1: Write failing DB behavior and concurrency tests**

Use synthetic rows and independent checked-out connections for concurrency. Cover stable case-insensitive title/name plus ID keysets, public no-op, ensure-view preserving edit, conditional revoke preserving a concurrent edit, a dashboard-local `:edit` making a delayed central fingerprint stale with no success audit, private-package atomic visibility, visibility rollback on grant failure, shared visibility retained on revoke, exact authorization conjunctions, outer-transaction rejection, and post-commit audit behavior.

The critical final-state assertions are literal:

```elixir
assert persisted_grant.access == :edit
assert persisted_instance.visibility == :shared
assert count_group_grants(target.id, group.id) == 1
```

- [ ] **Step 2: Register the DB tests and capture RED evidence**

Add the file to `//elixir/web-ng:networks_live_db_test`, tag only selected cases `:web_ng_shared_fixture_db`, and increment `expected_selected_tests` by the exact number added. Run through the guarded shared-fixture lifecycle with `--nocache_test_results`; expected failures name the missing strict actions/service.

- [ ] **Step 3: Add strict target listing/reread actions**

Add required keyset actions with `default_limit` and `max_page_size` 50, stable normalized-title/ID ordering, and only the selected group's grant loaded. Add by-ID mutation rereads and package `set_shared_for_policy_editor`. Policy Editor actions encode the exact AND rules from Global Constraints. Do not call `Packages.list_instance_access_grants/2`, because it converts query failure to `[]`.

- [ ] **Step 4: Add atomic monotonic grant actions**

For group view ensure, force group subject and `:view`, use the partial unique identity, and prevent edit downgrade:

```elixir
upsert? true
upsert_identity :unique_group_grant
upsert_condition expr(access != :edit)
upsert_fields [:access, :granted_by_id, :updated_at]
return_skipped_upsert? true
```

Use the equivalent package identity/action. Revoke through a named conditional destroy whose SQL predicate includes `access == :view`; never read a view row and later destroy only by ID. Require `%{dashboard_group_access_boundary_owned: true}` on every group-subject create/update/destroy action and omit public code-interface functions for those actions. User-subject actions remain unchanged.

- [ ] **Step 5: Implement the transaction-owning service**

Reject an outer transaction before authority lookup. Fresh-authorize the entrypoint, then acquire one transaction-scoped PostgreSQL advisory lock from a parameterized stable key such as `dashboard-group-access:<source>:<target_id>:<group_id>`. Under that lock, lock/reread the target and group grant, compare any server-supplied fingerprint, treat public as a no-write result, transition private package to shared, and roll back visibility when grant creation fails. Every group mutation sets `%{dashboard_group_access_boundary_owned: true}`. After commit, synchronously submit one `AuditWriter.write/1` request; log any error/raise/exit without changing the committed result.

Use a bound SQL parameter rather than interpolated SQL:

```elixir
Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])
```

- [ ] **Step 6: Route local group-view operations**

Local owner/editor actions retain existing local authorization but call the same serialized coordinator for group `:view`, group `:edit`, and group revoke. Route every first-party authored/package group-grant caller through `GroupAccess`; leave only user-subject grants on their current paths. Confirm a package owner without the global share permission can still use the local sharing surface, and add a repository search assertion/test inventory so no production group-grant write bypass remains.

- [ ] **Step 7: Run GREEN verification and commit**

Run the guarded DB suite, then:

```bash
bazel test -c opt --config=remote //elixir/web-ng:unit_tests_app_domain //elixir/web-ng:unit_tests_phoenix_live --test_output=errors
```

Commit:

```bash
git add elixir/serviceradar_core elixir/web-ng
git commit -m "feat(dashboards): add monotonic group access operations"
```

### Task 5: Asynchronous Group Profile Controls

**Files:**

- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live/policy_data.ex`
- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live/components.ex`
- Create: `elixir/web-ng/test/serviceradar_web_ng_web/settings/rbac_live/policy_data_test.exs`
- Create: `elixir/web-ng/test/serviceradar_web_ng_web/settings/rbac_live/components_test.exs`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live.ex`
- Modify: `elixir/web-ng/test/phoenix/live/settings/rbac_live_test.exs`
- Modify: `elixir/web-ng/BUILD.bazel`

**Interfaces:**

- Consumes: `GroupPolicy.assign/4` and `GroupPolicy.clear/3` from Task 2.
- Produces: `PolicyData.load_group_profiles(scope) :: {:ok, %{groups: list(), profiles: list(), group_tokens: map(), profile_tokens: map()}} | {:error, term()}`.
- Produces: stateless function components for loading, empty, success, and retryable error views.

- [ ] **Step 1: Write failing pure and LiveView tests**

Mark pure `PolicyData`/component tests `@moduletag :db_free`. In `rbac_live_test.exs`, tag only the new database cases `:web_ng_shared_fixture_db` and assert disconnected mount renders a loading marker and does not invoke the loader seam; connected mount loads; empty differs from failure; failure text is exactly generic and omits an injected internal marker; assign/clear delegates to `GroupPolicy`; and revoked authority fails after the page was opened. Test retry generation/late-result acceptance in a pure function rather than trying to schedule nondeterministic LiveView tasks.

- [ ] **Step 2: Run focused tests and capture RED evidence**

```bash
bazel test -c opt --config=remote //elixir/web-ng:unit_tests_serviceradar_web_ng_web --test_output=errors
```

Expected: the DB-free tests fail because `PolicyData`, components, and generation helpers are missing. Add `rbac_live_test.exs` to `//elixir/web-ng:networks_live_db_test`, increment `expected_selected_tests` by exactly the new tagged cases, and run that target through the guarded BuildBuddy shared-fixture lifecycle for the connected/mutation RED evidence. The DB-free unit target is not evidence for those LiveView cases.

- [ ] **Step 3: Implement connected-only async data loading**

Initialize `:group_profile_assignments` as `AsyncResult.loading()` on disconnected mount. Only under `connected?(socket)` call `assign_async` with that stable key. Before retry, cancel the same key and increment a server generation so late results are ignored.

```elixir
defp load_group_profiles(socket) do
  scope = socket.assigns.current_scope
  generation = socket.assigns.group_profile_generation + 1

  socket
  |> cancel_async(:group_profile_assignments)
  |> assign(:group_profile_generation, generation)
  |> assign_async(:group_profile_assignments, fn ->
    case PolicyData.load_group_profiles(scope) do
      {:ok, data} -> {:ok, %{group_profile_assignments: Map.put(data, :generation, generation)}}
      {:error, reason} -> {:error, reason}
    end
  end)
end
```

Log internal reasons only on the server. Render "Unable to load user groups. Try again." for failure and never render it as the empty state.

- [ ] **Step 4: Add token-bound assign/clear events**

Resolve opaque group/profile tokens from `PolicyData`'s server maps. Ignore extra browser fields. Unknown/stale tokens reload and show a generic stale notice. Call `GroupPolicy` under the current scope, refresh async data on success or authorization/stale failure, and add event names to `event_mapping/0`.

- [ ] **Step 5: Render focused components without growing the grid module**

Put group/profile controls and state-specific markup in `RbacLive.Components`. Keep the existing role-profile matrix behavior in `RbacLive`; do not restructure unrelated grid logic.

- [ ] **Step 6: Run GREEN verification and commit**

Run the DB-free Step 2 target plus the guarded tagged LiveView cases and confirm the selected test counts rather than trusting a zero-test green. Commit:

```bash
git add elixir/web-ng
git commit -m "feat(web-ng): manage group role profiles in policy editor"
```

### Task 6: Bounded Dashboard Audience LiveView

**Files:**

- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live/dashboard_audience.ex`
- Create: `elixir/web-ng/test/serviceradar_web_ng_web/settings/rbac_live/dashboard_audience_test.exs`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live/components.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live.ex`
- Modify: `elixir/web-ng/test/phoenix/live/settings/rbac_live_test.exs`
- Modify: `elixir/web-ng/BUILD.bazel`

**Interfaces:**

- Consumes: Task 4 `GroupAccess.page/4`, `ensure_group_view/5`, and `revoke_group_view/5`.
- Produces: pure `DashboardAudience` state transitions for group selection, request start, result acceptance, page replacement, and row-token resolution.
- State contains selected group token/ID, monotonically increasing epoch, and independent `:authored`/`:package` states with only the current page's before/after raw keysets, request ref, page metadata, error, and expected map. It never accumulates navigation history.

- [ ] **Step 1: Write failing state-machine tests**

Mark pure tests `@moduletag :db_free`. Use literal states to prove:

- selecting a group increments the epoch and clears both windows;
- paging authored leaves package state byte-for-byte equal;
- a failed next page preserves the previous stream/window and records only that source's error;
- a late request ref or old epoch is ignored;
- successful page replacement contains at most 50 expected entries;
- paged-out, forged, cross-group, and old-epoch tokens return `{:error, :stale}`.
- repeated forward/backward paging retains exactly two raw keysets per source and no history list.

```elixir
assert {:error, :stale} = DashboardAudience.resolve_row(state_for_group_b, token_from_group_a)
assert next.package == previous.package
assert map_size(next.authored.expected) <= 50
```

- [ ] **Step 2: Run the DB-free tests and capture RED evidence**

```bash
bazel test -c opt --config=remote //elixir/web-ng:unit_tests_serviceradar_web_ng_web --test_output=errors
```

Expected: `DashboardAudience` and its transition functions are undefined.

- [ ] **Step 3: Implement the pure bounded state machine**

Each loaded row receives a fresh random opaque token. Store only server-side:

```elixir
%{
  source: source,
  group_id: group_id,
  epoch: epoch,
  target_id: row.id,
  fingerprint: {
    row.visibility,
    row.updated_at,
    row.grant && row.grant.id,
    row.grant && row.grant.access,
    row.grant && row.grant.updated_at
  }
}
```

Never serialize raw keysets, target IDs, fingerprints, or grant IDs into DOM event values.

- [ ] **Step 4: Wire independent streams and async requests**

Initialize `:rbac_authored_dashboards` and `:rbac_package_dashboards` streams. Use `start_async({:dashboard_audience, source, request_ref}, ...)` per source. Accept a result only when request ref and group epoch still match. On success, call `stream(..., reset: true)` for only that source and replace only its expected map. On failure, preserve prior rows/window and set only that source's generic retry state.

- [ ] **Step 5: Wire intent-only mutation events**

Use source-specific event names so an entirely unknown token reloads only the named source. Read only `group-token`, `row-token`, and the event's fixed operation; ignore all other params. Resolve the row/group/epoch server-side and pass its fingerprint to `GroupAccess` for comparison under lock. On stale/unknown/unauthorized, make no write, reload that source, and show a visible generic notice.

- [ ] **Step 6: Render source-accurate availability**

Render public authored rows as "Public to users with analytics access" and package rows as "Public to authenticated users"; disable the grant control. Render `:edit` as stronger access whose view toggle cannot revoke it. Show a generic note that source `view_all` permissions may independently grant access; do not claim to enumerate selected-group members' full effective authority.

- [ ] **Step 7: Add connected LiveView coverage**

Use the pure state module for deterministic late-result testing. In the DB-backed LiveView cases, cover connected load, independent next-page controls/errors, bounded rendered rows, public/edit labels, forged/cross-group tokens, stale fingerprint, and authority revoked after open. Add only tagged cases to `networks_live_db_test` and update its exact selected count.

- [ ] **Step 8: Run GREEN verification and commit**

Run the guarded tagged LiveView DB cases and:

```bash
bazel test -c opt --config=remote //elixir/web-ng:unit_tests_serviceradar_web_ng_web //elixir/web-ng:unit_tests_phoenix_live --test_output=errors
```

Commit:

```bash
git add elixir/web-ng
git commit -m "feat(web-ng): edit dashboard group audiences"
```

### Task 7: Complete Guarded Verification and OpenSpec Tracking

**Files:**

- Modify: `openspec/changes/improve-rbac-policy-editor/tasks.md`
- Modify: `CHANGELOG.md` only if the implemented operator-visible behavior belongs under the current unreleased section
- Modify: operator documentation only if an existing Policy Editor page documents the changed controls

**Interfaces:**

- Consumes: all prior task commits.
- Produces: fully checked OpenSpec task list backed by fresh command output and no uncommitted generated files.

- [ ] **Step 1: Inspect the complete branch before verification**

Run `git status --short`, inspect the full branch diff against `origin/staging`, and verify no `.bazelrc.remote`, credentials, generated cache output, or captured/live values are tracked. Confirm every new fixture was invented and uses reserved documentation ranges/domains where applicable.

- [ ] **Step 2: Run migration and all DB cases through the guarded lifecycle**

Read and follow `.agents/skills/srql-fixtures-db-tests/SKILL.md`. Apply with `mix serviceradar.db.migrate`, run every newly registered serial/shared-fixture case with `--nocache_test_results`, inspect the actual test counts/output, and run teardown even after a red attempt.

- [ ] **Step 3: Run the canonical full remote unit suite**

```bash
make test
```

Expected: every selected target passes; read the BuildBuddy summary and test count rather than relying only on exit status.

- [ ] **Step 4: Run Elixir quality contracts**

```bash
./scripts/elixir_quality.sh --project elixir/serviceradar_core
./scripts/elixir_quality.sh --project elixir/web-ng --phoenix
```

Run `mix format` only through the repository's existing command/target as needed. Do not add or extend a script. Inspect warnings and formatter output.

- [ ] **Step 5: Strictly validate every coordinated OpenSpec change**

```bash
openspec validate improve-rbac-policy-editor --strict
openspec validate add-dashboard-creator --strict
openspec validate add-dashboard-package-access-control --strict
```

- [ ] **Step 6: Mark only evidenced tasks complete**

Change each implemented checkbox in `openspec/changes/improve-rbac-policy-editor/tasks.md` from `[ ]` to `[x]`. Leave no task checked if its test or behavior was skipped. Add concise CHANGELOG/docs text only if an existing convention calls for it.

- [ ] **Step 7: Run a final branch review and fix loop**

Request a whole-branch review against this plan and the OpenSpec design. Fix every Critical/Important finding, re-run the focused covering tests, and repeat the scoped review until no blocking finding remains.

- [ ] **Step 8: Re-run completion evidence and commit**

Re-run `git diff --check`, the affected focused tests, strict OpenSpec validation, and `git status --short`. Commit only the task tracking/docs changes:

```bash
git add openspec/changes/improve-rbac-policy-editor CHANGELOG.md docs
git commit -m "docs(openspec): complete RBAC policy editor change"
```

Do not push. Before any later worktree removal, report separately whether the branch is merged by content, has zero unique commits versus its base, and has a remote copy.
