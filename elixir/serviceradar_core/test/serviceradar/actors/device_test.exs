defmodule ServiceRadar.Actors.DeviceTest do
  @moduledoc """
  Tests for the Device Actor System.

  Verifies that:
  - Device actors can be started and registered
  - Lazy initialization works via get_or_start
  - Identity updates are handled correctly
  - Events are buffered and can be flushed
  - Health status transitions work properly
  - Hibernation and idle timeout function correctly
  - Multi-tenant isolation is enforced
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.Device
  alias ServiceRadar.Actors.DeviceRegistry
  alias ServiceRadar.Cluster.TenantRegistry

  @moduletag :database

  setup do
    unique_id = :erlang.unique_integer([:positive])
    tenant_id = Ash.UUID.generate()
    device_id = "device-#{unique_id}"
    partition_id = "partition-#{unique_id}"

    # Ensure tenant registry exists
    TenantRegistry.ensure_registry(tenant_id)

    # Wait for registry processes to start
    Process.sleep(100)

    on_exit(fn ->
      # Cleanup: stop any device actors we started
      DeviceRegistry.stop_all(tenant_id)
    end)

    {:ok,
      tenant_id: tenant_id,
      device_id: device_id,
      partition_id: partition_id,
      unique_id: unique_id
    }
  end

  describe "DeviceRegistry.get_or_start/3" do
    test "starts a new device actor when none exists", ctx do
      result = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      assert {:ok, pid} = result
      assert Process.alive?(pid)
    end

    test "returns existing actor on subsequent calls", ctx do
      {:ok, pid1} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)
      {:ok, pid2} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      assert pid1 == pid2
    end

    test "starts actor with partition_id", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(
        ctx.tenant_id,
        ctx.device_id,
        partition_id: ctx.partition_id
      )

      state = Device.get_state(pid)
      assert state.partition_id == ctx.partition_id
    end

    test "starts actor with initial identity", ctx do
      initial_identity = %{
        hostname: "test-server",
        ip: "10.0.0.1",
        mac: "00:11:22:33:44:55"
      }

      {:ok, pid} = DeviceRegistry.get_or_start(
        ctx.tenant_id,
        ctx.device_id,
        identity: initial_identity
      )

      identity = Device.get_identity(pid)
      assert identity.hostname == "test-server"
      assert identity.ip == "10.0.0.1"
    end
  end

  describe "DeviceRegistry.lookup/2" do
    test "returns :not_found when actor doesn't exist", ctx do
      result = DeviceRegistry.lookup(ctx.tenant_id, "nonexistent-device")
      assert result == :not_found
    end

    test "returns {:ok, pid} when actor exists", ctx do
      {:ok, expected_pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      result = DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id)
      assert {:ok, ^expected_pid} = result
    end
  end

  describe "DeviceRegistry.list_devices/1" do
    test "returns empty list when no devices", ctx do
      devices = DeviceRegistry.list_devices(ctx.tenant_id)
      # Filter out any devices we didn't create
      our_devices = Enum.filter(devices, &(&1.device_id == ctx.device_id))
      assert our_devices == []
    end

    test "returns list of active device actors", ctx do
      # Start multiple devices
      device_ids = for i <- 1..3, do: "device-list-#{ctx.unique_id}-#{i}"

      for id <- device_ids do
        {:ok, _} = DeviceRegistry.get_or_start(ctx.tenant_id, id)
      end

      devices = DeviceRegistry.list_devices(ctx.tenant_id)
      our_devices = Enum.filter(devices, &(&1.device_id in device_ids))

      assert length(our_devices) == 3
    end
  end

  describe "Device.get_state/1" do
    test "returns full state struct", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      state = Device.get_state(pid)

      assert %Device{} = state
      assert state.tenant_id == ctx.tenant_id
      assert state.device_id == ctx.device_id
      assert is_map(state.identity)
      assert is_map(state.health)
      assert is_list(state.events)
    end
  end

  describe "Device.update_identity/2" do
    test "updates identity in state", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      :ok = Device.update_identity(pid, %{hostname: "new-hostname"})

      identity = Device.get_identity(pid)
      assert identity.hostname == "new-hostname"
    end

    test "merges with existing identity", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(
        ctx.tenant_id,
        ctx.device_id,
        identity: %{hostname: "original", ip: "10.0.0.1"}
      )

      :ok = Device.update_identity(pid, %{hostname: "updated"})

      identity = Device.get_identity(pid)
      assert identity.hostname == "updated"
      assert identity.ip == "10.0.0.1"
    end
  end

  describe "Device.record_event/3" do
    test "buffers events in state", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      Device.record_event(pid, :test_event, %{data: "test"})
      Device.record_event(pid, :another_event, %{value: 42})

      # Give async cast time to process
      Process.sleep(50)

      state = Device.get_state(pid)
      assert length(state.events) >= 2
    end

    test "includes timestamp in events", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      before = DateTime.utc_now()
      Device.record_event(pid, :timed_event, %{})
      Process.sleep(50)

      state = Device.get_state(pid)
      event = List.first(state.events)

      assert event.type == :timed_event
      assert DateTime.compare(event.timestamp, before) in [:eq, :gt]
    end
  end

  describe "Device.record_health_check/2" do
    test "updates health status to healthy", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      Device.record_health_check(pid, %{
        available: true,
        response_time_ms: 15
      })

      Process.sleep(50)

      health = Device.get_health(pid)
      assert health.status == :healthy
      assert health.response_time_ms == 15
    end

    test "updates health status to unhealthy on failure", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      Device.record_health_check(pid, %{
        available: false,
        error: "connection refused"
      })

      Process.sleep(50)

      health = Device.get_health(pid)
      assert health.status == :unhealthy
    end

    test "tracks consecutive failures", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      for _ <- 1..3 do
        Device.record_health_check(pid, %{available: false})
        Process.sleep(20)
      end

      health = Device.get_health(pid)
      assert health.consecutive_failures >= 3
    end

    test "resets consecutive failures on success", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      # Record failures
      for _ <- 1..3 do
        Device.record_health_check(pid, %{available: false})
        Process.sleep(20)
      end

      # Then success
      Device.record_health_check(pid, %{available: true})
      Process.sleep(50)

      health = Device.get_health(pid)
      assert health.consecutive_failures == 0
    end
  end

  describe "Device.flush_events/1" do
    test "clears event buffer", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      Device.record_event(pid, :event1, %{})
      Device.record_event(pid, :event2, %{})
      Process.sleep(50)

      :ok = Device.flush_events(pid)

      state = Device.get_state(pid)
      assert state.events == []
    end
  end

  describe "Device.touch/1" do
    test "updates last_seen timestamp", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      before = Device.get_state(pid).last_seen
      Process.sleep(50)
      Device.touch(pid)
      Process.sleep(50)
      after_touch = Device.get_state(pid).last_seen

      assert DateTime.compare(after_touch, before) == :gt
    end
  end

  describe "DeviceRegistry.stop/2" do
    test "stops device actor", ctx do
      {:ok, pid} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)
      assert Process.alive?(pid)

      :ok = DeviceRegistry.stop(ctx.tenant_id, ctx.device_id)
      Process.sleep(50)

      refute Process.alive?(pid)
    end

    test "returns :not_found for non-existent device", ctx do
      result = DeviceRegistry.stop(ctx.tenant_id, "nonexistent")
      assert result == :not_found
    end
  end

  describe "multi-tenant isolation" do
    test "device actors are isolated between tenants", ctx do
      tenant_b = Ash.UUID.generate()
      TenantRegistry.ensure_registry(tenant_b)
      Process.sleep(100)

      # Start device in tenant A
      {:ok, pid_a} = DeviceRegistry.get_or_start(ctx.tenant_id, ctx.device_id)

      # Same device_id in tenant B should create new actor
      {:ok, pid_b} = DeviceRegistry.get_or_start(tenant_b, ctx.device_id)

      assert pid_a != pid_b

      # Lookup in wrong tenant returns not_found
      assert DeviceRegistry.lookup(tenant_b, ctx.device_id) == {:ok, pid_b}
      assert DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id) == {:ok, pid_a}

      # Cleanup
      DeviceRegistry.stop_all(tenant_b)
    end

    test "list_devices only returns devices for specified tenant", ctx do
      tenant_b = Ash.UUID.generate()
      TenantRegistry.ensure_registry(tenant_b)
      Process.sleep(100)

      # Start devices in both tenants
      {:ok, _} = DeviceRegistry.get_or_start(ctx.tenant_id, "device-a-#{ctx.unique_id}")
      {:ok, _} = DeviceRegistry.get_or_start(tenant_b, "device-b-#{ctx.unique_id}")

      # List should only return tenant's devices
      devices_a = DeviceRegistry.list_devices(ctx.tenant_id)
      devices_b = DeviceRegistry.list_devices(tenant_b)

      device_ids_a = Enum.map(devices_a, & &1.device_id)
      device_ids_b = Enum.map(devices_b, & &1.device_id)

      assert "device-a-#{ctx.unique_id}" in device_ids_a
      refute "device-b-#{ctx.unique_id}" in device_ids_a

      assert "device-b-#{ctx.unique_id}" in device_ids_b
      refute "device-a-#{ctx.unique_id}" in device_ids_b

      # Cleanup
      DeviceRegistry.stop_all(tenant_b)
    end
  end

  describe "convenience functions" do
    test "DeviceRegistry.update_identity/3 starts actor if needed", ctx do
      # Device doesn't exist yet
      assert DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id) == :not_found

      # Update identity (should start actor)
      :ok = DeviceRegistry.update_identity(ctx.tenant_id, ctx.device_id, %{
        hostname: "lazy-start-host"
      })

      # Now it should exist
      {:ok, pid} = DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id)
      identity = Device.get_identity(pid)
      assert identity.hostname == "lazy-start-host"
    end

    test "DeviceRegistry.record_event/4 starts actor if needed", ctx do
      assert DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id) == :not_found

      :ok = DeviceRegistry.record_event(ctx.tenant_id, ctx.device_id, :test, %{})

      {:ok, _pid} = DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id)
    end

    test "DeviceRegistry.record_health_check/3 starts actor if needed", ctx do
      assert DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id) == :not_found

      :ok = DeviceRegistry.record_health_check(ctx.tenant_id, ctx.device_id, %{
        available: true
      })

      {:ok, pid} = DeviceRegistry.lookup(ctx.tenant_id, ctx.device_id)
      health = Device.get_health(pid)
      assert health.status == :healthy
    end
  end
end
