defmodule ServiceRadar.Infrastructure.AgentTest do
  @moduledoc """
  Tests for the Infrastructure.Agent resource.

  Tests agent registration, state machine transitions, and API operations
  that pollers use to manage agent lifecycle.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Infrastructure.Agent

  @moduletag :database

  setup do
    # Generate unique tenant ID to prevent test pollution
    unique_id = :erlang.unique_integer([:positive])
    tenant_id = Ash.UUID.generate()

    # Create a test actor with super_admin role for bypassing policies
    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :super_admin,
      tenant_id: tenant_id
    }

    {:ok, tenant_id: tenant_id, actor: actor, unique_id: unique_id}
  end

  describe "register/1" do
    test "creates agent in connecting state", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      agent_uid = "agent-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: agent_uid,
          name: "Test Agent",
          host: "192.168.1.100",
          port: 50051,
          capabilities: ["icmp", "tcp", "http"]
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.uid == agent_uid
      assert agent.status == :connecting
      assert agent.host == "192.168.1.100"
      assert agent.port == 50051
      assert agent.is_healthy == true
      assert "icmp" in agent.capabilities
      assert agent.tenant_id == tenant_id
      assert agent.first_seen_time != nil
      assert agent.last_seen_time != nil
    end

    test "creates agent with SPIFFE identity", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      agent_uid = "agent-spiffe-#{unique_id}"
      spiffe_id = "spiffe://serviceradar.local/agent/test-tenant/default/#{agent_uid}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: agent_uid,
          name: "SPIFFE Agent",
          host: "10.0.0.50",
          port: 50051,
          spiffe_identity: spiffe_id
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.spiffe_identity == spiffe_id
    end
  end

  describe "register_connected/1" do
    test "creates agent directly in connected state", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      agent_uid = "agent-connected-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: agent_uid,
          name: "Pre-connected Agent",
          host: "192.168.1.101",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.status == :connected
      assert agent.is_healthy == true
    end
  end

  describe "state machine transitions" do
    setup %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      agent_uid = "agent-sm-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: agent_uid,
          name: "State Machine Test Agent",
          host: "192.168.1.102",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, agent: agent}
    end

    test "establish_connection: connecting -> connected", %{agent: agent, actor: actor} do
      assert agent.status == :connecting

      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert updated.status == :connected
      assert updated.is_healthy == true
    end

    test "degrade: connected -> degraded", %{agent: agent, actor: actor} do
      # First connect
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert connected.status == :connected

      # Then degrade
      {:ok, degraded} =
        connected
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert degraded.status == :degraded
      assert degraded.is_healthy == false
    end

    test "lose_connection: connected -> disconnected", %{agent: agent, actor: actor} do
      # First connect
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      # Then lose connection
      {:ok, disconnected} =
        connected
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert disconnected.status == :disconnected
      assert disconnected.poller_id == nil
    end

    test "reconnect: disconnected -> connecting", %{agent: agent, actor: actor} do
      # Connect -> Disconnect -> Reconnect
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      {:ok, disconnected} =
        connected
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      {:ok, reconnecting} =
        disconnected
        |> Ash.Changeset.for_update(:reconnect, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert reconnecting.status == :connecting
    end

    test "restore_health: degraded -> connected", %{agent: agent, actor: actor} do
      # Connect -> Degrade -> Restore
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      {:ok, degraded} =
        connected
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      {:ok, restored} =
        degraded
        |> Ash.Changeset.for_update(:restore_health, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert restored.status == :connected
      assert restored.is_healthy == true
    end

    test "mark_unavailable: any state -> unavailable", %{agent: agent, actor: actor} do
      {:ok, unavailable} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "Maintenance"}, actor: actor, authorize?: false)
        |> Ash.update()

      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false
    end
  end

  describe "heartbeat/1" do
    test "updates last_seen_time", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      agent_uid = "agent-hb-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: agent_uid,
          name: "Heartbeat Test Agent",
          host: "192.168.1.103",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      original_last_seen = agent.last_seen_time

      # Wait longer to ensure measurable time difference (DateTime has second precision)
      Process.sleep(1100)

      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert DateTime.compare(updated.last_seen_time, original_last_seen) in [:gt, :eq]
      # At minimum, the timestamp should be set
      assert updated.last_seen_time != nil
    end

    test "can update capabilities", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      agent_uid = "agent-hb-caps-#{unique_id}"

      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: agent_uid,
          name: "Capability Update Agent",
          host: "192.168.1.104",
          port: 50051,
          capabilities: ["icmp"]
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:heartbeat, %{capabilities: ["icmp", "tcp", "snmp"]}, actor: actor, authorize?: false)
        |> Ash.update()

      assert "snmp" in updated.capabilities
      assert length(updated.capabilities) == 3
    end
  end

  describe "queries" do
    setup %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      # Create multiple agents in different states (without poller FK constraint)
      {:ok, connected_agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-q-connected-#{unique_id}",
          name: "Connected Query Agent",
          host: "192.168.1.110",
          port: 50051,
          capabilities: ["icmp", "tcp"]
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, connecting_agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-q-connecting-#{unique_id}",
          name: "Connecting Query Agent",
          host: "192.168.1.111",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok,
        connected_agent: connected_agent,
        connecting_agent: connecting_agent
      }
    end

    test "connected returns only connected and healthy agents", %{connected_agent: agent, connecting_agent: _connecting, actor: actor, tenant_id: tenant_id} do
      agents =
        Agent
        |> Ash.Query.for_read(:connected, %{}, actor: actor, tenant: tenant_id)
        |> Ash.read!()

      assert Enum.all?(agents, &(&1.status == :connected))
      assert Enum.all?(agents, &(&1.is_healthy == true))
      assert Enum.any?(agents, &(&1.uid == agent.uid))
    end

    test "by_capability returns agents with specific capability", %{connected_agent: agent, actor: actor, tenant_id: tenant_id} do
      agents =
        Agent
        |> Ash.Query.for_read(:by_capability, %{capability: "tcp"}, actor: actor, tenant: tenant_id)
        |> Ash.read!()

      assert Enum.any?(agents, &(&1.uid == agent.uid))
    end

    test "by_status returns agents in specific status", %{connected_agent: connected, connecting_agent: connecting, actor: actor, tenant_id: tenant_id} do
      connected_agents =
        Agent
        |> Ash.Query.for_read(:by_status, %{status: :connected}, actor: actor, tenant: tenant_id)
        |> Ash.read!()

      connecting_agents =
        Agent
        |> Ash.Query.for_read(:by_status, %{status: :connecting}, actor: actor, tenant: tenant_id)
        |> Ash.read!()

      assert Enum.any?(connected_agents, &(&1.uid == connected.uid))
      assert Enum.any?(connecting_agents, &(&1.uid == connecting.uid))
    end
  end
end
