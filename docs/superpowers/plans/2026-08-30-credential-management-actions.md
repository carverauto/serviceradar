# Credential Management Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let credential managers navigate every reusable credential consumer, edit safe details, rotate write-only material, and permanently delete a credential only when PostgreSQL proves it is unused.

**Architecture:** Direct UUID consumers use restrictive foreign keys. Text/JSON consumers are mirrored transactionally into an Ash-backed binding table whose restrictive secret foreign key closes delete races. A core usage registry supplies redacted typed consumer summaries to one guarded Ash destroy action and to the LiveView; credential-owned versions cascade on delete while a separate append-only record retains only redacted deletion evidence.

**Tech Stack:** Elixir, Ash/AshPostgres/AshCloak/AshPaperTrail, PostgreSQL/CNPG, Phoenix LiveView, ExUnit, Bazel, Playwright, Helm/Kubernetes.

**Spec:** `openspec/changes/refactor-unified-credential-management/{proposal.md,design.md,specs/credential-management/spec.md}`

## Global Constraints

- Permanent deletion is allowed only when there is no configured live consumer and no unexpired `issued` or `active` broker grant.
- Every live credential reference must be protected by PostgreSQL through a direct `ON DELETE RESTRICT` foreign key or an FK-backed binding row maintained in the same transaction as its text/JSON owner.
- Historical resolution audits, OCSF events, immutable execution snapshots, and expired or terminal grants do not alone block deletion and never retain usable secret material.
- `network_credential_secret_versions` and terminal grant versions cascade with their owned records because version changes can contain ciphertext.
- `NetworkCredentialSecret` PaperTrail does not persist action input maps.
- Existing secret material is never rendered, prefilled, logged, returned in errors, or placed in template-facing LiveView assigns.
- Every edit, rotation, usage, and deletion event performs a fresh `settings.credentials.manage` authorization check.
- All database entities are Ash resources; schema generation begins with `mix ash.codegen`. Custom trigger SQL lives only in the generated migration, never in application code.
- Work stays on `codex/fix-credential-inventory-links`; pushes use an explicit refspec and target GitHub PR #4180. No release tag or release version is cut.

---

### Task 1: Database-enforced credential reference inventory

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_secret_binding.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_secret_deletion_audit.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/credentials.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_secret.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/credentials/credential_broker_grant.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/snmp_profile.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/snmp_target.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/inventory/device_snmp_credential.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_controller_resource.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations/integration_source.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/integrations/outbound_mail_settings.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/plugins/plugin_repository.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/controller.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/automation/ansible/playbook_repository.ex`
- Create via `mix ash.codegen`, then extend: `elixir/serviceradar_core/priv/repo/migrations/20260830220000_guard_network_credential_secret_deletion.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/credentials/credential_secret_reference_constraints_db_test.exs`
- Modify: `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`

**Interfaces:**
- Produces: `ServiceRadar.Credentials.NetworkCredentialSecretBinding` with public read action and fields `secret_id`, `owner_kind`, `owner_id`, `field_path`.
- Produces: `ServiceRadar.Credentials.NetworkCredentialSecretDeletionAudit` with create-only `:record` and read-only public surface.
- Produces: trigger-maintained bindings for `vulnerability_feed_definitions.credential_ref`, `notification_channels.secret_refs`, `producer_schedules.{credential_refs,params}`, `plugin_assignments.params`, and `plugin_target_policies.params_template`.
- Produces: restrictive typed references for SNMP profiles/targets/device credentials, mapper controllers, integration sources, outbound mail slots, plugin repositories, and all five Ansible columns.

- [ ] **Step 1: Write failing database contract tests**

Add one literal consumer fixture per storage shape and name the break each test catches:

```elixir
test "a JSON credential reference creates a restrictive binding", %{secret: secret} do
  assignment = plugin_assignment_fixture(%{
    params: %{"credential" => SecretRefs.network_credential_ref(secret.id)}
  })

  assert [%{secret_id: id, owner_kind: :plugin_assignment, owner_id: owner_id}] =
           NetworkCredentialSecretBinding
           |> Ash.Query.filter(secret_id == ^secret.id)
           |> Ash.read!(actor: system_actor())

  assert id == secret.id
  assert owner_id == to_string(assignment.id)
  assert {:error, _} = delete_secret_row(secret.id)
end

test "removing the owner removes its binding", %{secret: secret} do
  assignment = plugin_assignment_fixture(%{
    params: %{"credential" => SecretRefs.network_credential_ref(secret.id)}
  })

  :ok = Ash.destroy!(assignment, actor: system_actor())

  assert [] == bindings_for(secret.id)
end

test "deleting an unbound secret cascades ciphertext-bearing versions" do
  secret = secret_fixture(secret_payload: "marker-delete-version")
  assert version_count(secret.id) > 0

  assert :ok = delete_secret_row(secret.id)
  assert version_count(secret.id) == 0
end

defp delete_secret_row(secret_id) do
  case Ecto.Adapters.SQL.query(ServiceRadar.Repo,
         "DELETE FROM platform.network_credential_secrets WHERE id = $1",
         [Ecto.UUID.dump!(secret_id)]
       ) do
    {:ok, %{num_rows: 1}} -> :ok
    {:error, error} -> {:error, error}
  end
end

defp bindings_for(secret_id) do
  NetworkCredentialSecretBinding
  |> Ash.Query.filter(secret_id == ^secret_id)
  |> Ash.read!(actor: system_actor())
end

defp version_count(secret_id) do
  %{rows: [[count]]} =
    Ecto.Adapters.SQL.query!(ServiceRadar.Repo,
      "SELECT count(*) FROM platform.network_credential_secret_versions WHERE version_source_id = $1",
      [Ecto.UUID.dump!(secret_id)]
    )

  count
end
```

Define `plugin_assignment_fixture/1` locally by creating its approved package, agent, and assignment through the same public Ash actions the production materializer uses; do not insert a partial assignment row. Cover zero/one/nested/array refs, stale-binding removal on update, bare vulnerability-feed UUIDs, malformed network refs, broker `secret_ref`/`secret_id` mismatch, every typed FK, and binding backfill idempotence. The concurrency test uses two sandbox-authorized tasks and asserts that a binding insert racing a parent delete cannot leave a committed dangling consumer.

- [ ] **Step 2: Run the focused database target and confirm RED**

Create a disposable scratch database with `.agents/skills/srql-fixtures-db-tests/SKILL.md`, run current migrations into it with `MIX_ENV=test mix ash.migrate` (never `mix ecto.migrate`), then run:

```bash
MIX_ENV=test mix test test/serviceradar/credentials/credential_secret_reference_constraints_db_test.exs
```

Expected: FAIL because `NetworkCredentialSecretBinding` and the binding table/triggers do not exist; the failure must not be a fixture or connection error.

- [ ] **Step 3: Define the two Ash resources and relationship semantics**

The binding resource is read-only to callers and written by PostgreSQL triggers:

```elixir
defmodule ServiceRadar.Credentials.NetworkCredentialSecretBinding do
  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "network_credential_secret_bindings"
    repo ServiceRadar.Repo
    schema "platform"
    references do
      reference :secret, on_delete: :restrict
    end
  end

  actions do
    read :read do
      primary? true
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :secret_id, :uuid, allow_nil?: false, public?: true
    attribute :owner_kind, :atom, allow_nil?: false, public?: true
    attribute :owner_id, :string, allow_nil?: false, public?: true
    attribute :field_path, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end
```

The deletion audit stores only `secret_id`, `name`, `provider`, `credential_kind`, `source_type`, `deleted_by_actor_id`, and `deleted_at`. It has no update or destroy action. Register both resources in `ServiceRadar.Credentials`.

Set explicit `postgres.references` entries to `:restrict` on every live typed relationship. Keep `CredentialSecretResolutionAudit.secret_id` nilifying because it is historical. Set secret and grant version ownership to cascade. Set `NetworkCredentialSecret` PaperTrail `store_action_inputs? false`.

- [ ] **Step 4: Generate the Ash migration, then add trigger-only SQL**

Run from `elixir/serviceradar_core`:

```bash
mix ash.codegen guard_network_credential_secret_deletion
```

Keep the generated table/index/FK operations. In that generated migration, add one recursive JSONB extractor that accepts only exact `credentialref:network-credential-secret:<uuid>` strings, one owner-sync function that deletes and reinserts a row's complete binding set, and table-specific triggers. A binding FK is `ON DELETE RESTRICT`, never cascade. Backfill each owner table before enabling deletion and raise on an unresolved value explicitly identified as a network credential reference.

Add a broker constraint/trigger with this behavior:

```sql
IF NEW.secret_ref LIKE 'credentialref:network-credential-secret:%' THEN
  IF NEW.secret_id IS NULL OR
     NEW.secret_ref <> 'credentialref:network-credential-secret:' || NEW.secret_id::text THEN
    RAISE EXCEPTION 'network credential secret_ref must match secret_id';
  END IF;
END IF;
```

Rename the generated migration to the plan's exact `20260830220000_guard_network_credential_secret_deletion.exs` path before amending it. The down migration removes triggers/functions first, then binding/audit tables, then restores prior FK actions.

- [ ] **Step 5: Run migration and database tests to GREEN**

Run:

```bash
mix ash.migrate
MIX_ENV=test mix test test/serviceradar/credentials/credential_secret_reference_constraints_db_test.exs
```

Expected: PASS against the disposable scratch database, including an explicit assertion that one concurrent operation loses and no dangling reference commits. Drop the scratch database afterward. Do not run the guarded Bazel integration lanes from a workstation; GitHub/BuildBuddy owns them.

- [ ] **Step 6: Commit the database invariant slice**

```bash
git add elixir/serviceradar_core openspec/changes/refactor-unified-credential-management
git commit -m "feat(credentials): enforce guarded secret deletion"
```

---

### Task 2: Core usage, edit, rotation, and destroy lifecycle

**Files:**
- Create: `elixir/serviceradar_core/lib/serviceradar/credentials/credential_usage.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/credentials/credential_rotation.ex`
- Create: `elixir/serviceradar_core/lib/serviceradar/credentials/changes/guard_credential_destroy.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/credentials/network_credential_secret.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/credentials/credential_secret_builder.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/credentials/credential_broker_grant.ex`
- Create: `elixir/serviceradar_core/test/serviceradar/credentials/credential_usage_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/credentials/network_credential_secret_destroy_db_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/credentials/credential_lifecycle_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/credentials/credential_secret_builder_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/credentials/network_credential_secret_redaction_test.exs`
- Modify: `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`

**Interfaces:**
- Produces: `CredentialUsage.for_secret/2` and `CredentialUsage.for_secrets/2` returning redacted `%CredentialUsage.Result{status: :available, consumers: [...], live_grants: [...]}`.
- Produces: `%CredentialUsage.Consumer{kind: atom(), id: String.t(), label: String.t(), slot: atom() | nil}`; web-ng owns route construction.
- Produces: `CredentialSecretBuilder.build_rotation/4` that validates provider/kind compatibility and returns only rotation-safe Ash attributes.
- Produces: `CredentialRotation.rotate/4` that validates before state mutation, then executes start/complete/fail actions.
- Produces: `NetworkCredentialSecret.edit_details/2`, `usage/2`, and `destroy_permanently/2`; generic `:update` no longer accepts secret material.

**Implementation rulings:**
- `CredentialUsage.Result.live_grants` contains only redacted `%CredentialUsage.LiveGrant{id, status, consumer_kind, consumer_id, purpose, expires_at}` values, never raw grant resources.
- `CredentialUsage` first authorizes every requested secret through its public read with the caller scope/actor. Only after that gate may its internal source registry use a system actor for cross-domain reads. One source failure returns unavailable; missing rows are never treated as zero usage. Capture one injectable `now` per call, normalize mirrored Ansible legacy/sync columns, deduplicate by `{kind, id, slot}`, and sort deterministically.
- `CredentialSecretBuilder.build_rotation/4` is `(secret, freshly_resolved_profile, submitted_values, opts)`. `CredentialRotation.rotate/4` is `(secret, submitted_values, scope_or_actor, opts)` and resolves the current approved profile from `IntegrationCatalog.profile_for(secret.provider, ...)` under an internal actor; it never accepts a browser/caller-supplied descriptor. The builder verifies internal source type, rotatable state, stored descriptor/auth method, provider, credential kind, and auth method. It preserves `next_rotation_due_at` until a separate scheduling input exists.
- Normalize equal Ansible legacy and sync credential columns into one `:sync` consumer; if they diverge, retain a separate legacy slot so every restrictive FK remains visible.
- The final FK loser is mapped outside a plain `before_action` hook (declared AshPostgres constraint mapping or an around/public wrapper), because the FK can fail after the guard returns. The stable error is `credential_in_use`; the LiveView separately reloads structured usage for named links.

- [ ] **Step 1: Write failing lifecycle and usage tests**

```elixir
test "edit_details cannot replace encrypted payload", %{secret: secret, actor: actor} do
  action = Ash.Resource.Info.action(NetworkCredentialSecret, :edit_details)
  assert action.accept == [:name, :description]

  assert {:error, _} =
           secret
           |> Ash.Changeset.for_update(:edit_details, %{
             name: "renamed",
             secret_payload: "must-not-be-accepted"
           }, actor: actor)
           |> Ash.update(actor: actor)
end

test "usage names the single SNMP profile without loading payload", %{secret: secret, scope: scope} do
  profile = snmp_profile_fixture(scope, credential_secret_id: secret.id, name: "Default SNMP")

  assert {:ok, %CredentialUsage.Result{consumers: [consumer]}} =
           CredentialUsage.for_secret(secret.id, scope: scope)

  assert consumer.kind == :snmp_profile
  assert consumer.id == to_string(profile.id)
  assert consumer.label == "Default SNMP"
  refute Map.has_key?(Map.from_struct(consumer), :secret_payload)
end

test "destroy refuses a configured consumer and succeeds after detachment", context do
  %{secret: secret, scope: scope} = context
  profile = snmp_profile_fixture(scope, credential_secret_id: secret.id)

  assert {:error, %Ash.Error.Invalid{}} =
           NetworkCredentialSecret.destroy_permanently(secret, secret.id, scope: scope)

  clear_profile_secret(profile, scope)
  assert :ok = NetworkCredentialSecret.destroy_permanently(secret, secret.id, scope: scope)
end
```

Add literal cases for rules, every typed/bound consumer kind, lookup failure, an unexpired active grant, an expired `issued` grant, terminal grant/version cleanup, descriptor mismatch, rotation success/failure, forged actor, stale secret ID, and secret marker absence from PaperTrail rows, lifecycle events, errors, and inspected changesets.

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
bazel test --config=remote //elixir/serviceradar_core:unit_tests
MIX_ENV=test mix test test/serviceradar/credentials/network_credential_secret_destroy_db_test.exs
```

Expected: FAIL on missing `CredentialUsage`, `build_rotation/4`, `edit_details`, and `destroy_permanently` behavior.

- [ ] **Step 3: Implement the redacted usage registry**

Batch queries by secret ID and construct values only from public fields:

```elixir
defmodule ServiceRadar.Credentials.CredentialUsage.Consumer do
  @enforce_keys [:kind, :id, :label]
  defstruct [:kind, :id, :label, :slot]
end

defmodule ServiceRadar.Credentials.CredentialUsage.Result do
  defstruct status: :available, consumers: [], live_grants: []
end

@spec for_secrets([Ecto.UUID.t()], keyword()) ::
        {:ok, %{Ecto.UUID.t() => Result.t()}} | {:error, term()}
def for_secrets(secret_ids, opts) do
  # Each registered source must return successfully. One error returns {:error, source_reason};
  # never merge a partial map and call missing consumers zero.
end
```

Query direct resources through Ash and trigger-maintained denormalized references through `NetworkCredentialSecretBinding`. Count as live only grants with status in `[:issued, :active]` and `expires_at > now`. Historical sources are omitted from blocking consumers.

- [ ] **Step 4: Implement safe edit and write-only rotation**

Narrow generic update and add an explicit metadata action:

```elixir
update :edit_details do
  accept [:name, :description]
end
```

`build_rotation/4` reuses descriptor validation, verifies the existing credential's provider, kind, and auth-method metadata, then returns exactly `secret_payload`, `username`, `public_fingerprint`, `metadata`, and `next_rotation_due_at`. `CredentialRotation.rotate/4` builds first, calls `start_rotation`, then `complete_rotation`; if completion fails it calls `fail_rotation` with a classified redacted message. Extend `complete_rotation` to accept descriptor-approved `username`.

- [ ] **Step 5: Implement guarded permanent destroy**

Add a transaction-backed Ash destroy action:

```elixir
destroy :destroy_permanently do
  primary? true
  argument :confirm_secret_id, :uuid, allow_nil?: false
  change {ServiceRadar.Credentials.Changes.GuardCredentialDestroy, []}
end
```

Expose the destroy action with `define :destroy_permanently, action: :destroy_permanently, args: [:confirm_secret_id]`, so the public call is `destroy_permanently(secret, secret.id, scope: scope)`.

The change verifies the confirmation ID, queries `CredentialUsage`, rejects unavailable/nonempty usage, removes expired or terminal grants through a system-only grant destroy action, records `NetworkCredentialSecretDeletionAudit` inside the transaction, and allows the parent delete. Map a final FK violation to a stable `credential_in_use` error because that is the expected concurrent-bind loser.

- [ ] **Step 6: Run core tests to GREEN and commit**

```bash
bazel test --config=remote //elixir/serviceradar_core:unit_tests
MIX_ENV=test mix test test/serviceradar/credentials/credential_secret_reference_constraints_db_test.exs test/serviceradar/credentials/network_credential_secret_destroy_db_test.exs
git add elixir/serviceradar_core
git commit -m "feat(credentials): manage and delete reusable secrets"
```

---

### Task 3: Navigable inventory and action components

**Files:**
- Create: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live/credential_inventory_components.ex`
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live.ex`
- Modify: `elixir/web-ng/test/phoenix/components/credential_inventory_components_test.exs`

**Interfaces:**
- Consumes: `%CredentialUsage.Result{}` and `%CredentialUsage.Consumer{}` from Task 2.
- Produces: `credential_inventory_table/1`, `credential_usage_summary/1`, and modal components for edit, rotation, used-delete, unused-delete, and unavailable usage.
- Produces: contextual element IDs `credential-actions-<id>`, `credential-edit-modal`, `credential-rotate-modal`, and `credential-delete-modal`.

- [ ] **Step 1: Write failing db-free rendering tests**

```elixir
test "one SNMP profile is a direct named edit link" do
  html = render_inventory(usage: usage([consumer(:snmp_profile, "profile-1", "Default SNMP")]))

  assert html =~ ~s(href="/settings/snmp/profile-1/edit")
  assert html =~ "1 SNMP profile"
  assert html =~ "Default SNMP"
end

test "unavailable usage blocks the destructive confirmation" do
  html = render_delete_modal(usage: :unavailable)

  assert html =~ "Usage unavailable"
  refute html =~ ~s(phx-click="confirm_delete_credential")
end

test "secret values never render in rotation validation" do
  marker = "ui-secret-marker-rotate"
  html = render_rotation_modal(errors: ["API token is required"], submitted_fields: %{"api_token" => marker})

  refute html =~ marker
  assert html =~ ~s(value="")
end

defp consumer(kind, id, label),
  do: %CredentialUsage.Consumer{kind: kind, id: id, label: label}

defp usage(consumers),
  do: %CredentialUsage.Result{status: :available, consumers: consumers, live_grants: []}
```

Add zero/one/many rules and SNMP profiles, multiple-kind disclosure, contextual action labels, immutable edit context, used-delete named links, and accessibility names/focus attributes.

- [ ] **Step 2: Run the component test and confirm RED**

Run:

```bash
bazel test --config=remote //elixir/web-ng:unit_tests
```

Expected: FAIL because the usage model is count-only and action/modals do not exist.

- [ ] **Step 3: Extract and implement inventory components**

Use existing `UIComponents.ui_dropdown`, `ui_modal`, `ui_button`, and token classes. Render one consumer as a direct link and many as a compact details/dropdown list. Construct routes in web-ng:

```elixir
defp consumer_path(%Consumer{kind: :snmp_profile, id: id}),
  do: ~p"/settings/snmp/#{id}/edit"

defp consumer_path(%Consumer{kind: :credential_rule, id: id}),
  do: ~p"/settings/networks/credentials/#{id}/edit"

defp consumer_path(_consumer), do: nil
```

The Actions dropdown contains `Edit details`, `Rotate`, and `Delete`. Delete always opens a modal: used/unavailable states expose only Close; unused exposes the named permanent-delete confirmation. Secret fields receive blank values after every render, including validation errors.

- [ ] **Step 4: Run db-free tests to GREEN and commit**

```bash
bazel test --config=remote //elixir/web-ng:unit_tests
git add elixir/web-ng
git commit -m "feat(web-ng): link credential consumers and actions"
```

---

### Task 4: Authorized LiveView management flows

**Files:**
- Modify: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/network_credential_rules_live.ex`
- Modify: `elixir/web-ng/test/phoenix/live/settings/network_credential_rules_live_test.exs`

**Interfaces:**
- Consumes: Task 2 core lifecycle and Task 3 components.
- Produces events: `edit_credential`, `save_credential_details`, `rotate_credential`, `save_credential_rotation`, `delete_credential`, `confirm_delete_credential`, `close_credential_modal`.
- Produces assigns: `credential_usage_by_id`, `credential_modal`, `credential_form`, `credential_action_error` with no plaintext secret values.

- [ ] **Step 1: Write failing LiveView behavior tests**

```elixir
test "the SNMP usage link opens the referenced profile", %{conn: conn, scope: scope} do
  secret = credential_secret_fixture(scope)
  profile = snmp_profile_fixture(scope, credential_secret_id: secret.id, name: "Default SNMP")
  {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

  assert has_element?(lv, "#credential-secret-#{secret.id} a[href='/settings/snmp/#{profile.id}/edit']", "Default SNMP")
end

test "used credential cannot be deleted until its profile is detached", %{conn: conn, scope: scope} do
  secret = credential_secret_fixture(scope)
  profile = snmp_profile_fixture(scope, credential_secret_id: secret.id)
  {:ok, lv, _html} = live(conn, ~p"/settings/networks/credentials")

  html = render_click(lv, "delete_credential", %{"id" => secret.id})
  assert html =~ "Can't delete"
  refute has_element?(lv, "button[phx-click='confirm_delete_credential']")

  clear_profile_secret(profile, scope)
  render_click(lv, "delete_credential", %{"id" => secret.id})
  render_click(lv, "confirm_delete_credential", %{"id" => secret.id})
  refute has_element?(lv, "#credential-secret-#{secret.id}")
end
```

Add metadata-only edit preserving decrypted payload, successful rotation, validation/failure redaction, external/disabled/rotating rejection, usage query failure, stale ID, concurrent last-moment consumer, focused-row deletion navigation, and a forged event after permission removal.

- [ ] **Step 2: Run the LiveView test and confirm RED**

Run:

```bash
bazel test --config=remote //elixir/web-ng:unit_tests
```

Expected: FAIL on missing management events and linked usage behavior.

- [ ] **Step 3: Implement fresh authorization and state transitions**

Wrap every new event:

```elixir
defp authorize_manage_event(socket, fun) when is_function(fun, 0) do
  ServiceRadar.Identity.RBAC.clear_process_cache()

  if RBAC.can?(socket.assigns.current_scope, "settings.credentials.manage") do
    fun.()
  else
    {:noreply,
     socket
     |> put_flash(:error, "Not authorized to manage credentials")
     |> redirect(to: ~p"/settings/profile")}
  end
end
```

Load usage through `CredentialUsage.for_secrets/2`; preserve `:unavailable` instead of manufacturing zero. Fetch credentials only through the public read action. Rotation looks up the current approved descriptor and passes submitted fields directly to `build_rotation/4`; immediately replace all template-facing submitted secret field values with empty strings. On delete confirmation, ignore socket counts and invoke the guarded Ash destroy action, then reload both inventory and usage.

- [ ] **Step 4: Run web-ng tests to GREEN and commit**

```bash
bazel test --config=remote //elixir/web-ng:unit_tests
git add elixir/web-ng
git commit -m "feat(web-ng): manage reusable credentials"
```

---

### Task 5: Spec bookkeeping and repository verification

**Files:**
- Modify: `openspec/changes/refactor-unified-credential-management/tasks.md`
- Modify: `docs/docs/credentials.md`
- Modify if required by generated migration: `elixir/serviceradar_core/priv/repo/migrations/20260830220000_guard_network_credential_secret_deletion.exs`

**Interfaces:**
- Consumes all previous tasks.
- Produces operator documentation and verified OpenSpec task status for only the completed credential inventory/lifecycle items.

- [ ] **Step 1: Update operator documentation**

Document Edit details, write-only Rotate, linked usage, permanent-delete prerequisites, active-grant behavior, and the fact that removing a consumer is required before deletion. Do not document any secret-recovery path.

- [ ] **Step 2: Mark only implemented OpenSpec tasks complete**

Mark 2.4 and 2.6-2.9, 3.8-3.9, and 5.6-5.8 complete only after their corresponding tests pass. Leave broader unimplemented unified-credential tasks untouched.

- [ ] **Step 3: Validate formatting, spec, focused suites, then full repository**

Run:

```bash
mix format --check-formatted
openspec validate refactor-unified-credential-management --strict
bazel test --config=remote //elixir/serviceradar_core:unit_tests
bazel test --config=remote //elixir/web-ng:unit_tests
make lint
make test
```

Run both new DB test files against a fresh disposable scratch database before these commands. Expected: every command exits zero. Read the final output and record exact target/test counts; do not infer success from a running job. The guarded core integration lanes run only in the in-cluster GitHub/BuildBuddy workflow and are verified from PR checks.

- [ ] **Step 4: Commit verification/docs**

```bash
git add docs/docs/credentials.md openspec/changes/refactor-unified-credential-management
git commit -m "docs(credentials): document guarded management"
```

---

### Task 6: Review, PR update, candidate build, and farm01 verification

**Files:**
- No release/version files.
- Runtime-only farm01 Helm value override for the immutable candidate tag/digest.

**Interfaces:**
- Produces: updated GitHub PR #4180, immutable `sha-<commit>` images, farm01 rollout, and browser/database verification evidence.

- [ ] **Step 1: Run whole-branch review and address findings**

Generate a review package from `git merge-base origin/staging HEAD` through `HEAD`, run the required final code review, fix any load-bearing findings, and repeat the scoped verification once.

- [ ] **Step 2: Push the feature branch with the required explicit refspec**

```bash
git push github codex/fix-credential-inventory-links:refs/heads/codex/fix-credential-inventory-links
gh pr view 4180 --repo carverauto/serviceradar
gh pr checks 4180 --repo carverauto/serviceradar
```

Verify the push output says `-> codex/fix-credential-inventory-links`, never `-> staging`.

- [ ] **Step 3: Build and publish the immutable candidate without cutting a release**

Use `.agents/skills/demo-local-rollout/SKILL.md`. Build/push `sha-<full-HEAD>` images through the documented Bazel targets. Do not update `VERSION`, `CHANGELOG`, Helm chart version, a semver tag, or `latest`.

- [ ] **Step 4: Roll farm01 and verify the rollout completed after the build**

Apply the candidate tag/digest to farm01 with the rollout skill, wait for all affected workloads and the migration job to become healthy, and confirm every inspected pod started after the rollout began.

- [ ] **Step 5: Verify behavior through UI and CNPG artifacts**

With Playwright against farm01:

1. Open the reusable SNMP credential row and follow `1 SNMP profile · <name>` directly to the profile editor.
2. Edit its description and verify the payload marker never appears.
3. Rotate a disposable test credential and verify success with blank secret fields on reopen.
4. Attempt to delete a credential bound to an SNMP profile and verify the linked blocking consumer.
5. Detach a disposable credential's final consumer, delete it, and verify the row disappears.

In CNPG, query only non-secret artifacts: parent absence, zero version rows, one redacted deletion audit, and no orphan binding rows. Include explicit failure branches for each assertion.

- [ ] **Step 6: Report the candidate, rollout, PR, and verification evidence**

Report commit SHA, PR URL/check state, image tag/digest, farm01 Helm revision/pod readiness, exact test counts, browser scenarios, database artifact checks, and the explicit statement that no release was cut.
