defmodule ServiceRadar.Infrastructure.HealthTrackerTest do
  @moduledoc """
  Tests for HealthTracker - internal health event persistence and PubSub emission.

  Verifies that:
  - State transitions create HealthEvent records in CNPG
  - PubSub events are broadcast for live UI updates
  - NATS is not required for internal health persistence

  These tests satisfy task 4.1 from the remove-nats-internal-events proposal.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Infrastructure.HealthEvent
  alias ServiceRadar.Infrastructure.HealthPubSub
  alias ServiceRadar.Infrastructure.HealthTracker

  @moduletag :database

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    old_repo_enabled = Application.get_env(:serviceradar_core, :repo_enabled)

    Application.put_env(:serviceradar_core, :repo_enabled, true)

    on_exit(fn ->
      Application.put_env(:serviceradar_core, :repo_enabled, old_repo_enabled)
    end)

    {:ok, unique_id: unique_id}
  end

  describe "record_state_change/3" do
    test "creates a HealthEvent record for agent state transition", %{
      unique_id: unique_id
    } do
      entity_id = "agent-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id,
          old_state: :connected,
          new_state: :degraded,
          reason: :high_latency,
          metadata: %{latency_ms: 500}
        )

      assert event.entity_type == :agent
      assert event.entity_id == entity_id
      assert event.old_state == :connected
      assert event.new_state == :degraded
      assert event.reason == :high_latency
      assert event.metadata["latency_ms"] == 500
      assert event.recorded_at
    end

    test "creates a HealthEvent for gateway heartbeat timeout", %{
      unique_id: unique_id
    } do
      entity_id = "gateway-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:gateway, entity_id,
          old_state: :healthy,
          new_state: :degraded,
          reason: :heartbeat_timeout
        )

      assert event.entity_type == :gateway
      assert event.entity_id == entity_id
      assert event.new_state == :degraded
      assert event.reason == :heartbeat_timeout
    end

    test "creates a HealthEvent for checker state change", %{
      unique_id: unique_id
    } do
      entity_id = "checker-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:checker, entity_id,
          old_state: :active,
          new_state: :failing,
          reason: :consecutive_failures,
          metadata: %{failure_count: 3}
        )

      assert event.entity_type == :checker
      assert event.new_state == :failing
      assert event.metadata["failure_count"] == 3
    end

    test "persisted event is queryable via timeline", %{
      unique_id: unique_id
    } do
      entity_id = "agent-timeline-#{unique_id}"

      # Record multiple state changes
      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, new_state: :connecting)

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id,
          old_state: :connecting,
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id,
          old_state: :connected,
          new_state: :degraded,
          reason: :high_latency
        )

      # Query timeline
      {:ok, events} = HealthTracker.timeline(:agent, entity_id, hours: 1)

      assert length(events) == 3
      # Most recent first
      assert hd(events).new_state == :degraded
    end

    test "records node information", %{unique_id: unique_id} do
      entity_id = "agent-node-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id,
          new_state: :connected,
          node: "node-1@serviceradar.local"
        )

      assert event.node == "node-1@serviceradar.local"
    end

    test "defaults node to current node", %{unique_id: unique_id} do
      entity_id = "agent-default-node-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id, new_state: :connected)

      assert event.node == to_string(node())
    end
  end

  describe "PubSub emission" do
    test "broadcasts health event on state change", %{
      unique_id: unique_id
    } do
      entity_id = "agent-pubsub-#{unique_id}"
      topic = HealthPubSub.topic()

      # Subscribe to the topic
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, topic)

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id,
          old_state: :connected,
          new_state: :degraded,
          reason: :high_latency
        )

      # Assert we received the broadcast
      assert_receive {:health_event, received_event}, 1000
      assert received_event.id == event.id
      assert received_event.entity_type == :agent
      assert received_event.new_state == :degraded
    end

    test "does not broadcast when broadcast: false", %{
      unique_id: unique_id
    } do
      entity_id = "agent-no-broadcast-#{unique_id}"
      topic = HealthPubSub.topic()

      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, topic)

      {:ok, _event} =
        HealthTracker.record_state_change(:agent, entity_id,
          new_state: :connected,
          broadcast: false
        )

      # Should NOT receive a broadcast
      refute_receive {:health_event, _}, 100
    end
  end

  describe "current_status/2" do
    test "returns the most recent health event for an entity", %{
      unique_id: unique_id
    } do
      entity_id = "agent-status-#{unique_id}"

      # Record several events
      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, new_state: :connecting)

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id,
          old_state: :connecting,
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id,
          old_state: :connected,
          new_state: :degraded
        )

      # Get current status
      {:ok, current} = HealthTracker.current_status(:agent, entity_id)

      assert current.new_state == :degraded
    end

    test "returns nil for entity with no events", %{unique_id: unique_id} do
      entity_id = "agent-no-events-#{unique_id}"

      {:ok, current} = HealthTracker.current_status(:agent, entity_id)

      assert current == nil
    end
  end

  describe "record_health_check/3" do
    test "records state change when health status changes", %{
      unique_id: unique_id
    } do
      entity_id = "datasvc-#{unique_id}"

      # First health check - healthy
      {:ok, event} =
        HealthTracker.record_health_check(:custom, entity_id,
          healthy: true,
          latency_ms: 50
        )

      assert event.new_state == :healthy

      # Second health check - unhealthy
      {:ok, event2} =
        HealthTracker.record_health_check(:custom, entity_id,
          healthy: false,
          latency_ms: 5000,
          error: "timeout"
        )

      assert event2.new_state == :unhealthy
      assert event2.old_state == :healthy
    end

    test "returns :unchanged when health status is the same", %{
      unique_id: unique_id
    } do
      entity_id = "datasvc-unchanged-#{unique_id}"

      # First health check
      {:ok, _} =
        HealthTracker.record_health_check(:custom, entity_id, healthy: true)

      # Second health check - same status
      result =
        HealthTracker.record_health_check(:custom, entity_id, healthy: true)

      assert result == {:ok, :unchanged}
    end
  end

  describe "heartbeat/3" do
    test "records first heartbeat as new event", %{unique_id: unique_id} do
      entity_id = "core-#{unique_id}"

      {:ok, event} =
        HealthTracker.heartbeat(:core, entity_id,
          healthy: true,
          metadata: %{version: "1.0.0"}
        )

      assert event.new_state == :healthy
      assert event.reason == :heartbeat
      assert event.metadata["version"] == "1.0.0"
    end

    test "returns :unchanged for subsequent heartbeats with same state", %{
      unique_id: unique_id
    } do
      entity_id = "core-unchanged-#{unique_id}"

      # First heartbeat
      {:ok, _} = HealthTracker.heartbeat(:core, entity_id, healthy: true)

      # Second heartbeat - same state
      result = HealthTracker.heartbeat(:core, entity_id, healthy: true)

      assert result == {:ok, :unchanged}
    end

    test "records event when health state changes", %{unique_id: unique_id} do
      entity_id = "core-change-#{unique_id}"

      # First heartbeat - healthy
      {:ok, _} = HealthTracker.heartbeat(:core, entity_id, healthy: true)

      # Second heartbeat - degraded
      {:ok, event} = HealthTracker.heartbeat(:core, entity_id, healthy: false)

      assert event.new_state == :degraded
      assert event.old_state == :healthy
    end
  end

  describe "summary/0" do
    test "returns health summary grouped by entity type and state", %{
      unique_id: unique_id
    } do
      # Create events for different entity types
      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-sum-1-#{unique_id}",
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-sum-2-#{unique_id}",
          new_state: :degraded
        )

      {:ok, _} =
        HealthTracker.record_state_change(:gateway, "gateway-sum-1-#{unique_id}",
          new_state: :healthy
        )

      {:ok, summary} = HealthTracker.summary()

      assert is_map(summary)
      assert Map.has_key?(summary, :agent)
      assert Map.has_key?(summary, :gateway)
      assert summary[:agent][:total] >= 2
    end
  end

  describe "recent_events/1" do
    test "returns recent events across all entities", %{unique_id: unique_id} do
      # Create some events
      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-recent-#{unique_id}",
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:gateway, "gateway-recent-#{unique_id}",
          new_state: :healthy
        )

      {:ok, events} = HealthTracker.recent_events(limit: 10)

      assert length(events) >= 2
      assert Enum.all?(events, &is_struct(&1, HealthEvent))
    end

    test "can filter by entity_type", %{unique_id: unique_id} do
      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-filter-#{unique_id}",
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:gateway, "gateway-filter-#{unique_id}",
          new_state: :healthy
        )

      {:ok, events} = HealthTracker.recent_events(entity_type: :agent, limit: 100)

      assert Enum.all?(events, &(&1.entity_type == :agent))
    end
  end
end
