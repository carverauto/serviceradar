defmodule ServiceRadar.CompositeChecks.CompositeCheckRuleTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckRule

  defp actor, do: SystemActor.system(:composite_check_test)

  # The catch-all guard is a policy, and `system_bypass()` lets system actors
  # past every policy. Operator edits are the path that guard exists for, so
  # these cases must be exercised as an operator.
  defp operator, do: %{id: Ash.UUID.generate(), role: :operator}

  defp new_check do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Rule Fixture #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    check
  end

  defp create_rule(check, attrs) do
    CompositeCheckRule
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
    |> Ash.create()
  end

  test "creating a check creates its catch-all rule" do
    check = new_check()

    assert {:ok, [rule]} = CompositeCheckRule.list_by_check(check.id, actor: actor())
    assert rule.catch_all
    assert rule.verdict == "inconclusive"
    assert rule.status == :unknown
    assert rule.match == %{}
  end

  test "the catch-all cannot be destroyed" do
    check = new_check()
    {:ok, [catch_all]} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert {:error, %Forbidden{}} = Ash.destroy(catch_all, actor: operator())
  end

  test "the catch-all can be relabelled without touching its matching" do
    check = new_check()
    {:ok, [catch_all]} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert {:ok, updated} =
             catch_all
             |> Ash.Changeset.for_update(:relabel, %{verdict_label: "Not enough signal"},
               actor: operator()
             )
             |> Ash.update()

    assert updated.verdict_label == "Not enough signal"
    assert updated.match == %{}
    assert updated.position == 1_000_000
  end

  test "the catch-all rejects a match or position edit rather than silently discarding it" do
    check = new_check()
    {:ok, [catch_all]} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert {:error, %Forbidden{}} =
             catch_all
             |> Ash.Changeset.for_update(:update, %{position: 0}, actor: operator())
             |> Ash.update()

    assert {:error, %Forbidden{}} =
             catch_all
             |> Ash.Changeset.for_update(:update, %{match: %{"agent_a" => "available"}},
               actor: operator()
             )
             |> Ash.update()

    {:ok, [reloaded]} = CompositeCheckRule.list_by_check(check.id, actor: actor())
    assert reloaded.match == %{}
    assert reloaded.position == 1_000_000
  end

  test "an authored rule can still be edited by an operator" do
    check = new_check()

    {:ok, rule} =
      create_rule(check, %{
        position: 0,
        match: %{"agent_a" => "available"},
        verdict: "ok",
        verdict_label: "OK",
        status: :healthy
      })

    assert {:ok, updated} =
             rule
             |> Ash.Changeset.for_update(:update, %{position: 3, status: :degraded},
               actor: operator()
             )
             |> Ash.update()

    assert updated.position == 3
    assert updated.status == :degraded
  end

  test "rules sort by position with the catch-all last" do
    check = new_check()

    for {verdict, position} <- [{"not_isolated", 2}, {"isolated_verified", 0}] do
      assert {:ok, _} =
               create_rule(check, %{
                 position: position,
                 match: %{"agent_a" => "available"},
                 verdict: verdict,
                 verdict_label: verdict,
                 status: :healthy
               })
    end

    {:ok, rules} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert Enum.map(rules, & &1.verdict) == ["isolated_verified", "not_isolated", "inconclusive"]
    assert List.last(rules).catch_all
  end

  # Regression: an Ash validation reading `get_attribute(:match)` returns nil
  # when the update runs atomically (atomic changes live in changeset.atomics),
  # so a validation-based non-empty check rejected every legitimate match edit.
  # The rule is a database check constraint for exactly this reason.
  test "an operator can edit a rule's match" do
    check = new_check()

    {:ok, rule} =
      create_rule(check, %{
        position: 0,
        match: %{"agent_a" => "available"},
        verdict: "ok",
        verdict_label: "OK",
        status: :healthy
      })

    assert {:ok, updated} =
             rule
             |> Ash.Changeset.for_update(
               :update,
               %{match: %{"agent_a" => "available", "agent_b" => "blocked"}},
               actor: operator()
             )
             |> Ash.update()

    assert updated.match == %{"agent_a" => "available", "agent_b" => "blocked"}
  end

  test "an operator cannot empty an authored rule's match" do
    check = new_check()

    {:ok, rule} =
      create_rule(check, %{
        position: 0,
        match: %{"agent_a" => "available"},
        verdict: "ok",
        verdict_label: "OK",
        status: :healthy
      })

    assert {:error, error} =
             rule
             |> Ash.Changeset.for_update(:update, %{match: %{}}, actor: operator())
             |> Ash.update()

    assert Exception.message(error) =~ "at least one input"
  end

  test "a non-catch-all rule requires a non-empty match" do
    check = new_check()

    assert {:error, error} =
             create_rule(check, %{
               position: 0,
               match: %{},
               verdict: "everything",
               verdict_label: "Everything",
               status: :healthy
             })

    assert Exception.message(error) =~ "at least one input"
  end

  test "status is constrained to the fixed enum" do
    check = new_check()

    assert {:error, _} =
             create_rule(check, %{
               position: 0,
               match: %{"agent_a" => "available"},
               verdict: "made_up",
               verdict_label: "Made up",
               status: :catastrophic
             })
  end

  test "a normal rule can be deleted" do
    check = new_check()

    {:ok, rule} =
      create_rule(check, %{
        position: 0,
        match: %{"agent_a" => "available"},
        verdict: "ok",
        verdict_label: "OK",
        status: :healthy
      })

    assert :ok = Ash.destroy(rule, actor: actor())
    assert {:ok, [remaining]} = CompositeCheckRule.list_by_check(check.id, actor: actor())
    assert remaining.catch_all
  end
end
