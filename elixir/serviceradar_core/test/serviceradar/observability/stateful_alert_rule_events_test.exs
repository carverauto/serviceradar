defmodule ServiceRadar.Observability.StatefulAlertRuleEventsTest do
  @moduledoc """
  Coverage for the `add-ash-events-audit-log` change (tasks.md section 3):
  every create/update/destroy on `StatefulAlertRule` writes exactly one
  `ApiEvent` row with the correct actor/resource/action/data, stamps
  `metadata["source"]` from the transport (`"api"` vs. `"web"`), and none of
  this changes `PresetRuleResource`'s existing authorization behavior.

  A real `%ServiceRadar.Identity.User{}` actor is used for the assertions in
  this file that check `event.user_id` directly, because
  `persist_actor_primary_key` only captures `user_id` when the actor struct
  matches the configured destination resource exactly -- see
  `AshEvents.Events.ActionWrapperHelpers.create_event!/5`. Real production
  traffic never passes that struct, though: both actor-construction paths
  (`set_ash_actor` in the `:ash_json_api` router pipeline, and the
  `Ash.Scope.ToOpts` implementation for `Scope` on the LiveView path) build a
  plain map instead, so `user_id` is `nil` there and attribution instead
  comes from `metadata["actor_id"]` (stamped by
  `ServiceRadar.Observability.Changes.StampEventSource` independently of
  actor shape) -- see the "the actor shape real requests actually use"
  describe block below, which deliberately uses that map shape instead of a
  `%User{}` struct.
  """
  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Observability.ApiEvent
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Plugins.AlertRuleCatalog
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Security.AuditHistory

  require Ash.Query

  @system SystemActor.system(:stateful_alert_rule_events_test)
  @viewer %{id: Ecto.UUID.generate(), role: :viewer}

  defp user_fixture(role) do
    # `AssignFirstUserRole` grants :admin to the first user registered in an
    # empty `ng_users` table -- true for a fresh async transaction -- and
    # `DisallowLastAdminLockout` then refuses to demote the *only* admin.
    # Register a throwaway admin first so the real fixture user below can be
    # freely assigned any role.
    register_user!()

    {:ok, user} = User.update_role(register_user!(), %{role: role}, actor: @system)
    user
  end

  defp register_user! do
    unique = System.unique_integer([:positive])
    password = "Sup3rSecretPassw0rd!#{unique}"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "ash-events-test-#{unique}@example.com",
          password: password,
          password_confirmation: password
        },
        actor: @system
      )

    user
  end

  defp rule_params(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "Ash Events Test Rule #{unique}",
        signal: :log,
        match: %{},
        group_by: ["serviceradar.sync.integration_source_id"]
      },
      attrs
    )
  end

  defp events_for(record_id) do
    ApiEvent
    |> Ash.Query.filter(record_id == ^record_id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(actor: @system)
  end

  test "catalog sync attributes create and update events to its system actor" do
    plugin_id = "audit-catalog-#{System.unique_integer([:positive])}"
    declaration = %{
      "name" => "log-match",
      "signal" => "log",
      "match" => %{"body_contains" => "synthetic failure"},
      "group_by" => ["service.name"],
      "description" => "Initial definition"
    }

    manifest = %{
      "id" => plugin_id,
      "name" => "Audit Catalog",
      "version" => "0.1.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 100},
      "alert_rules" => [declaration]
    }

    ServiceRadar.Plugins.Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Audit Catalog"}, actor: @system)
    |> Ash.create!()

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Audit Catalog",
          version: "0.1.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          alert_rules: [declaration],
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}",
          signature: %{},
          source_type: :upload
        },
        actor: @system
      )
      |> Ash.create!()

    assert :ok = AlertRuleCatalog.sync_package(package)

    assert [rule] =
             StatefulAlertRule
             |> Ash.Query.filter(plugin_package_id == ^package.id)
             |> Ash.read!(actor: @system)

    assert [created] = events_for(rule.id)
    assert created.action_type == :create
    assert created.metadata["actor_id"] == "system:alert_rule_catalog"

    updated_declaration = Map.put(declaration, "description", "Updated definition")
    assert :ok = AlertRuleCatalog.sync_package(%{package | alert_rules: [updated_declaration]})

    assert [_, updated] = events_for(rule.id)
    assert updated.action_type == :update
    assert updated.data["description"] == "Updated definition"
    assert updated.metadata["actor_id"] == "system:alert_rule_catalog"
  end

  describe "create" do
    test "writes exactly one ApiEvent row with the correct actor/resource/action/data" do
      user = user_fixture(:operator)
      params = rule_params()

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, params, actor: user)
               |> Ash.create()

      assert [event] = events_for(rule.id)
      assert event.resource == StatefulAlertRule
      assert event.action == :create
      assert event.action_type == :create
      assert event.record_id == rule.id
      assert event.user_id == user.id
      assert event.data["name"] == params.name
    end
  end

  describe "update" do
    test "writes its own ApiEvent row, distinct from the create event" do
      user = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, rule_params(), actor: user)
               |> Ash.create()

      assert {:ok, updated} =
               rule
               |> Ash.Changeset.for_update(:update, %{priority: 7}, actor: user)
               |> Ash.update()

      assert [create_event, update_event] = events_for(rule.id)
      assert create_event.action_type == :create
      assert update_event.action_type == :update
      assert update_event.action == :update
      assert update_event.record_id == updated.id
      assert update_event.user_id == user.id
    end
  end

  describe "destroy" do
    test "writes its own ApiEvent row, distinct from the create event" do
      user = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, rule_params(), actor: user)
               |> Ash.create()

      result =
        rule
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: user)
        |> Ash.destroy()

      refute match?({:error, _}, result)

      assert [create_event, destroy_event] = events_for(rule.id)
      assert create_event.action_type == :create
      assert destroy_event.action_type == :destroy
      assert destroy_event.action == :destroy
      assert destroy_event.user_id == user.id
    end
  end

  describe "metadata[\"source\"]" do
    test "is \"web\" through the existing LiveView path, which never sets the context flag" do
      user = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, rule_params(), actor: user)
               |> Ash.create()

      assert [event] = events_for(rule.id)
      assert event.metadata["source"] == "web"
    end

    test "is \"api\" when the JSON:API request path's context flag is set" do
      # Mirrors exactly what `AshJsonApi.Controllers.Helpers` does with the
      # conn context `ServiceRadarWebNGWeb.Plugs.ApiSourceContext` sets via
      # `Ash.PlugHelpers.set_context/2`: `Ash.Changeset.new() |>
      # Ash.Changeset.set_context(request.context) |> Ash.Changeset.for_create(...)`.
      user = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_context(%{source: "api"})
               |> Ash.Changeset.for_create(:create, rule_params(), actor: user)
               |> Ash.create()

      assert [event] = events_for(rule.id)
      assert event.metadata["source"] == "api"
    end

    test "update and destroy through the JSON:API context flag are stamped \"api\" too" do
      user = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_context(%{source: "api"})
               |> Ash.Changeset.for_create(:create, rule_params(), actor: user)
               |> Ash.create()

      assert {:ok, updated} =
               rule
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_context(%{source: "api"})
               |> Ash.Changeset.for_update(:update, %{priority: 3}, actor: user)
               |> Ash.update()

      result =
        updated
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_context(%{source: "api"})
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: user)
        |> Ash.destroy()

      refute match?({:error, _}, result)

      assert [create_event, update_event, destroy_event] = events_for(rule.id)
      assert create_event.metadata["source"] == "api"
      assert update_event.metadata["source"] == "api"
      assert destroy_event.metadata["source"] == "api"
    end
  end

  describe "authorization is unaffected by AshEvents" do
    test "a viewer is still denied create, and no ApiEvent row is written for the attempt" do
      params = rule_params()

      assert {:error, %Forbidden{}} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, params, actor: @viewer)
               |> Ash.create()

      assert {:ok, []} =
               ApiEvent
               |> Ash.Query.filter(resource == ^StatefulAlertRule and action_type == :create)
               |> Ash.Query.filter(data["name"] == ^params.name)
               |> Ash.read(actor: @system)
    end

    test "a viewer is still denied update, and no ApiEvent row is written for the attempt" do
      user = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, rule_params(), actor: user)
               |> Ash.create()

      assert {:error, %Forbidden{}} =
               rule
               |> Ash.Changeset.for_update(:update, %{priority: 9}, actor: @viewer)
               |> Ash.update()

      assert [create_event] = events_for(rule.id)
      assert create_event.action_type == :create
    end

    test "a viewer is still denied destroy, and no ApiEvent row is written for the attempt" do
      user = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, rule_params(), actor: user)
               |> Ash.create()

      assert {:error, %Forbidden{}} =
               rule
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: @viewer)
               |> Ash.destroy()

      assert [create_event] = events_for(rule.id)
      assert create_event.action_type == :create
    end
  end

  describe "the actor shape real requests actually use (map, not %User{} struct)" do
    test "create/update/destroy attribute via metadata[\"actor_id\"], and AuditHistory surfaces it" do
      user = user_fixture(:operator)

      # Exactly the shape `set_ash_actor/2` builds on the `:ash_json_api`
      # router pipeline (`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`)
      # and the `Ash.Scope.ToOpts` implementation for `Scope` builds on the
      # LiveView path (`elixir/web-ng/lib/serviceradar_web_ng/ash_scope.ex`)
      # -- both build this plain map for a real user, never the raw
      # `%User{}` struct. `permissions` is a real, DB-resolved `MapSet`, just
      # like both of those call sites produce (via
      # `RBAC.permissions_for_user/1,2` or a pre-loaded `Scope`).
      actor = %{
        id: user.id,
        role: user.role,
        email: user.email,
        role_profile_id: user.role_profile_id,
        permissions: RBAC.permissions_for_user(user, actor: @system)
      }

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, rule_params(), actor: actor)
               |> Ash.create()

      assert {:ok, updated} =
               rule
               |> Ash.Changeset.for_update(:update, %{priority: 4}, actor: actor)
               |> Ash.update()

      result =
        updated
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
        |> Ash.destroy()

      refute match?({:error, _}, result)

      assert [create_event, update_event, destroy_event] = events_for(rule.id)

      # Before the fix, none of this was captured: `persist_actor_primary_key`
      # requires an exact `%User{}` struct match, so `user_id` is correctly
      # nil for this actor shape -- but `metadata["actor_id"]` was *also*
      # unset (the change only ever wrote `metadata["source"]`), so actor
      # attribution was silently and completely lost for this actor shape,
      # which is what every real request through either transport uses.
      for event <- [create_event, update_event, destroy_event] do
        assert event.user_id == nil
        assert event.metadata["actor_id"] == user.id
      end

      entries =
        AuditHistory.list_recent(actor: actor, resource_types: [StatefulAlertRule], limit: 50)

      assert entry = Enum.find(entries, &(&1.version.version_source_id == rule.id))
      assert %{"actor" => %{"id" => actor_id}} = entry.version.version_action_inputs
      assert actor_id == user.id
    end
  end
end
