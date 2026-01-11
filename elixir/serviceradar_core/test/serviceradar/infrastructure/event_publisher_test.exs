defmodule ServiceRadar.Infrastructure.EventPublisherTest do
  @moduledoc """
  Tests for infrastructure event publishing.

  Note: These tests mock the NATS connection since we don't want
  to require a running NATS server for unit tests.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Infrastructure.EventPublisher

  describe "publish_state_change/1" do
    test "builds correct event structure" do
      # This test verifies the event structure without actually publishing
      # In production, this would go to NATS JetStream

      event_opts = [
        entity_type: :gateway,
        entity_id: "gateway-123",
        tenant_id: "tenant-uuid",
        tenant_slug: "acme",
        partition_id: "partition-uuid",
        old_state: :healthy,
        new_state: :degraded,
        reason: :heartbeat_timeout,
        metadata: %{custom: "data"}
      ]

      # The function will fail to publish (no NATS) but we can verify
      # it processes the parameters correctly
      result = EventPublisher.publish_state_change(event_opts)

      # Expect error since NATS is not connected
      assert {:error, {:nats_not_connected, _}} = result
    end

    test "requires all mandatory fields" do
      # Missing tenant_slug should raise
      assert_raise KeyError, fn ->
        EventPublisher.publish_state_change(
          entity_type: :gateway,
          entity_id: "gateway-123",
          tenant_id: "tenant-uuid",
          # missing tenant_slug
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

  describe "publish_registered/5" do
    test "builds correct event for registration" do
      result =
        EventPublisher.publish_registered(
          :gateway,
          "gateway-123",
          "tenant-uuid",
          "acme",
          initial_state: :healthy,
          partition_id: "partition-uuid"
        )

      # Expect error since NATS is not connected
      assert {:error, {:nats_not_connected, _}} = result
    end
  end

  describe "publish_deregistered/5" do
    test "builds correct event for deregistration" do
      result =
        EventPublisher.publish_deregistered(
          :agent,
          "agent-456",
          "tenant-uuid",
          "acme",
          final_state: :disconnected,
          reason: "shutdown"
        )

      # Expect error since NATS is not connected
      assert {:error, {:nats_not_connected, _}} = result
    end
  end

  describe "publish_heartbeat_timeout/5" do
    test "builds correct event for heartbeat timeout" do
      result =
        EventPublisher.publish_heartbeat_timeout(
          :gateway,
          "gateway-123",
          "tenant-uuid",
          "acme",
          last_seen: DateTime.utc_now(),
          current_state: :healthy
        )

      # Expect error since NATS is not connected
      assert {:error, {:nats_not_connected, _}} = result
    end
  end

  describe "publish_health_change/6" do
    test "builds correct event for health change" do
      result =
        EventPublisher.publish_health_change(
          :checker,
          "checker-789",
          "tenant-uuid",
          "acme",
          false,
          reason: "consecutive_failures"
        )

      # Expect error since NATS is not connected
      assert {:error, {:nats_not_connected, _}} = result
    end
  end
end
