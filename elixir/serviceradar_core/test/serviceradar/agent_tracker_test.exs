defmodule ServiceRadar.AgentTrackerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.AgentTracker
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "preserves runtime metadata across subsequent status updates" do
    unique_id = System.unique_integer([:positive])
    agent_id = "agent-tracker-#{unique_id}"

    on_exit(fn ->
      AgentTracker.remove_agent(agent_id)
    end)

    :ok =
      AgentTracker.track_agent(agent_id, %{
        version: "1.2.10",
        hostname: "dusk01",
        os: "linux",
        arch: "amd64",
        gateway_id: "gateway-demo",
        deployment_type: "bare-metal",
        partition: "default",
        source_ip: "192.168.2.22"
      })

    :ok =
      AgentTracker.track_agent(agent_id, %{
        service_count: 3,
        partition: "default",
        source_ip: "192.168.2.22"
      })

    agent = AgentTracker.get_agent(agent_id)

    assert agent.agent_id == agent_id
    assert agent.service_count == 3
    assert agent.version == "1.2.10"
    assert agent.hostname == "dusk01"
    assert agent.os == "linux"
    assert agent.arch == "amd64"
    assert agent.gateway_id == "gateway-demo"
    assert agent.deployment_type == "bare-metal"
    assert agent.source_ip == "192.168.2.22"
    assert %DateTime{} = agent.last_seen
    assert is_integer(agent.last_seen_mono)
  end

  test "counts refused statuses per source family and reports them with the agent" do
    agent_id = "agent-tracker-refused-#{System.unique_integer([:positive])}"
    on_exit(fn -> AgentTracker.remove_agent(agent_id) end)

    :ok = AgentTracker.track_agent(agent_id, %{version: "1.4.0"})

    assert :first = AgentTracker.record_refused_statuses(agent_id, %{"results" => 2})

    assert :repeat =
             AgentTracker.record_refused_statuses(agent_id, %{
               "results" => 1,
               "sysmon-metrics" => 4
             })

    # A later heartbeat rewrites the agent's info map and must not reset the counts.
    :ok = AgentTracker.track_agent(agent_id, %{service_count: 1})

    agent = AgentTracker.get_agent(agent_id)
    assert agent.refused_statuses == %{"results" => 3, "sysmon-metrics" => 4}
    assert %DateTime{} = agent.last_refused_at

    assert %{refused_statuses: %{"results" => 3}} =
             Enum.find(AgentTracker.list_agents(), &(&1.agent_id == agent_id))

    :ok = AgentTracker.remove_agent(agent_id)
    assert :first = AgentTracker.record_refused_statuses(agent_id, %{"results" => 1})
  end
end
