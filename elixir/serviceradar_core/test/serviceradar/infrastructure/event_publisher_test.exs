defmodule ServiceRadar.Infrastructure.EventPublisherTest do
  @moduledoc """
  Tests for infrastructure event publishing.

  These tests inject the internal-log publisher so their result is independent
  of the integration test application's database and NATS state.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Infrastructure.EventPublisher

  describe "publish_state_change/1" do
    test "builds correct event structure" do
      event_opts = [
        entity_type: :gateway,
        entity_id: "gateway-123",
        partition_id: "partition-uuid",
        old_state: :healthy,
        new_state: :degraded,
        reason: :heartbeat_timeout,
        metadata: %{custom: "data"},
        log_publisher: disconnected_publisher(self())
      ]

      result = EventPublisher.publish_state_change(event_opts)

      assert {:error, {:nats_not_connected, :test}} = result

      assert_receive {:publish_internal_log, "infrastructure.state_change", payload}
      assert payload.log_name == "infra.state_change"
      assert payload.unmapped["entity_id"] == "gateway-123"
      assert payload.unmapped["custom"] == "data"
    end

    test "requires all mandatory fields" do
      # Missing entity_id should raise
      assert_raise KeyError, fn ->
        EventPublisher.publish_state_change(
          entity_type: :gateway,
          # missing entity_id
          old_state: :healthy,
          new_state: :degraded
        )
      end
    end
  end

  describe "entity_types/0" do
    test "returns supported entity types" do
      types = EventPublisher.entity_types()

      assert :gateway in types
      assert :agent in types
      assert :checker in types
      assert :collector in types
    end
  end

  describe "event_types/0" do
    test "returns supported event types" do
      types = EventPublisher.event_types()

      assert :state_change in types
      assert :registered in types
      assert :deregistered in types
      assert :health_change in types
      assert :heartbeat_timeout in types
    end
  end

  describe "publish_registered/4" do
    test "builds correct event for registration" do
      result =
        EventPublisher.publish_registered(
          :gateway,
          "gateway-123",
          initial_state: :healthy,
          partition_id: "partition-uuid",
          log_publisher: disconnected_publisher(self())
        )

      assert {:error, {:nats_not_connected, :test}} = result
      assert_receive {:publish_internal_log, "infrastructure.registered", _payload}
    end
  end

  describe "publish_deregistered/4" do
    test "builds correct event for deregistration" do
      result =
        EventPublisher.publish_deregistered(
          :agent,
          "agent-456",
          final_state: :disconnected,
          reason: "shutdown",
          log_publisher: disconnected_publisher(self())
        )

      assert {:error, {:nats_not_connected, :test}} = result
      assert_receive {:publish_internal_log, "infrastructure.deregistered", _payload}
    end
  end

  describe "publish_heartbeat_timeout/4" do
    test "builds correct event for heartbeat timeout" do
      result =
        EventPublisher.publish_heartbeat_timeout(
          :gateway,
          "gateway-123",
          last_seen: DateTime.utc_now(),
          current_state: :healthy,
          log_publisher: disconnected_publisher(self())
        )

      assert {:error, {:nats_not_connected, :test}} = result
      assert_receive {:publish_internal_log, "infrastructure.heartbeat_timeout", _payload}
    end
  end

  describe "publish_health_change/5" do
    test "builds correct event for health change" do
      result =
        EventPublisher.publish_health_change(
          :checker,
          "checker-789",
          false,
          reason: "consecutive_failures",
          log_publisher: disconnected_publisher(self())
        )

      assert {:error, {:nats_not_connected, :test}} = result
      assert_receive {:publish_internal_log, "infrastructure.health_change", _payload}
    end
  end

  defp disconnected_publisher(test_pid) do
    fn subject, payload ->
      send(test_pid, {:publish_internal_log, subject, payload})
      {:error, {:nats_not_connected, :test}}
    end
  end
end
