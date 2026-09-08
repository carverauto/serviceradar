defmodule ServiceRadar.CompositeChecks.EvaluationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.CompositeChecks.RuleGenerator
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability

  defp actor, do: SystemActor.system(:composite_check_test)

  defmodule ScopeRunner do
    @moduledoc false

    def query_page(_query, _opts) do
      uids = Process.get(:scope_uids, ["device-1"])
      {:ok, %{rows: Enum.map(uids, &%{"uid" => &1}), next_cursor: nil}}
    end
  end

  defmodule FailingRunner do
    @moduledoc false
    def query_page(_query, _opts), do: {:error, :boom}
  end

  # device_agent_availability.device_uid is a foreign key onto ocsf_devices, so
  # availability rows need a real device behind them.
  defp device!(uid) do
    <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      hostname: "composite-#{a}-#{b}",
      ip: "10.#{a}.#{b}.#{max(c, 1)}"
    })
    |> Ash.create!(actor: actor())
  end

  defp availability(device_uid, agent_id, is_available, checked_at) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        agent_id: agent_id,
        is_available: is_available,
        checked_at: checked_at
      },
      actor: actor()
    )
    |> Ash.create!()
  end

  defp build_check(opts \\ []) do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Eval #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    inputs =
      for {key, expected, position} <- [{"a", "available", 0}, {"b", "blocked", 1}] do
        CompositeCheckInput
        |> Ash.Changeset.for_create(
          :create,
          %{
            check_id: check.id,
            key: key,
            label: key,
            position: position,
            kind: :vantage_point,
            expected: expected,
            config: %{"agent_id" => "agent-#{key}", "max_age_seconds" => 900}
          },
          actor: actor()
        )
        |> Ash.create!()
      end

    inputs =
      if Keyword.get(opts, :with_fact, false) do
        fact =
          CompositeCheckInput
          |> Ash.Changeset.for_create(
            :create,
            %{
              check_id: check.id,
              key: "nac",
              label: "nac",
              position: 2,
              kind: :device_metadata,
              config: %{"path" => "nac_applied", "value_type" => "boolean"}
            },
            actor: actor()
          )
          |> Ash.create!()

        inputs ++ [fact]
      else
        inputs
      end

    for attrs <- RuleGenerator.generate(inputs) do
      CompositeCheckRule
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), actor: actor())
      |> Ash.create!()
    end

    check
  end

  setup do
    Process.put(:scope_uids, ["device-1"])
    device!("device-1")
    device!("device-2")
    %{check: build_check()}
  end

  defp run(check, opts \\ []) do
    Evaluation.run(check, Keyword.merge([actor: actor(), runner: ScopeRunner], opts))
  end

  defp result(check, uid) do
    DeviceCompositeCheckResult.get_by_device_check(uid, check.id, actor: actor())
  end

  test "two agents disagreeing produces the isolated verdict", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, summary} = run(check)
    assert summary.evaluated == 1

    assert {:ok, result} = result(check, "device-1")
    assert result.verdict == "isolated_verified"
    assert result.status == :healthy
    assert result.inputs["a"]["value"] == "available"
    assert result.inputs["b"]["value"] == "blocked"
  end

  test "reachable from both is a real finding", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", true, now)

    assert {:ok, _} = run(check)

    {:ok, result} = result(check, "device-1")
    assert result.verdict == "not_isolated"
    assert result.status == :down
  end

  test "unreachable from every vantage point is not compliant", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", false, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, _} = run(check)

    {:ok, result} = result(check, "device-1")
    assert result.verdict == "device_unreachable"
    assert result.status == :degraded
    refute result.status == :healthy
  end

  test "a missing vantage point falls through to inconclusive", %{check: check} do
    availability("device-1", "agent-a", true, DateTime.utc_now())

    assert {:ok, _} = run(check)

    {:ok, result} = result(check, "device-1")
    assert result.verdict == "inconclusive"
    assert result.inputs["b"]["reason"] == "no_result"
  end

  test "a stale availability row falls through to inconclusive", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, DateTime.add(now, -5_000))

    assert {:ok, _} = run(check)

    {:ok, result} = result(check, "device-1")
    assert result.verdict == "inconclusive"
    assert result.inputs["b"]["stale"]
  end

  test "changed_at advances only when the verdict changes", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, first} = run(check)
    assert [%{from_verdict: nil, to_verdict: "isolated_verified"}] = first.transitions

    {:ok, initial} = result(check, "device-1")

    assert {:ok, second} = run(check)
    assert second.transitions == []

    {:ok, again} = result(check, "device-1")

    assert again.changed_at == initial.changed_at
    assert DateTime.compare(again.evaluated_at, initial.evaluated_at) in [:gt, :eq]
  end

  test "a device leaving scope loses its result row", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, _} = run(check)

    Process.put(:scope_uids, ["device-2"])
    assert {:ok, summary} = run(check)
    assert summary.removed == 1

    assert {:error, _} = result(check, "device-1")
  end

  test "a failed page does not delete existing results", %{check: check} do
    # Un-evaluated rows keep an older evaluated_at and are indistinguishable
    # from devices that left the scope, so a partial pass must never sweep.
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, _} = run(check)
    assert {:ok, _} = result(check, "device-1")

    assert_raise RuntimeError, ~r/scope query failed/, fn ->
      run(check, runner: FailingRunner)
    end

    assert {:ok, still_there} = result(check, "device-1")
    assert still_there.verdict == "isolated_verified"
  end

  test "evaluates a whole page without a query per device", %{check: check} do
    now = DateTime.utc_now()
    uids = for n <- 1..25, do: "bulk-#{n}"
    Process.put(:scope_uids, uids)

    for uid <- uids do
      device!(uid)
      availability(uid, "agent-a", true, now)
      availability(uid, "agent-b", false, now)
    end

    assert {:ok, summary} = run(check)
    assert summary.evaluated == 25

    for uid <- uids do
      assert {:ok, %{verdict: "isolated_verified"}} = result(check, uid)
    end
  end

  describe "verdict events" do
    defp verdict_events do
      require Ash.Query

      ServiceRadar.Monitoring.OcsfEvent
      |> Ash.Query.filter(log_name == ^ServiceRadar.CompositeChecks.VerdictEventWriter.log_name())
      |> Ash.read!(actor: actor())
    end

    test "a pass emits an event on transition and stays silent when unchanged", %{check: check} do
      now = DateTime.utc_now()
      availability("device-1", "agent-a", true, now)
      availability("device-1", "agent-b", false, now)

      assert {:ok, _} = run(check)
      assert [event] = verdict_events()
      assert event.unmapped["to_verdict"] == "isolated_verified"

      assert {:ok, _} = run(check)
      assert length(verdict_events()) == 1
    end

    test "emit_events? false lets a pass run without touching the event stream", %{check: check} do
      now = DateTime.utc_now()
      availability("device-1", "agent-a", true, now)
      availability("device-1", "agent-b", false, now)

      assert {:ok, summary} = run(check, emit_events?: false)
      assert [_transition] = summary.transitions
      assert verdict_events() == []
    end
  end

  test "does not write Device.is_available unless the check opts in", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    {:ok, device} = Device.get_by_uid("device-1", false, actor: actor())

    assert {:ok, _} =
             device
             |> Ash.Changeset.for_update(:set_availability, %{is_available: false},
               actor: actor()
             )
             |> Ash.update()

    assert {:ok, _} = run(check)

    {:ok, after_eval} = Device.get_by_uid("device-1", false, actor: actor())
    refute after_eval.is_available
  end

  test "write_canonical_availability projects a healthy verdict onto Device.is_available", %{
    check: check
  } do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    assert {:ok, check} =
             check
             |> Ash.Changeset.for_update(:update, %{write_canonical_availability: true},
               actor: actor()
             )
             |> Ash.update()

    {:ok, device} = Device.get_by_uid("device-1", false, actor: actor())

    assert {:ok, _} =
             device
             |> Ash.Changeset.for_update(:set_availability, %{is_available: false},
               actor: actor()
             )
             |> Ash.update()

    assert {:ok, _} = run(check)

    {:ok, after_eval} = Device.get_by_uid("device-1", false, actor: actor())
    assert after_eval.is_available
  end

  test "evaluate_devices resolves without persisting", %{check: check} do
    now = DateTime.utc_now()
    availability("device-1", "agent-a", true, now)
    availability("device-1", "agent-b", false, now)

    {:ok, inputs} = CompositeCheckInput.list_by_check(check.id, actor: actor())
    {:ok, rules} = CompositeCheckRule.list_by_check(check.id, actor: actor())

    assert {:ok, [row]} = Evaluation.evaluate_devices(check, inputs, rules, ["device-1"])
    assert row.verdict == "isolated_verified"

    # Preview must leave no trace.
    assert {:error, _} = result(check, "device-1")
  end

  describe "with a device metadata input" do
    setup do
      Process.put(:scope_uids, ["device-1"])
      %{check: build_check(with_fact: true)}
    end

    @describetag :with_fact

    test "an absent fact is inconclusive, not false", %{check: check} do
      now = DateTime.utc_now()
      availability("device-1", "agent-a", true, now)
      availability("device-1", "agent-b", false, now)

      assert {:ok, _} = run(check)

      {:ok, result} = result(check, "device-1")
      assert result.verdict == "inconclusive"
      assert result.inputs["nac"]["reason"] == "absent"
    end
  end
end
