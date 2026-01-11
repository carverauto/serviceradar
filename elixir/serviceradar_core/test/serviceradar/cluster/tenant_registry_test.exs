defmodule ServiceRadar.Cluster.TenantRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Cluster.TenantRegistry

  # Use unique tenant IDs per test to avoid cross-test pollution
  setup do
    unique_id = :erlang.unique_integer([:positive])
    tenant_id_1 = "tenant-1-registry-test-#{unique_id}"
    tenant_id_2 = "tenant-2-registry-test-#{unique_id}"
    tenant_slug_1 = "acme-corp-#{unique_id}"
    tenant_slug_2 = "xyz-inc-#{unique_id}"

    # Ensure TenantRegistry is running
    case Process.whereis(TenantRegistry) do
      nil ->
        start_supervised!(TenantRegistry)

      _pid ->
        :ok
    end

    on_exit(fn ->
      # Clean up tenant registries created during the test (ignore errors)
      try do
        TenantRegistry.stop_tenant_infrastructure(tenant_id_1)
        TenantRegistry.stop_tenant_infrastructure(tenant_id_2)
      catch
        _, _ -> :ok
      end
    end)

    %{
      tenant_id_1: tenant_id_1,
      tenant_id_2: tenant_id_2,
      tenant_slug_1: tenant_slug_1,
      tenant_slug_2: tenant_slug_2
    }
  end

  describe "ensure_registry/1" do
    test "creates registry and supervisor for new tenant", %{tenant_id_1: tenant_id_1} do
      assert {:ok, %{registry: registry, supervisor: supervisor}} =
               TenantRegistry.ensure_registry(tenant_id_1)

      assert is_atom(registry)
      assert is_atom(supervisor)
      assert Process.whereis(registry) != nil
      assert Process.whereis(supervisor) != nil
    end

    test "returns existing registry for same tenant", %{tenant_id_1: tenant_id_1} do
      {:ok, %{registry: registry1}} = TenantRegistry.ensure_registry(tenant_id_1)
      {:ok, %{registry: registry2}} = TenantRegistry.ensure_registry(tenant_id_1)

      assert registry1 == registry2
    end

    test "creates separate registries for different tenants", %{tenant_id_1: tenant_id_1, tenant_id_2: tenant_id_2} do
      {:ok, %{registry: registry1}} = TenantRegistry.ensure_registry(tenant_id_1)
      {:ok, %{registry: registry2}} = TenantRegistry.ensure_registry(tenant_id_2)

      assert registry1 != registry2
    end
  end

  describe "ensure_registry/2 with slug" do
    test "registers slug -> UUID mapping", %{tenant_id_1: tenant_id_1, tenant_slug_1: tenant_slug_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1, tenant_slug_1)

      assert {:ok, ^tenant_id_1} = TenantRegistry.tenant_id_for_slug(tenant_slug_1)
    end

    test "returns error for unknown slug", _context do
      assert :error = TenantRegistry.tenant_id_for_slug("unknown-slug")
    end
  end

  describe "registry_name/1" do
    test "generates consistent names for same tenant", %{tenant_id_1: tenant_id_1} do
      name1 = TenantRegistry.registry_name(tenant_id_1)
      name2 = TenantRegistry.registry_name(tenant_id_1)

      assert name1 == name2
    end

    test "generates different names for different tenants", %{tenant_id_1: tenant_id_1, tenant_id_2: tenant_id_2} do
      name1 = TenantRegistry.registry_name(tenant_id_1)
      name2 = TenantRegistry.registry_name(tenant_id_2)

      assert name1 != name2
    end

    test "uses hash-based naming", %{tenant_id_1: tenant_id_1} do
      name = TenantRegistry.registry_name(tenant_id_1)
      name_str = Atom.to_string(name)

      assert String.starts_with?(name_str, "ServiceRadar.TenantRegistry.T_")
      assert String.ends_with?(name_str, ".Registry")
    end
  end

  describe "register/3 and lookup/2" do
    test "registers and looks up process in tenant registry", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      key = {:gateway, "gateway-001"}
      metadata = %{status: :available, node: node()}

      {:ok, _pid} = TenantRegistry.register(tenant_id_1, key, metadata)

      assert [{pid, found_metadata}] = TenantRegistry.lookup(tenant_id_1, key)
      assert is_pid(pid)
      assert found_metadata.status == :available
    end

    test "returns empty list for non-existent key", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      assert [] = TenantRegistry.lookup(tenant_id_1, {:gateway, "non-existent"})
    end

    test "tenant isolation - cannot see other tenant's registrations", %{tenant_id_1: tenant_id_1, tenant_id_2: tenant_id_2} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_2)

      key = {:gateway, "gateway-001"}
      metadata = %{status: :available}

      {:ok, _pid} = TenantRegistry.register(tenant_id_1, key, metadata)

      # Same key in tenant 1 should be found
      assert [{_pid, _}] = TenantRegistry.lookup(tenant_id_1, key)

      # Same key in tenant 2 should NOT be found
      assert [] = TenantRegistry.lookup(tenant_id_2, key)
    end
  end

  describe "register_gateway/3 and find_gateways/1" do
    test "registers gateway with auto-generated metadata", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      metadata = %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      }

      {:ok, _pid} = TenantRegistry.register_gateway(tenant_id_1, "gateway-001", metadata)

      gateways = TenantRegistry.find_gateways(tenant_id_1)

      assert length(gateways) == 1
      [gateway] = gateways
      assert gateway[:partition_id] == "partition-1"
      assert gateway[:status] == :available
      assert gateway[:type] == :gateway
      assert %DateTime{} = gateway[:registered_at]
      assert %DateTime{} = gateway[:last_heartbeat]
    end

    test "find_available_gateways/1 filters by status", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      {:ok, _} =
        TenantRegistry.register_gateway(tenant_id_1, "gateway-001", %{status: :available})

      {:ok, _} = TenantRegistry.register_gateway(tenant_id_1, "gateway-002", %{status: :busy})

      available = TenantRegistry.find_available_gateways(tenant_id_1)

      assert length(available) == 1
      assert hd(available)[:status] == :available
    end
  end

  describe "register_agent/3 and find_agents/1" do
    test "registers agent with auto-generated metadata", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      metadata = %{
        partition_id: "partition-1",
        capabilities: [:icmp_sweep, :tcp_sweep],
        status: :connected
      }

      {:ok, _pid} = TenantRegistry.register_agent(tenant_id_1, "agent-001", metadata)

      agents = TenantRegistry.find_agents(tenant_id_1)

      assert length(agents) == 1
      [agent] = agents
      assert agent[:partition_id] == "partition-1"
      assert agent[:capabilities] == [:icmp_sweep, :tcp_sweep]
      assert agent[:type] == :agent
    end
  end

  describe "unregister/2" do
    test "unregisters process from tenant registry", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      key = {:gateway, "gateway-001"}
      {:ok, _pid} = TenantRegistry.register(tenant_id_1, key, %{})

      assert [{_, _}] = TenantRegistry.lookup(tenant_id_1, key)

      :ok = TenantRegistry.unregister(tenant_id_1, key)

      assert [] = TenantRegistry.lookup(tenant_id_1, key)
    end
  end

  describe "count/1 and count_by_type/2" do
    test "counts all processes in tenant registry", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      {:ok, _} = TenantRegistry.register_gateway(tenant_id_1, "gateway-001", %{})
      {:ok, _} = TenantRegistry.register_gateway(tenant_id_1, "gateway-002", %{})
      {:ok, _} = TenantRegistry.register_agent(tenant_id_1, "agent-001", %{})

      assert TenantRegistry.count(tenant_id_1) == 3
    end

    test "counts processes by type", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      {:ok, _} = TenantRegistry.register_gateway(tenant_id_1, "gateway-001", %{})
      {:ok, _} = TenantRegistry.register_gateway(tenant_id_1, "gateway-002", %{})
      {:ok, _} = TenantRegistry.register_agent(tenant_id_1, "agent-001", %{})

      assert TenantRegistry.count_by_type(tenant_id_1, :gateway) == 2
      assert TenantRegistry.count_by_type(tenant_id_1, :agent) == 1
    end
  end

  describe "gateway_heartbeat/2" do
    test "updates last_heartbeat timestamp", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      {:ok, _} = TenantRegistry.register_gateway(tenant_id_1, "gateway-001", %{})

      [gateway_before] = TenantRegistry.find_gateways(tenant_id_1)
      original_heartbeat = gateway_before[:last_heartbeat]

      Process.sleep(10)

      :ok = TenantRegistry.gateway_heartbeat(tenant_id_1, "gateway-001")

      [gateway_after] = TenantRegistry.find_gateways(tenant_id_1)
      new_heartbeat = gateway_after[:last_heartbeat]

      assert DateTime.compare(new_heartbeat, original_heartbeat) == :gt
    end
  end

  describe "start_child/2" do
    test "starts child under tenant's DynamicSupervisor", %{tenant_id_1: tenant_id_1} do
      {:ok, _} = TenantRegistry.ensure_registry(tenant_id_1)

      child_spec = %{
        id: :test_worker,
        start: {Agent, :start_link, [fn -> 42 end]},
        restart: :temporary
      }

      {:ok, pid} = TenantRegistry.start_child(tenant_id_1, child_spec)

      assert is_pid(pid)
      assert Agent.get(pid, & &1) == 42
    end
  end

  describe "stop_tenant_infrastructure/1" do
    test "stops registry and supervisor for tenant", %{tenant_id_1: tenant_id_1} do
      {:ok, %{registry: registry, supervisor: supervisor}} =
        TenantRegistry.ensure_registry(tenant_id_1)

      assert Process.whereis(registry) != nil
      assert Process.whereis(supervisor) != nil

      :ok = TenantRegistry.stop_tenant_infrastructure(tenant_id_1)

      # Poll for processes to terminate (up to 500ms)
      wait_for_process_down(registry, 50, 10)
      wait_for_process_down(supervisor, 50, 10)

      assert Process.whereis(registry) == nil
      assert Process.whereis(supervisor) == nil
    end

    # Helper to wait for a process to terminate
    defp wait_for_process_down(_name, _interval, 0), do: :ok

    defp wait_for_process_down(name, interval, retries) do
      case Process.whereis(name) do
        nil -> :ok
        _pid ->
          Process.sleep(interval)
          wait_for_process_down(name, interval, retries - 1)
      end
    end

    test "returns error for non-existent tenant", _context do
      assert {:error, :not_found} =
               TenantRegistry.stop_tenant_infrastructure("non-existent-tenant-id")
    end
  end
end
