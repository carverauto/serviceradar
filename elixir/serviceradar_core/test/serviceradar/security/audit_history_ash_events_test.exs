defmodule ServiceRadar.Security.AuditHistoryAshEventsTest do
  @moduledoc """
  Coverage for `AuditHistory`'s AshEvents (`ApiEvent`) integration --
  `add-ash-events-audit-log` tasks.md section 4: `ApiEvent` rows are
  adapted into the same field-name shape AshPaperTrail's `<Resource>.Version`
  rows use, unioned into `list_recent/2`, with existing access control
  (per-resource Ash policies -- here, `ApiEvent`'s own `settings.audit.view`
  policy) preserved exactly.
  """
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadar.Security.AuthLockout

  @system SystemActor.system(:audit_history_ash_events_test)
  @viewer %{id: Ecto.UUID.generate(), role: :viewer}

  defp user_fixture(role) do
    # See stateful_alert_rule_events_test.exs's user_fixture/1 for why a
    # throwaway admin is registered first (AssignFirstUserRole /
    # DisallowLastAdminLockout).
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
          email: "audit-history-ash-events-test-#{unique}@example.com",
          password: password,
          password_confirmation: password
        },
        actor: @system
      )

    user
  end

  defp rule_params do
    unique = System.unique_integer([:positive])

    %{
      name: "Audit History Ash Events Rule #{unique}",
      signal: :log,
      match: %{},
      group_by: ["serviceradar.sync.integration_source_id"]
    }
  end

  test "ash_events_resources/0 includes StatefulAlertRule by default" do
    assert StatefulAlertRule in AuditHistory.ash_events_resources()
  end

  test "all_resources/0 unions both allow-lists" do
    all = AuditHistory.all_resources()

    assert StatefulAlertRule in all
    assert Enum.all?(AuditHistory.resources(), &(&1 in all))
  end

  describe "list_recent/2 with ApiEvent rows" do
    test "an authorized actor sees the create event, adapted with origin from metadata[\"source\"]" do
      operator = user_fixture(:operator)

      assert {:ok, rule} =
               StatefulAlertRule
               |> Ash.Changeset.new()
               |> Ash.Changeset.set_context(%{source: "api"})
               |> Ash.Changeset.for_create(:create, rule_params(), actor: operator)
               |> Ash.create()

      entries =
        AuditHistory.list_recent(actor: operator, resource_types: [StatefulAlertRule], limit: 50)

      assert entry = Enum.find(entries, &(&1.version.version_source_id == rule.id))
      assert entry.resource == StatefulAlertRule
      assert entry.origin == "api"
      assert entry.version.version_action_type == "create"
      assert %{"actor" => %{"id" => actor_id}} = entry.version.version_action_inputs
      assert actor_id == operator.id
    end

    test "default history includes events while a PaperTrail filter stays scoped" do
      operator = user_fixture(:operator)

      rule =
        StatefulAlertRule
        |> Ash.Changeset.for_create(:create, rule_params(), actor: operator)
        |> Ash.create!()

      lock =
        AuthLockout
        |> Ash.Changeset.for_create(:lock, %{actor_id: Ecto.UUID.generate()}, actor: @system)
        |> Ash.create!()

      entries = AuditHistory.list_recent(actor: operator)
      assert Enum.any?(entries, &(&1.version.version_source_id == rule.id))
      assert Enum.any?(entries, &(&1.version.version_source_id == lock.id))

      entries = AuditHistory.list_recent(actor: operator, resource_types: [AuthLockout])
      assert Enum.any?(entries, &(&1.version.version_source_id == lock.id))
      assert Enum.all?(entries, &(&1.resource == AuthLockout))
    end

    test "update inputs retain mutation values alongside actor attribution" do
      operator = user_fixture(:operator)

      rule =
        StatefulAlertRule
        |> Ash.Changeset.for_create(:create, rule_params(), actor: operator)
        |> Ash.create!()

      rule
      |> Ash.Changeset.for_update(:update, %{priority: 7}, actor: operator)
      |> Ash.update!()

      assert [entry] =
               AuditHistory.list_recent(
                 actor: operator,
                 resource_types: [StatefulAlertRule],
                 action_types: ["update"]
               )

      assert %{"priority" => 7, "actor" => %{"id" => actor_id}} =
               entry.version.version_action_inputs

      assert actor_id == operator.id
    end

    test "actor filtering precedes pagination for user and metadata identities" do
      operator = user_fixture(:operator)
      other_operator = user_fixture(:operator)

      for event_actor <- [operator, Map.from_struct(operator)] do
        rule =
          StatefulAlertRule
          |> Ash.Changeset.for_create(:create, rule_params(), actor: event_actor)
          |> Ash.create!()

        rule
        |> Ash.Changeset.for_update(:update, %{priority: 7}, actor: event_actor)
        |> Ash.update!()

        StatefulAlertRule
        |> Ash.Changeset.for_create(:create, rule_params(), actor: other_operator)
        |> Ash.create!()

        opts = [
          actor: operator,
          actor_id: operator.id,
          resource_types: [StatefulAlertRule],
          limit: 1
        ]

        assert [entry] = AuditHistory.list_recent(opts)
        assert entry.version.version_source_id == rule.id
        assert entry.version.version_action_type == "update"

        assert [entry] = AuditHistory.list_recent(Keyword.put(opts, :offset, 1))
        assert entry.version.version_source_id == rule.id
        assert entry.version.version_action_type == "create"
      end
    end

    test "an actor without settings.audit.view sees no rows for that resource" do
      operator = user_fixture(:operator)

      assert {:ok, _rule} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(:create, rule_params(), actor: operator)
               |> Ash.create()

      # `settings.audit.view` defaults to operator/admin roles (RBAC
      # catalog) -- a plain viewer reads none of these rows, exactly as it
      # reads none of the PaperTrail-backed resources' version rows.
      assert AuditHistory.list_recent(
               actor: @viewer,
               resource_types: [StatefulAlertRule],
               limit: 50
             ) == []
    end
  end
end
