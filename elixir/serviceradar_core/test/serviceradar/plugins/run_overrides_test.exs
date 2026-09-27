defmodule ServiceRadar.Plugins.RunOverridesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.RunOverrideAckIngestor
  alias ServiceRadar.Plugins.RunOverrides

  @actor %{id: "test", role: :system}

  describe "RunOverrideAckIngestor.supports?/2" do
    test "needs a host acknowledgement list and the host assignment label" do
      payload = %{
        "run_overrides_acknowledged" => ["fault-1"],
        "labels" => %{"assignment_id" => "a1"}
      }

      assert RunOverrideAckIngestor.supports?(payload, %{})
      refute RunOverrideAckIngestor.supports?(Map.delete(payload, "labels"), %{})

      refute RunOverrideAckIngestor.supports?(
               %{payload | "run_overrides_acknowledged" => []},
               %{}
             )

      refute RunOverrideAckIngestor.supports?(
               %{payload | "run_overrides_acknowledged" => [""]},
               %{}
             )
    end

    test "ingesting a result without acknowledgements does nothing" do
      assert :ok =
               RunOverrideAckIngestor.ingest(%{"labels" => %{"assignment_id" => "a1"}}, %{}, [])
    end
  end

  describe "RunOverrides.apply_action_result/3" do
    test "a result without operations applies nothing" do
      assert {:ok, 0} =
               RunOverrides.apply_action_result(%{"status" => "succeeded"}, %{}, actor: @actor)
    end

    test "operations need the assignment that ran the action" do
      payload = %{"run_overrides" => [%{"op" => "end", "id" => "fault-1"}]}

      assert {:error, :missing_plugin_assignment} =
               RunOverrides.apply_action_result(payload, %{}, actor: @actor)
    end

    test "an action whose descriptor declares no maximum cannot set overrides" do
      payload = %{
        "run_overrides" => [
          %{"op" => "set", "id" => "fault-1", "kind" => "jam", "duration_seconds" => 60},
          %{"op" => "explode", "id" => "fault-2"},
          %{"op" => "set", "kind" => "jam", "duration_seconds" => 60}
        ]
      }

      assert {:ok, 0} =
               RunOverrides.apply_action_result(
                 payload,
                 %{plugin_assignment_id: Ash.UUID.generate()},
                 actor: @actor,
                 max_override_duration_seconds: nil
               )
    end
  end

  test "encode_list/1 wraps overrides in the agent wire envelope" do
    assert %{
             "schema" => "serviceradar.plugin_run_overrides.v1",
             "overrides" => [%{"id" => "x"}]
           } = RunOverrides.encode_list([%{"id" => "x"}])
  end
end
