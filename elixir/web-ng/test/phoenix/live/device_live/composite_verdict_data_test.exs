defmodule ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictDataTest do
  # Writes to shared tables; keep serial to avoid deadlocks in CNPG-backed tests.
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictData

  defp check_fixture(attrs) do
    defaults = %{
      name: "Verdict Check #{System.unique_integer([:positive])}",
      scope_query: "in:devices"
    }

    CompositeCheck
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: system_actor())
    |> Ash.create!()
  end

  defp input_fixture(check, key, attrs) do
    defaults = %{
      check_id: check.id,
      key: key,
      label: key,
      position: 0,
      kind: :vantage_point,
      expected: "blocked",
      config: %{"agent_id" => key, "max_age_seconds" => 900}
    }

    CompositeCheckInput
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: system_actor())
    |> Ash.create!()
  end

  defp rule_fixture(check, attrs) do
    defaults = %{
      check_id: check.id,
      position: 0,
      match: %{"a" => "available"},
      verdict: "isolated_verified",
      verdict_label: "Isolated",
      verdict_description: "Isolation observed",
      status: :healthy
    }

    CompositeCheckRule
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), actor: system_actor())
    |> Ash.create!()
  end

  defp snapshot(value, observed_at, opts \\ []) do
    %{
      "value" => value,
      "observed_at" => observed_at && DateTime.to_iso8601(observed_at),
      "stale" => Keyword.get(opts, :stale, false),
      "reason" => Keyword.get(opts, :reason)
    }
  end

  defp upsert_result(device, check, attrs) do
    now = DateTime.utc_now()

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      Map.merge(
        %{
          device_uid: device.uid,
          check_id: check.id,
          verdict: "isolated_verified",
          status: :healthy,
          inputs: %{},
          evaluated_at: now,
          changed_at: now
        },
        attrs
      ),
      actor: system_actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  describe "load/3" do
    test "a device with no results returns nothing" do
      device = device_fixture(%{})

      assert CompositeVerdictData.load(device.uid, actor: system_actor()) == []
    end

    test "a nil uid returns nothing rather than querying" do
      assert CompositeVerdictData.load(nil, actor: system_actor()) == []
    end

    test "renders the verdict, its label, and the matched rule's explanation" do
      device = device_fixture(%{})
      check = check_fixture(%{})
      rule = rule_fixture(check, %{})

      upsert_result(device, check, %{matched_rule_id: rule.id})

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())

      assert entry.verdict == "isolated_verified"
      # The label and explanation come from the rule that actually matched, so
      # a relabelled rule changes what the device page says.
      assert entry.verdict_label == "Isolated"
      assert entry.explanation == "Isolation observed"
      assert entry.status == :healthy
      assert entry.check_name == check.name
      assert entry.check_slug == check.slug
    end

    test "falls back to the verdict slug when the matched rule is gone" do
      device = device_fixture(%{})
      check = check_fixture(%{})
      rule = rule_fixture(check, %{})

      upsert_result(device, check, %{matched_rule_id: rule.id})
      Ash.destroy!(rule, actor: system_actor())

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())

      # A rule deleted after the result was written must not blank the verdict.
      assert entry.verdict_label == "isolated_verified"
      assert entry.explanation == nil
    end

    test "shows each input's value and age" do
      device = device_fixture(%{})
      check = check_fixture(%{})
      input_fixture(check, "agent-a", %{position: 0, expected: "available"})
      input_fixture(check, "agent-b", %{position: 1, expected: "blocked"})

      observed = DateTime.add(DateTime.utc_now(), -120, :second)

      upsert_result(device, check, %{
        inputs: %{
          "agent-a" => snapshot("available", observed),
          "agent-b" => snapshot("blocked", observed)
        }
      })

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())
      assert [a, b] = entry.inputs

      assert a.key == "agent-a"
      assert a.value == "available"
      assert a.expected == "available"
      assert a.age == "2m ago"
      assert b.key == "agent-b"
      assert b.value == "blocked"
    end

    test "an input the evaluator recorded nothing for is unknown, not absent" do
      device = device_fixture(%{})
      check = check_fixture(%{})
      input_fixture(check, "agent-a", %{position: 0, expected: "available"})
      input_fixture(check, "agent-b", %{position: 1, expected: "blocked"})

      upsert_result(device, check, %{
        inputs: %{"agent-a" => snapshot("available", DateTime.utc_now())}
      })

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())

      # Driven by the check's inputs rather than the snapshot's keys: a silently
      # absent row is how an operator misses that a vantage point never
      # reported.
      assert [_a, b] = entry.inputs
      assert b.key == "agent-b"
      assert b.value == "unknown"
      assert b.age == "never"
    end

    test "an unknown input carries its reason" do
      device = device_fixture(%{})
      check = check_fixture(%{})
      input_fixture(check, "agent-a", %{position: 0})

      upsert_result(device, check, %{
        inputs: %{"agent-a" => snapshot("unknown", nil, reason: "no_result")}
      })

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())
      assert [a] = entry.inputs

      assert a.value == "unknown"
      assert a.reason == "no_result"
    end

    test "a stale input is marked stale and keeps its observation age" do
      device = device_fixture(%{})
      check = check_fixture(%{})
      input_fixture(check, "agent-a", %{position: 0})

      observed = DateTime.add(DateTime.utc_now(), -7200, :second)

      upsert_result(device, check, %{
        inputs: %{"agent-a" => snapshot("unknown", observed, stale: true, reason: "stale")}
      })

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())
      assert [a] = entry.inputs

      assert a.stale
      assert a.age == "2h ago"
      assert a.reason == "stale"
    end

    test "a snapshot key with no matching input is shown as removed" do
      device = device_fixture(%{})
      check = check_fixture(%{})
      input_fixture(check, "agent-a", %{position: 0})

      upsert_result(device, check, %{
        inputs: %{
          "agent-a" => snapshot("available", DateTime.utc_now()),
          "agent-gone" => snapshot("blocked", DateTime.utc_now())
        }
      })

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())

      # The input was removed after this verdict was written. Dropping the row
      # would claim the verdict did not use it.
      assert [a, gone] = entry.inputs
      refute a.removed
      assert gone.key == "agent-gone"
      assert gone.removed
      assert gone.value == "blocked"
    end

    test "a device in several checks lists each, sorted by check name" do
      device = device_fixture(%{})
      first = check_fixture(%{name: "AAA Check #{System.unique_integer([:positive])}"})
      second = check_fixture(%{name: "ZZZ Check #{System.unique_integer([:positive])}"})

      upsert_result(device, second, %{verdict: "not_isolated", status: :down})
      upsert_result(device, first, %{})

      names =
        device.uid
        |> CompositeVerdictData.load(actor: system_actor())
        |> Enum.map(& &1.check_name)

      assert names == [first.name, second.name]
    end

    test "a draft check's verdict is still shown, with its state" do
      device = device_fixture(%{})
      check = check_fixture(%{})

      upsert_result(device, check, %{})

      assert [entry] = CompositeVerdictData.load(device.uid, actor: system_actor())

      # A draft that has been previewed or was enabled and rolled back still has
      # results; hiding them would leave the page silently incomplete.
      assert entry.check_state == :draft
    end
  end
end
