defmodule ServiceRadar.AgentTrackerTest do
  use ExUnit.Case, async: false

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
end
