defmodule ServiceRadarGateway.RegistrationTest do
  @moduledoc """
  Tests for gateway registration with the distributed Horde registry.

  Verifies that:
  - Gateway can register with the GatewayRegistry
  - Registration metadata is correct
  - Status updates are reflected in the registry
  - Heartbeat mechanism works
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Gateway.RegistrationWorker
  alias ServiceRadar.GatewayRegistry

  @partition_id "test-partition"
  @domain "test-domain"
  @capabilities [:icmp, :tcp]

  describe "GatewayRegistry" do
    test "can register a gateway directly with the registry" do
      key = {@partition_id, :test_node}
      metadata = %{
        partition_id: @partition_id,
        domain: @domain,
        capabilities: @capabilities,
        node: :test_node,
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }

      assert {:ok, _pid} = GatewayRegistry.register(key, metadata)

      # Verify lookup works
      result = GatewayRegistry.lookup(key)
      assert [{_pid, registered_metadata}] = result
      assert registered_metadata.partition_id == @partition_id
      assert registered_metadata.domain == @domain
      assert registered_metadata.status == :available
    end

    test "find_gateways_for_partition returns only gateways in that partition" do
      # Register a gateway in test-partition-a
      key_a = {"test-partition-a", :node_a}
      metadata_a = %{
        partition_id: "test-partition-a",
        domain: "domain-a",
        capabilities: [:icmp],
        node: :node_a,
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }
      {:ok, _} = GatewayRegistry.register(key_a, metadata_a)

      # Register a gateway in test-partition-b
      key_b = {"test-partition-b", :node_b}
      metadata_b = %{
        partition_id: "test-partition-b",
        domain: "domain-b",
        capabilities: [:tcp],
        node: :node_b,
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }
      {:ok, _} = GatewayRegistry.register(key_b, metadata_b)

      # Find gateways for partition-a
      gateways_a = GatewayRegistry.find_gateways_for_partition("test-partition-a")
      assert length(gateways_a) >= 1
      assert Enum.all?(gateways_a, &(&1.partition_id == "test-partition-a"))
    end

    test "find_available_gateways filters by status" do
      # Register an available gateway
      key_avail = {"avail-partition", :avail_node}
      metadata_avail = %{
        partition_id: "avail-partition",
        domain: "domain",
        capabilities: [],
        node: :avail_node,
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }
      {:ok, _} = GatewayRegistry.register(key_avail, metadata_avail)

      # Register an unavailable gateway
      key_unavail = {"unavail-partition", :unavail_node}
      metadata_unavail = %{
        partition_id: "unavail-partition",
        domain: "domain",
        capabilities: [],
        node: :unavail_node,
        status: :unavailable,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }
      {:ok, _} = GatewayRegistry.register(key_unavail, metadata_unavail)

      # Find available gateways
      available = GatewayRegistry.find_available_gateways()

      # Should contain the available one
      avail_ids = Enum.map(available, & &1.partition_id)
      assert "avail-partition" in avail_ids

      # Should not contain the unavailable one
      unavail_ids = Enum.filter(available, &(&1.status == :unavailable)) |> Enum.map(& &1.partition_id)
      assert unavail_ids == []
    end

    test "update_value updates metadata" do
      key = {"update-partition", :update_node}
      metadata = %{
        partition_id: "update-partition",
        domain: "domain",
        capabilities: [],
        node: :update_node,
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }
      {:ok, _} = GatewayRegistry.register(key, metadata)

      # Update status to busy
      GatewayRegistry.update_value(key, fn meta ->
        %{meta | status: :busy}
      end)

      # Verify update
      [{_pid, updated}] = GatewayRegistry.lookup(key)
      assert updated.status == :busy
    end

    test "count returns number of registered gateways" do
      initial_count = GatewayRegistry.count()

      key = {"count-partition", :count_node}
      metadata = %{
        partition_id: "count-partition",
        domain: "domain",
        capabilities: [],
        node: :count_node,
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }
      {:ok, _} = GatewayRegistry.register(key, metadata)

      assert GatewayRegistry.count() == initial_count + 1
    end

    test "unregister removes gateway from registry" do
      key = {"unregister-partition", :unregister_node}
      metadata = %{
        partition_id: "unregister-partition",
        domain: "domain",
        capabilities: [],
        node: :unregister_node,
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }
      {:ok, _} = GatewayRegistry.register(key, metadata)

      # Verify registered
      assert [{_pid, _}] = GatewayRegistry.lookup(key)

      # Unregister
      :ok = GatewayRegistry.unregister(key)

      # Verify removed
      assert [] = GatewayRegistry.lookup(key)
    end
  end

  describe "RegistrationWorker" do
    # Note: The RegistrationWorker is started by ServiceRadarGateway.Application
    # so we test the already-running instance rather than starting new ones

    test "is running after application starts" do
      # The RegistrationWorker should be running
      pid = Process.whereis(RegistrationWorker)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "is registered in the GatewayRegistry" do
      # The default partition from Application startup
      key = {"default", Node.self()}
      result = GatewayRegistry.lookup(key)
      assert [{_pid, metadata}] = result
      assert metadata.partition_id == "default"
      assert metadata.status == :available
    end

    test "get_status returns current status" do
      status = RegistrationWorker.get_status()
      assert status in [:available, :busy, :unavailable, :draining]
    end

    test "get_info returns gateway information" do
      info = RegistrationWorker.get_info()
      assert info.partition_id == "default"
      assert info.node == Node.self()
      assert info.status != nil
    end
  end

  describe "stale detection" do
    test "stale?/1 returns true for old heartbeats" do
      old_metadata = %{
        last_heartbeat: DateTime.add(DateTime.utc_now(), -180, :second)
      }

      assert RegistrationWorker.stale?(old_metadata) == true
    end

    test "stale?/1 returns false for recent heartbeats" do
      recent_metadata = %{
        last_heartbeat: DateTime.utc_now()
      }

      assert RegistrationWorker.stale?(recent_metadata) == false
    end

    test "stale?/1 returns true when no heartbeat" do
      no_heartbeat = %{}
      assert RegistrationWorker.stale?(no_heartbeat) == true
    end
  end
end
