defmodule ServiceRadar.Credentials.ProxmoxCredentialRuleReconcileWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.ProxmoxCredentialRuleReconcileWorker

  defmodule FakeMaterializer do
    @moduledoc false

    def reconcile_proxmox_inventory_for_agent("agent-fail", opts) do
      send(opts[:test_pid], {:reconcile, "agent-fail"})
      {:error, :boom}
    end

    def reconcile_proxmox_inventory_for_agent(agent_uid, opts) do
      send(opts[:test_pid], {:reconcile, agent_uid})

      {:ok,
       %{
         rules: 1,
         resolved_inputs: 1,
         desired_assignments: 2,
         upserted: 1,
         unchanged: 1,
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
             ProxmoxCredentialRuleReconcileWorker.reconcile_agents(agents,
               materializer: FakeMaterializer,
               test_pid: self()
             )

    assert_receive {:reconcile, "agent-a"}
    assert_receive {:reconcile, "agent-b"}
    assert_receive {:reconcile, "agent-fail"}

    assert summary == %{
             agents: 2,
             failed_agents: 1,
             skipped_agents: 1,
             rules: 2,
             resolved_inputs: 2,
             desired_assignments: 4,
             upserted: 2,
             unchanged: 2,
             disabled: 0
           }
  end
end
