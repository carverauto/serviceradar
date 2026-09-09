defmodule ServiceRadar.Observability.StatefulAlertRuleEventsTest do
  @moduledoc """
  Coverage for the `add-ash-events-audit-log` change (tasks.md section 3):
  every create/update/destroy on `StatefulAlertRule` writes exactly one
  `ApiEvent` row with the correct actor/resource/action/data, stamps
  `metadata["source"]` from the transport (`"api"` vs. `"web"`), and none of
  this changes `PresetRuleResource`'s existing authorization behavior.

  A real `%ServiceRadar.Identity.User{}` actor is required here (rather than
  the plain-map actors `stateful_alert_rule_policy_test.exs` uses) because
  `persist_actor_primary_key` only captures `user_id` when the actor struct
  matches the configured destination resource -- see
  `AshEvents.Events.ActionWrapperHelpers.create_event!/5`.
  """
  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Observability.ApiEvent
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query

  @system SystemActor.system(:stateful_alert_rule_events_test)
  @viewer %{id: Ecto.UUID.generate(), role: :viewer}

  defp user_fixture(role) do
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

    {:ok, user} = User.update_role(user, %{role: role}, actor: @system)
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
end
