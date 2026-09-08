defmodule ServiceRadar.Observability.StatefulAlertRulePolicyTest do
  @moduledoc """
  Policy/domain-level coverage for `StatefulAlertRule`'s authorization rules,
  now that `ServiceRadar.Observability` is mounted on the JSON:API router
  (`add-alert-rule-json-api`, tasks.md section 4).

  Mirrors the shape `elixir/web-ng`'s `service_check_test.exs` exercises for
  `ServiceCheck` (system bypasses everything, operator can create/update, viewer
  cannot update) plus an explicit destroy check for both roles.

  Written directly against `PresetRuleResource`'s actual policy
  (`system_bypass(); read_viewer_plus(); operator_action([:create, :update,
  :destroy])`) rather than the generic `assert_rbac_matrix/2` helper in
  `policy_test_helpers.ex`: that helper's `expected_permission/2` assumes
  operator cannot destroy, which is wrong for every `PresetRuleResource`
  caller including this one (tasks.md 5.5 / design.md Risks).
  """
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRule

  @system SystemActor.system(:stateful_alert_rule_policy_test)
  @admin %{id: Ecto.UUID.generate(), role: :admin}
  @operator %{id: Ecto.UUID.generate(), role: :operator}
  @viewer %{id: Ecto.UUID.generate(), role: :viewer}

  defp rule_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Policy Test Rule #{unique}",
      signal: :log,
      match: %{},
      group_by: ["serviceradar.sync.integration_source_id"]
    }

    StatefulAlertRule
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: @system)
    |> Ash.create!()
  end

  describe "read" do
    test "system, admin, operator, and viewer can all read" do
      _rule = rule_fixture()

      for actor <- [@system, @admin, @operator, @viewer] do
        assert Ash.can?({StatefulAlertRule, :read}, actor, maybe_is: false),
               "expected #{inspect(actor.role)} to be able to read StatefulAlertRule"
      end
    end

    test "a nil actor cannot read any rows" do
      _rule = rule_fixture()

      refute Ash.can?({StatefulAlertRule, :read}, nil, maybe_is: false)

      assert {:ok, []} =
               StatefulAlertRule
               |> Ash.Query.for_read(:read, %{}, actor: nil)
               |> Ash.read()
    end
  end

  describe "create" do
    test "operator can create a rule" do
      assert {:ok, %StatefulAlertRule{}} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Operator Rule #{System.unique_integer([:positive])}",
                   signal: :log,
                   match: %{},
                   group_by: ["serviceradar.sync.integration_source_id"]
                 },
                 actor: @operator
               )
               |> Ash.create()
    end

    test "admin can create a rule" do
      assert {:ok, %StatefulAlertRule{}} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Admin Rule #{System.unique_integer([:positive])}",
                   signal: :log,
                   match: %{},
                   group_by: ["serviceradar.sync.integration_source_id"]
                 },
                 actor: @admin
               )
               |> Ash.create()
    end

    test "viewer cannot create a rule" do
      assert {:error, %Forbidden{}} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Viewer Rule #{System.unique_integer([:positive])}",
                   signal: :log,
                   match: %{},
                   group_by: ["serviceradar.sync.integration_source_id"]
                 },
                 actor: @viewer
               )
               |> Ash.create()
    end

    test "a nil actor cannot create a rule" do
      assert {:error, %Forbidden{}} =
               StatefulAlertRule
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Nil Actor Rule #{System.unique_integer([:positive])}",
                   signal: :log,
                   match: %{},
                   group_by: ["serviceradar.sync.integration_source_id"]
                 },
                 actor: nil
               )
               |> Ash.create()
    end
  end

  describe "update" do
    setup do
      {:ok, rule: rule_fixture()}
    end

    test "operator can update a rule", %{rule: rule} do
      assert {:ok, updated} =
               rule
               |> Ash.Changeset.for_update(:update, %{priority: 5}, actor: @operator)
               |> Ash.update()

      assert updated.priority == 5
    end

    test "admin can update a rule", %{rule: rule} do
      assert {:ok, updated} =
               rule
               |> Ash.Changeset.for_update(:update, %{priority: 7}, actor: @admin)
               |> Ash.update()

      assert updated.priority == 7
    end

    test "viewer cannot update a rule", %{rule: rule} do
      assert {:error, %Forbidden{}} =
               rule
               |> Ash.Changeset.for_update(:update, %{priority: 5}, actor: @viewer)
               |> Ash.update()
    end
  end

  describe "destroy" do
    setup do
      {:ok, rule: rule_fixture()}
    end

    # PresetRuleResource's policy is `operator_action([:create, :update,
    # :destroy])` -- operator CAN destroy here, unlike the generic 3-tier RBAC
    # matrix's assumption (`expected_permission/2` in
    # `elixir/web-ng/test/support/policy_test_helpers.ex`). Explicit coverage
    # per tasks.md 5.5 -- do not rely on the generic matrix helper for this
    # resource.
    test "operator CAN destroy a rule (explicit, not the generic matrix assumption)", %{
      rule: rule
    } do
      result =
        rule
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: @operator)
        |> Ash.destroy()

      refute match?({:error, _}, result)

      assert {:ok, nil} =
               StatefulAlertRule
               |> Ash.Query.for_read(:by_id, %{id: rule.id}, actor: @system)
               |> Ash.read_one()
    end

    test "viewer cannot destroy a rule", %{rule: rule} do
      result =
        rule
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: @viewer)
        |> Ash.destroy()

      assert {:error, %Forbidden{}} = result

      assert {:ok, %StatefulAlertRule{}} =
               StatefulAlertRule
               |> Ash.Query.for_read(:by_id, %{id: rule.id}, actor: @system)
               |> Ash.read_one()
    end
  end
end
