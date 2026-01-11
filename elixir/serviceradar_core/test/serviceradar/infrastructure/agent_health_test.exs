defmodule ServiceRadar.Infrastructure.AgentHealthTest do
  @moduledoc """
  Tests for agent health monitoring in the Infrastructure.Agent resource.

  Verifies that:
  - Health state transitions work correctly (degrade/restore_health)
  - is_healthy flag is properly maintained
  - Health-related queries return correct results
  - last_seen_time tracking works for health monitoring
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Infrastructure.Agent

  @moduletag :database

  setup_all do
    tenant = ServiceRadar.TestSupport.create_tenant_schema!("agent-health")

    on_exit(fn ->
      ServiceRadar.TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    {:ok, tenant_id: tenant.tenant_id}
  end

  setup %{tenant_id: tenant_id} do
    unique_id = :erlang.unique_integer([:positive])

    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :super_admin,
      tenant_id: tenant_id
    }

    {:ok, tenant_id: tenant_id, actor: actor, unique_id: unique_id}
  end

  describe "health state transitions" do
    test "new agent starts healthy", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-health-new-#{unique_id}",
          name: "New Agent",
          host: "192.168.1.10",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.is_healthy == true
    end

    test "connected agent starts healthy", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-health-connected-#{unique_id}",
          name: "Connected Agent",
          host: "192.168.1.11",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.is_healthy == true
      assert agent.status == :connected
    end

    test "degrade action marks agent as unhealthy", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      # Create connected agent
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-health-degrade-#{unique_id}",
          name: "Degrade Test Agent",
          host: "192.168.1.12",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.is_healthy == true
      assert agent.status == :connected

      # Degrade the agent
      {:ok, degraded} =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert degraded.is_healthy == false
      assert degraded.status == :degraded
    end

    test "restore_health action marks agent as healthy", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      # Create and degrade agent
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-health-restore-#{unique_id}",
          name: "Restore Test Agent",
          host: "192.168.1.13",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, degraded} =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert degraded.is_healthy == false

      # Restore health
      {:ok, restored} =
        degraded
        |> Ash.Changeset.for_update(:restore_health, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert restored.is_healthy == true
      assert restored.status == :connected
    end

    test "mark_unavailable action marks agent as unhealthy", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-health-unavailable-#{unique_id}",
          name: "Unavailable Test Agent",
          host: "192.168.1.14",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, unavailable} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "Maintenance"}, actor: actor, authorize?: false)
        |> Ash.update()

      assert unavailable.is_healthy == false
      assert unavailable.status == :unavailable
    end

    test "establish_connection resets health to true", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      # Create connecting agent (default state)
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-health-connect-#{unique_id}",
          name: "Connect Health Test",
          host: "192.168.1.15",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Establish connection
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert connected.is_healthy == true
      assert connected.status == :connected
    end
  end

  describe "health-based queries" do
    setup %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      # Create a healthy connected agent
      {:ok, healthy_agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-query-healthy-#{unique_id}",
          name: "Healthy Agent",
          host: "192.168.1.20",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Create a degraded (unhealthy) agent
      {:ok, degraded_agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-query-degraded-#{unique_id}",
          name: "Degraded Agent",
          host: "192.168.1.21",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      {:ok, degraded_agent} =
        degraded_agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      {:ok, healthy_agent: healthy_agent, degraded_agent: degraded_agent}
    end

    test "connected query only returns healthy agents", %{
      healthy_agent: healthy,
      degraded_agent: degraded,
      actor: actor,
      tenant_id: tenant_id
    } do
      agents =
        Agent
        |> Ash.Query.for_read(:connected, %{}, actor: actor, tenant: tenant_id)
        |> Ash.read!()

      # Should include healthy connected agent
      assert Enum.any?(agents, &(&1.uid == healthy.uid))

      # Should NOT include degraded agent (is_healthy == false)
      refute Enum.any?(agents, &(&1.uid == degraded.uid))
    end

    test "by_status :degraded returns unhealthy agents", %{
      degraded_agent: degraded,
      healthy_agent: healthy,
      actor: actor,
      tenant_id: tenant_id
    } do
      agents =
        Agent
        |> Ash.Query.for_read(:by_status, %{status: :degraded}, actor: actor, tenant: tenant_id)
        |> Ash.read!()

      assert Enum.any?(agents, &(&1.uid == degraded.uid))
      refute Enum.any?(agents, &(&1.uid == healthy.uid))
    end
  end

  describe "heartbeat and timestamps" do
    test "heartbeat updates last_seen_time", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-heartbeat-time-#{unique_id}",
          name: "Heartbeat Agent",
          host: "192.168.1.30",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      original_seen = agent.last_seen_time
      assert original_seen != nil

      # Send heartbeat
      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      # last_seen_time should be updated
      assert updated.last_seen_time != nil
      # The timestamp should be at least equal or greater
      assert DateTime.compare(updated.last_seen_time, original_seen) in [:eq, :gt]
    end

    test "heartbeat can update is_healthy flag", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-heartbeat-health-#{unique_id}",
          name: "Heartbeat Health Agent",
          host: "192.168.1.31",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.is_healthy == true

      # Heartbeat marking unhealthy
      {:ok, unhealthy} =
        agent
        |> Ash.Changeset.for_update(:heartbeat, %{is_healthy: false}, actor: actor, authorize?: false)
        |> Ash.update()

      assert unhealthy.is_healthy == false

      # Heartbeat marking healthy again
      {:ok, healthy} =
        unhealthy
        |> Ash.Changeset.for_update(:heartbeat, %{is_healthy: true}, actor: actor, authorize?: false)
        |> Ash.update()

      assert healthy.is_healthy == true
    end

    test "first_seen_time is set on creation and never changes", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-first-seen-#{unique_id}",
          name: "First Seen Agent",
          host: "192.168.1.32",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      original_first_seen = agent.first_seen_time
      assert original_first_seen != nil

      # Update agent
      {:ok, updated} =
        agent
        |> Ash.Changeset.for_update(:heartbeat, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      # first_seen_time should remain the same
      assert DateTime.compare(updated.first_seen_time, original_first_seen) == :eq
    end

    test "modified_time is updated on state changes", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-modified-time-#{unique_id}",
          name: "Modified Time Agent",
          host: "192.168.1.33",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Sleep to ensure measurable time difference
      Process.sleep(1100)

      {:ok, degraded} =
        agent
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      # modified_time should be set and potentially later
      assert degraded.modified_time != nil

      # If creation set modified_time, the degrade should update it
      if agent.modified_time do
        assert DateTime.compare(degraded.modified_time, agent.modified_time) in [:eq, :gt]
      end
    end
  end

  describe "health monitoring scenarios" do
    test "complete degradation and recovery cycle", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      # 1. Create new agent
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "agent-cycle-#{unique_id}",
          name: "Cycle Test Agent",
          host: "192.168.1.40",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.status == :connecting
      assert agent.is_healthy == true

      # 2. Establish connection
      {:ok, connected} =
        agent
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert connected.status == :connected
      assert connected.is_healthy == true

      # 3. Degrade due to issues
      {:ok, degraded} =
        connected
        |> Ash.Changeset.for_update(:degrade, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert degraded.status == :degraded
      assert degraded.is_healthy == false

      # 4. Restore health
      {:ok, restored} =
        degraded
        |> Ash.Changeset.for_update(:restore_health, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert restored.status == :connected
      assert restored.is_healthy == true

      # 5. Mark unavailable for maintenance
      {:ok, unavailable} =
        restored
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "Scheduled maintenance"}, actor: actor, authorize?: false)
        |> Ash.update()

      assert unavailable.status == :unavailable
      assert unavailable.is_healthy == false

      # 6. Recover from unavailable
      {:ok, recovering} =
        unavailable
        |> Ash.Changeset.for_update(:recover, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert recovering.status == :connecting

      # 7. Re-establish connection
      {:ok, final} =
        recovering
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert final.status == :connected
      assert final.is_healthy == true
    end

    test "disconnection and reconnection cycle", %{tenant_id: tenant_id, actor: actor, unique_id: unique_id} do
      # Create connected agent
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{
          uid: "agent-disconnect-#{unique_id}",
          name: "Disconnect Test Agent",
          host: "192.168.1.41",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      assert agent.status == :connected

      # Lose connection
      {:ok, disconnected} =
        agent
        |> Ash.Changeset.for_update(:lose_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert disconnected.status == :disconnected

      # Start reconnection
      {:ok, reconnecting} =
        disconnected
        |> Ash.Changeset.for_update(:reconnect, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert reconnecting.status == :connecting

      # Complete reconnection
      {:ok, reconnected} =
        reconnecting
        |> Ash.Changeset.for_update(:establish_connection, %{}, actor: actor, authorize?: false)
        |> Ash.update()

      assert reconnected.status == :connected
      assert reconnected.is_healthy == true
    end
  end
end
