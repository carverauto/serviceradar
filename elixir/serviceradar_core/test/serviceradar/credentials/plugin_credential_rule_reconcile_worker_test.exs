defmodule ServiceRadar.Credentials.PluginCredentialRuleReconcileWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginCredentialRuleReconcileWorker

  defmodule FakeMaterializer do
    @moduledoc false

    def reconcile_all_for_agent("agent-fail", opts) do
      send(opts[:test_pid], {:reconcile_all, "agent-fail"})
      {:error, :boom}
    end

    def reconcile_all_for_agent(agent_uid, opts) do
      send(opts[:test_pid], {:reconcile_all, agent_uid})

      {:ok,
       %{
         rules: 2,
         resolved_inputs: 2,
         desired_assignments: 4,
         upserted: 2,
         unchanged: 2,
         disabled: 0
       }}
    end
  end

  test "reconcile_agents aggregates materializer results per agent" do
    agents = [
      %{uid: "agent-a"},
      %{"uid" => "agent-b"},
      %{uid: ""},
      %{uid: "agent-fail"}
    ]

    assert summary =
             PluginCredentialRuleReconcileWorker.reconcile_agents(agents,
               materializer: FakeMaterializer,
               test_pid: self()
             )

    assert_receive {:reconcile_all, "agent-a"}
    assert_receive {:reconcile_all, "agent-b"}
    assert_receive {:reconcile_all, "agent-fail"}

    assert summary == %{
             agents: 2,
             failed_agents: 1,
             skipped_agents: 1,
             rules: 4,
             resolved_inputs: 4,
             desired_assignments: 8,
             upserted: 4,
             unchanged: 4,
             disabled: 0,
             skips: %{}
           }
  end
end
