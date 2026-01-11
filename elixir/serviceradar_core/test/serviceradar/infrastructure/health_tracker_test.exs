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

  alias ServiceRadar.Infrastructure.{HealthEvent, HealthTracker, HealthPubSub}

  @moduletag :database

  setup_all do
    tenant = ServiceRadar.TestSupport.create_tenant_schema!("health-tracker-test")

    on_exit(fn ->
      ServiceRadar.TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    {:ok, tenant_id: tenant.tenant_id, tenant_slug: tenant.tenant_slug}
  end

  setup %{tenant_id: tenant_id, tenant_slug: tenant_slug} do
    unique_id = :erlang.unique_integer([:positive])

    {:ok, tenant_id: tenant_id, tenant_slug: tenant_slug, unique_id: unique_id}
  end

  describe "record_state_change/4" do
    test "creates a HealthEvent record for agent state transition", %{
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "agent-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
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
      assert event.tenant_id == tenant_id
      assert event.recorded_at != nil
    end

    test "creates a HealthEvent for gateway heartbeat timeout", %{
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "gateway-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:gateway, entity_id, tenant_slug,
          old_state: :healthy,
          new_state: :degraded,
          reason: :heartbeat_timeout
        )

      assert event.entity_type == :gateway
      assert event.entity_id == entity_id
      assert event.new_state == :degraded
      assert event.reason == :heartbeat_timeout
      assert event.tenant_id == tenant_id
    end

    test "creates a HealthEvent for checker state change", %{
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "checker-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:checker, entity_id, tenant_slug,
          old_state: :active,
          new_state: :failing,
          reason: :consecutive_failures,
          metadata: %{failure_count: 3}
        )

      assert event.entity_type == :checker
      assert event.new_state == :failing
      assert event.metadata["failure_count"] == 3
      assert event.tenant_id == tenant_id
    end

    test "persisted event is queryable via timeline", %{
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "agent-timeline-#{unique_id}"

      # Record multiple state changes
      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          new_state: :connecting
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          old_state: :connecting,
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          old_state: :connected,
          new_state: :degraded,
          reason: :high_latency
        )

      # Query timeline
      {:ok, events} = HealthTracker.timeline(:agent, entity_id, tenant_slug, hours: 1)

      assert length(events) == 3
      # Most recent first
      assert hd(events).new_state == :degraded
    end

    test "records node information", %{tenant_slug: tenant_slug, unique_id: unique_id} do
      entity_id = "agent-node-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          new_state: :connected,
          node: "node-1@serviceradar.local"
        )

      assert event.node == "node-1@serviceradar.local"
    end

    test "defaults node to current node", %{tenant_slug: tenant_slug, unique_id: unique_id} do
      entity_id = "agent-default-node-#{unique_id}"

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          new_state: :connected
        )

      assert event.node == to_string(node())
    end
  end

  describe "PubSub emission" do
    test "broadcasts health event on state change", %{
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "agent-pubsub-#{unique_id}"
      topic = HealthPubSub.topic(tenant_id)

      # Subscribe to the topic
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, topic)

      {:ok, event} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
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
      tenant_id: tenant_id,
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "agent-no-broadcast-#{unique_id}"
      topic = HealthPubSub.topic(tenant_id)

      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, topic)

      {:ok, _event} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          new_state: :connected,
          broadcast: false
        )

      # Should NOT receive a broadcast
      refute_receive {:health_event, _}, 100
    end
  end

  describe "current_status/3" do
    test "returns the most recent health event for an entity", %{
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "agent-status-#{unique_id}"

      # Record several events
      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          new_state: :connecting
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          old_state: :connecting,
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, entity_id, tenant_slug,
          old_state: :connected,
          new_state: :degraded
        )

      # Get current status
      {:ok, current} = HealthTracker.current_status(:agent, entity_id, tenant_slug)

      assert current.new_state == :degraded
    end

    test "returns nil for entity with no events", %{tenant_slug: tenant_slug, unique_id: unique_id} do
      entity_id = "agent-no-events-#{unique_id}"

      {:ok, current} = HealthTracker.current_status(:agent, entity_id, tenant_slug)

      assert current == nil
    end
  end

  describe "record_health_check/4" do
    test "records state change when health status changes", %{
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "datasvc-#{unique_id}"

      # First health check - healthy
      {:ok, event} =
        HealthTracker.record_health_check(:custom, entity_id, tenant_slug,
          healthy: true,
          latency_ms: 50
        )

      assert event.new_state == :healthy

      # Second health check - unhealthy
      {:ok, event2} =
        HealthTracker.record_health_check(:custom, entity_id, tenant_slug,
          healthy: false,
          latency_ms: 5000,
          error: "timeout"
        )

      assert event2.new_state == :unhealthy
      assert event2.old_state == :healthy
    end

    test "returns :unchanged when health status is the same", %{
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "datasvc-unchanged-#{unique_id}"

      # First health check
      {:ok, _} =
        HealthTracker.record_health_check(:custom, entity_id, tenant_slug,
          healthy: true
        )

      # Second health check - same status
      result =
        HealthTracker.record_health_check(:custom, entity_id, tenant_slug,
          healthy: true
        )

      assert result == {:ok, :unchanged}
    end
  end

  describe "heartbeat/4" do
    test "records first heartbeat as new event", %{tenant_slug: tenant_slug, unique_id: unique_id} do
      entity_id = "core-#{unique_id}"

      {:ok, event} =
        HealthTracker.heartbeat(:core, entity_id, tenant_slug,
          healthy: true,
          metadata: %{version: "1.0.0"}
        )

      assert event.new_state == :healthy
      assert event.reason == :heartbeat
      assert event.metadata["version"] == "1.0.0"
    end

    test "returns :unchanged for subsequent heartbeats with same state", %{
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      entity_id = "core-unchanged-#{unique_id}"

      # First heartbeat
      {:ok, _} = HealthTracker.heartbeat(:core, entity_id, tenant_slug, healthy: true)

      # Second heartbeat - same state
      result = HealthTracker.heartbeat(:core, entity_id, tenant_slug, healthy: true)

      assert result == {:ok, :unchanged}
    end

    test "records event when health state changes", %{tenant_slug: tenant_slug, unique_id: unique_id} do
      entity_id = "core-change-#{unique_id}"

      # First heartbeat - healthy
      {:ok, _} = HealthTracker.heartbeat(:core, entity_id, tenant_slug, healthy: true)

      # Second heartbeat - degraded
      {:ok, event} = HealthTracker.heartbeat(:core, entity_id, tenant_slug, healthy: false)

      assert event.new_state == :degraded
      assert event.old_state == :healthy
    end
  end

  describe "summary/1" do
    test "returns health summary grouped by entity type and state", %{
      tenant_slug: tenant_slug,
      unique_id: unique_id
    } do
      # Create events for different entity types
      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-sum-1-#{unique_id}", tenant_slug,
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-sum-2-#{unique_id}", tenant_slug,
          new_state: :degraded
        )

      {:ok, _} =
        HealthTracker.record_state_change(:gateway, "gateway-sum-1-#{unique_id}", tenant_slug,
          new_state: :healthy
        )

      {:ok, summary} = HealthTracker.summary(tenant_slug)

      assert is_map(summary)
      assert Map.has_key?(summary, :agent)
      assert Map.has_key?(summary, :gateway)
      assert summary[:agent][:total] >= 2
    end
  end

  describe "recent_events/2" do
    test "returns recent events across all entities", %{tenant_slug: tenant_slug, unique_id: unique_id} do
      # Create some events
      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-recent-#{unique_id}", tenant_slug,
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:gateway, "gateway-recent-#{unique_id}", tenant_slug,
          new_state: :healthy
        )

      {:ok, events} = HealthTracker.recent_events(tenant_slug, limit: 10)

      assert length(events) >= 2
      assert Enum.all?(events, &is_struct(&1, HealthEvent))
    end

    test "can filter by entity_type", %{tenant_slug: tenant_slug, unique_id: unique_id} do
      {:ok, _} =
        HealthTracker.record_state_change(:agent, "agent-filter-#{unique_id}", tenant_slug,
          new_state: :connected
        )

      {:ok, _} =
        HealthTracker.record_state_change(:gateway, "gateway-filter-#{unique_id}", tenant_slug,
          new_state: :healthy
        )

      {:ok, events} = HealthTracker.recent_events(tenant_slug, entity_type: :agent, limit: 100)

      assert Enum.all?(events, &(&1.entity_type == :agent))
    end
  end

  describe "error handling" do
    test "returns error for invalid tenant schema", %{unique_id: unique_id} do
      entity_id = "agent-invalid-#{unique_id}"
      invalid_tenant = "non-existent-tenant-id"

      result =
        HealthTracker.record_state_change(:agent, entity_id, invalid_tenant,
          new_state: :connected
        )

      assert {:error, :tenant_schema_not_found} = result
    end
  end
end
