defmodule ServiceRadar.Cluster.TenantRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Cluster.TenantRegistry

  @tenant_id_1 "550e8400-e29b-41d4-a716-446655440001"
  @tenant_id_2 "550e8400-e29b-41d4-a716-446655440002"
  @tenant_slug_1 "acme-corp"
  @tenant_slug_2 "xyz-inc"

  setup do
    # TenantRegistry is started by the application supervisor
    # We just need to ensure it's running and clean up tenant registries between tests
    case Process.whereis(TenantRegistry) do
      nil ->
        # Not running, start it for tests
        start_supervised!(TenantRegistry)

      _pid ->
        # Already running from application, clean up any existing tenant registries
        try do
          TenantRegistry.list_registries()
          |> Enum.each(fn {_name, pid} ->
            try do
              # Terminate each tenant's infrastructure
              Process.exit(pid, :shutdown)
            catch
              _, _ -> :ok
            end
          end)

          # Wait for cleanup
          Process.sleep(50)
        catch
          _, _ -> :ok
        end
    end

    on_exit(fn ->
      # Clean up any tenant infrastructure we created during the test
      if Process.whereis(TenantRegistry) do
        try do
          TenantRegistry.list_registries()
          |> Enum.each(fn {_name, pid} ->
            try do
              Process.exit(pid, :shutdown)
            catch
              _, _ -> :ok
            end
          end)
        catch
          _, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "ensure_registry/1" do
    test "creates registry and supervisor for new tenant" do
      assert {:ok, %{registry: registry, supervisor: supervisor}} =
               TenantRegistry.ensure_registry(@tenant_id_1)

      assert is_atom(registry)
      assert is_atom(supervisor)
      assert Process.whereis(registry) != nil
      assert Process.whereis(supervisor) != nil
    end

    test "returns existing registry for same tenant" do
      {:ok, %{registry: registry1}} = TenantRegistry.ensure_registry(@tenant_id_1)
      {:ok, %{registry: registry2}} = TenantRegistry.ensure_registry(@tenant_id_1)

      assert registry1 == registry2
    end

    test "creates separate registries for different tenants" do
      {:ok, %{registry: registry1}} = TenantRegistry.ensure_registry(@tenant_id_1)
      {:ok, %{registry: registry2}} = TenantRegistry.ensure_registry(@tenant_id_2)

      assert registry1 != registry2
    end
  end

  describe "ensure_registry/2 with slug" do
    test "registers slug -> UUID mapping" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1, @tenant_slug_1)

      assert {:ok, @tenant_id_1} = TenantRegistry.tenant_id_for_slug(@tenant_slug_1)
    end

    test "returns error for unknown slug" do
      assert :error = TenantRegistry.tenant_id_for_slug("unknown-slug")
    end
  end

  describe "registry_name/1" do
    test "generates consistent names for same tenant" do
      name1 = TenantRegistry.registry_name(@tenant_id_1)
      name2 = TenantRegistry.registry_name(@tenant_id_1)

      assert name1 == name2
    end

    test "generates different names for different tenants" do
      name1 = TenantRegistry.registry_name(@tenant_id_1)
      name2 = TenantRegistry.registry_name(@tenant_id_2)

      assert name1 != name2
    end

    test "uses hash-based naming" do
      name = TenantRegistry.registry_name(@tenant_id_1)
      name_str = Atom.to_string(name)

      assert String.starts_with?(name_str, "ServiceRadar.TenantRegistry.T_")
      assert String.ends_with?(name_str, ".Registry")
    end
  end

  describe "register/3 and lookup/2" do
    test "registers and looks up process in tenant registry" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      key = {:poller, "poller-001"}
      metadata = %{status: :available, node: node()}

      {:ok, _pid} = TenantRegistry.register(@tenant_id_1, key, metadata)

      assert [{pid, found_metadata}] = TenantRegistry.lookup(@tenant_id_1, key)
      assert is_pid(pid)
      assert found_metadata.status == :available
    end

    test "returns empty list for non-existent key" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      assert [] = TenantRegistry.lookup(@tenant_id_1, {:poller, "non-existent"})
    end

    test "tenant isolation - cannot see other tenant's registrations" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_2)

      key = {:poller, "poller-001"}
      metadata = %{status: :available}

      {:ok, _pid} = TenantRegistry.register(@tenant_id_1, key, metadata)

      # Same key in tenant 1 should be found
      assert [{_pid, _}] = TenantRegistry.lookup(@tenant_id_1, key)

      # Same key in tenant 2 should NOT be found
      assert [] = TenantRegistry.lookup(@tenant_id_2, key)
    end
  end

  describe "register_poller/3 and find_pollers/1" do
    test "registers poller with auto-generated metadata" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      metadata = %{
        partition_id: "partition-1",
        domain: "site-a",
        status: :available
      }

      {:ok, _pid} = TenantRegistry.register_poller(@tenant_id_1, "poller-001", metadata)

      pollers = TenantRegistry.find_pollers(@tenant_id_1)

      assert length(pollers) == 1
      [poller] = pollers
      assert poller[:partition_id] == "partition-1"
      assert poller[:status] == :available
      assert poller[:type] == :poller
      assert %DateTime{} = poller[:registered_at]
      assert %DateTime{} = poller[:last_heartbeat]
    end

    test "find_available_pollers/1 filters by status" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      {:ok, _} =
        TenantRegistry.register_poller(@tenant_id_1, "poller-001", %{status: :available})

      {:ok, _} = TenantRegistry.register_poller(@tenant_id_1, "poller-002", %{status: :busy})

      available = TenantRegistry.find_available_pollers(@tenant_id_1)

      assert length(available) == 1
      assert hd(available)[:status] == :available
    end
  end

  describe "register_agent/3 and find_agents/1" do
    test "registers agent with auto-generated metadata" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      metadata = %{
        partition_id: "partition-1",
        capabilities: [:icmp_sweep, :tcp_sweep],
        status: :connected
      }

      {:ok, _pid} = TenantRegistry.register_agent(@tenant_id_1, "agent-001", metadata)

      agents = TenantRegistry.find_agents(@tenant_id_1)

      assert length(agents) == 1
      [agent] = agents
      assert agent[:partition_id] == "partition-1"
      assert agent[:capabilities] == [:icmp_sweep, :tcp_sweep]
      assert agent[:type] == :agent
    end
  end

  describe "unregister/2" do
    test "unregisters process from tenant registry" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      key = {:poller, "poller-001"}
      {:ok, _pid} = TenantRegistry.register(@tenant_id_1, key, %{})

      assert [{_, _}] = TenantRegistry.lookup(@tenant_id_1, key)

      :ok = TenantRegistry.unregister(@tenant_id_1, key)

      assert [] = TenantRegistry.lookup(@tenant_id_1, key)
    end
  end

  describe "count/1 and count_by_type/2" do
    test "counts all processes in tenant registry" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      {:ok, _} = TenantRegistry.register_poller(@tenant_id_1, "poller-001", %{})
      {:ok, _} = TenantRegistry.register_poller(@tenant_id_1, "poller-002", %{})
      {:ok, _} = TenantRegistry.register_agent(@tenant_id_1, "agent-001", %{})

      assert TenantRegistry.count(@tenant_id_1) == 3
    end

    test "counts processes by type" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      {:ok, _} = TenantRegistry.register_poller(@tenant_id_1, "poller-001", %{})
      {:ok, _} = TenantRegistry.register_poller(@tenant_id_1, "poller-002", %{})
      {:ok, _} = TenantRegistry.register_agent(@tenant_id_1, "agent-001", %{})

      assert TenantRegistry.count_by_type(@tenant_id_1, :poller) == 2
      assert TenantRegistry.count_by_type(@tenant_id_1, :agent) == 1
    end
  end

  describe "poller_heartbeat/2" do
    test "updates last_heartbeat timestamp" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      {:ok, _} = TenantRegistry.register_poller(@tenant_id_1, "poller-001", %{})

      [poller_before] = TenantRegistry.find_pollers(@tenant_id_1)
      original_heartbeat = poller_before[:last_heartbeat]

      Process.sleep(10)

      :ok = TenantRegistry.poller_heartbeat(@tenant_id_1, "poller-001")

      [poller_after] = TenantRegistry.find_pollers(@tenant_id_1)
      new_heartbeat = poller_after[:last_heartbeat]

      assert DateTime.compare(new_heartbeat, original_heartbeat) == :gt
    end
  end

  describe "start_child/2" do
    test "starts child under tenant's DynamicSupervisor" do
      {:ok, _} = TenantRegistry.ensure_registry(@tenant_id_1)

      child_spec = %{
        id: :test_worker,
        start: {Agent, :start_link, [fn -> 42 end]},
        restart: :temporary
      }

      {:ok, pid} = TenantRegistry.start_child(@tenant_id_1, child_spec)

      assert is_pid(pid)
      assert Agent.get(pid, & &1) == 42
    end
  end

  describe "stop_tenant_infrastructure/1" do
    test "stops registry and supervisor for tenant" do
      {:ok, %{registry: registry, supervisor: supervisor}} =
        TenantRegistry.ensure_registry(@tenant_id_1)

      assert Process.whereis(registry) != nil
      assert Process.whereis(supervisor) != nil

      :ok = TenantRegistry.stop_tenant_infrastructure(@tenant_id_1)

      # Give processes time to terminate
      Process.sleep(50)

      assert Process.whereis(registry) == nil
      assert Process.whereis(supervisor) == nil
    end

    test "returns error for non-existent tenant" do
      assert {:error, :not_found} =
               TenantRegistry.stop_tenant_infrastructure("non-existent-tenant-id")
    end
  end
end
