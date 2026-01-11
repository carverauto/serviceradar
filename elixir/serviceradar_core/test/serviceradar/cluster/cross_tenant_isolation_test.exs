defmodule ServiceRadar.Cluster.CrossTenantIsolationTest do
  @moduledoc """
  Integration tests for cross-tenant process isolation.

  These tests verify that the hybrid isolation approach (Option D) correctly
  prevents cross-tenant process discovery and communication:

  1. Tenants cannot enumerate each other's processes via Horde.Registry.select
  2. Tenants cannot look up each other's processes by key
  3. TenantGuard rejects cross-tenant GenServer calls
  4. Platform/admin processes can access all tenants
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Cluster.TenantGuard

  # Use unique tenant IDs per test run to avoid cross-test pollution
  setup do
    # Generate unique tenant IDs for this test
    unique_id = :erlang.unique_integer([:positive])
    tenant_a = "tenant-a-isolation-#{unique_id}"
    tenant_b = "tenant-b-isolation-#{unique_id}"
    tenant_slug_a = "acme-corp-#{unique_id}"
    tenant_slug_b = "xyz-inc-#{unique_id}"

    # Ensure TenantRegistry is running
    case Process.whereis(TenantRegistry) do
      nil ->
        start_supervised!(TenantRegistry)

      _pid ->
        :ok
    end

    # Create registries for both tenants
    {:ok, _} = TenantRegistry.ensure_registry(tenant_a, tenant_slug_a)
    {:ok, _} = TenantRegistry.ensure_registry(tenant_b, tenant_slug_b)

    on_exit(fn ->
      # Clean up tenant registries (ignore errors)
      try do
        TenantRegistry.stop_tenant_infrastructure(tenant_a)
        TenantRegistry.stop_tenant_infrastructure(tenant_b)
      catch
        _, _ -> :ok
      end
    end)

    %{tenant_a: tenant_a, tenant_b: tenant_b, tenant_slug_a: tenant_slug_a, tenant_slug_b: tenant_slug_b}
  end

  describe "registry isolation" do
    test "tenant A cannot see tenant B's gateways", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      # Ensure registries are fully initialized
      assert Process.whereis(TenantRegistry.registry_name(tenant_a)) != nil
      assert Process.whereis(TenantRegistry.registry_name(tenant_b)) != nil

      # Register gateways in both tenants
      {:ok, pid_a} =
        TenantRegistry.register_gateway(tenant_a, "gateway-a1", %{
          partition_id: "partition-1",
          status: :available
        })

      {:ok, pid_b} =
        TenantRegistry.register_gateway(tenant_b, "gateway-b1", %{
          partition_id: "partition-1",
          status: :available
        })

      # Verify registrations succeeded
      assert is_pid(pid_a)
      assert is_pid(pid_b)

      # Tenant A should only see its own gateway
      gateways_a = TenantRegistry.find_gateways(tenant_a)
      assert length(gateways_a) == 1
      assert hd(gateways_a)[:key] == {:gateway, "gateway-a1"}

      # Tenant B should only see its own gateway
      gateways_b = TenantRegistry.find_gateways(tenant_b)
      assert length(gateways_b) == 1,
             "Expected 1 gateway for tenant B, got #{length(gateways_b)}: #{inspect(gateways_b)}"

      assert hd(gateways_b)[:key] == {:gateway, "gateway-b1"}
    end

    test "tenant A cannot look up tenant B's gateway by key", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      {:ok, _} =
        TenantRegistry.register_gateway(tenant_b, "shared-name", %{status: :available})

      # Tenant A tries to look up the same key - should not find it
      assert [] = TenantRegistry.lookup(tenant_a, {:gateway, "shared-name"})

      # Tenant B can find its own
      assert [{_, _}] = TenantRegistry.lookup(tenant_b, {:gateway, "shared-name"})
    end

    test "tenant A cannot see tenant B's agents", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      {:ok, _} =
        TenantRegistry.register_agent(tenant_a, "agent-a1", %{
          capabilities: [:icmp]
        })

      {:ok, _} =
        TenantRegistry.register_agent(tenant_b, "agent-b1", %{
          capabilities: [:tcp]
        })

      agents_a = TenantRegistry.find_agents(tenant_a)
      agents_b = TenantRegistry.find_agents(tenant_b)

      assert length(agents_a) == 1
      assert length(agents_b) == 1
      assert hd(agents_a)[:key] != hd(agents_b)[:key]
    end

    test "count is isolated per tenant", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      {:ok, _} = TenantRegistry.register_gateway(tenant_a, "g1", %{})
      {:ok, _} = TenantRegistry.register_gateway(tenant_a, "g2", %{})
      {:ok, _} = TenantRegistry.register_gateway(tenant_a, "g3", %{})
      {:ok, _} = TenantRegistry.register_gateway(tenant_b, "g1", %{})

      assert TenantRegistry.count(tenant_a) == 3
      assert TenantRegistry.count(tenant_b) == 1
    end

    test "heartbeat only affects correct tenant's gateway", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      {:ok, _} = TenantRegistry.register_gateway(tenant_a, "gateway-1", %{})
      {:ok, _} = TenantRegistry.register_gateway(tenant_b, "gateway-1", %{})

      # Get initial heartbeats
      [gateway_a_before] = TenantRegistry.find_gateways(tenant_a)
      [gateway_b_before] = TenantRegistry.find_gateways(tenant_b)

      Process.sleep(10)

      # Update only tenant A's heartbeat
      :ok = TenantRegistry.gateway_heartbeat(tenant_a, "gateway-1")

      [gateway_a_after] = TenantRegistry.find_gateways(tenant_a)
      [gateway_b_after] = TenantRegistry.find_gateways(tenant_b)

      # Tenant A's heartbeat should be updated
      assert DateTime.compare(
               gateway_a_after[:last_heartbeat],
               gateway_a_before[:last_heartbeat]
             ) == :gt

      # Tenant B's heartbeat should be unchanged
      assert DateTime.compare(
               gateway_b_after[:last_heartbeat],
               gateway_b_before[:last_heartbeat]
             ) == :eq
    end
  end

  describe "process-level isolation (TenantGuard)" do
    defmodule TenantAwareWorker do
      use GenServer
      use ServiceRadar.Cluster.TenantGuard

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      def init(opts) do
        tenant_id = Keyword.fetch!(opts, :tenant_id)
        set_process_tenant(tenant_id)
        {:ok, %{tenant_id: tenant_id, data: "secret-#{tenant_id}"}}
      end

      def handle_call(:get_data, from, state) do
        guard_tenant!(state.tenant_id, from)
        {:reply, {:ok, state.data}, state}
      end

      def handle_call(:get_data_unsafe, _from, state) do
        # Intentionally skips guard - for testing purposes
        {:reply, {:ok, state.data}, state}
      end
    end

    test "same-tenant process communication succeeds", %{tenant_a: tenant_a} do
      {:ok, worker} = TenantAwareWorker.start_link(tenant_id: tenant_a)

      # Set caller to same tenant
      TenantGuard.set_process_tenant(tenant_a)

      assert {:ok, "secret-" <> ^tenant_a} = GenServer.call(worker, :get_data)

      GenServer.stop(worker)
    end

    test "cross-tenant process communication is blocked", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      # Trap exits so the GenServer crash doesn't kill us
      Process.flag(:trap_exit, true)

      {:ok, worker} = TenantAwareWorker.start_link(tenant_id: tenant_a)

      # Set caller to different tenant
      TenantGuard.set_process_tenant(tenant_b)

      # The exception is raised in the GenServer and propagates as an exit
      # We expect the call to either crash or return an exit
      result =
        try do
          GenServer.call(worker, :get_data)
        catch
          :exit, reason -> {:caught_exit, reason}
        end

      assert match?({:caught_exit, _}, result)
    end

    test "platform admin can access any tenant's processes", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      {:ok, worker_a} = TenantAwareWorker.start_link(tenant_id: tenant_a)
      {:ok, worker_b} = TenantAwareWorker.start_link(tenant_id: tenant_b)

      # Platform admin
      TenantGuard.set_process_tenant(:platform)

      assert {:ok, _} = GenServer.call(worker_a, :get_data)
      assert {:ok, _} = GenServer.call(worker_b, :get_data)

      GenServer.stop(worker_a)
      GenServer.stop(worker_b)
    end

    test "super_admin can access any tenant's processes", %{tenant_a: tenant_a} do
      {:ok, worker} = TenantAwareWorker.start_link(tenant_id: tenant_a)

      TenantGuard.set_process_tenant(:super_admin)

      assert {:ok, _} = GenServer.call(worker, :get_data)

      GenServer.stop(worker)
    end
  end

  describe "combined registry + guard isolation" do
    test "attacker scenario: cannot discover and call cross-tenant processes", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      # Scenario: Attacker is on tenant B, tries to access tenant A's gateway

      # Tenant A registers a gateway
      {:ok, _} =
        TenantRegistry.register_gateway(tenant_a, "secret-gateway", %{
          partition_id: "partition-1",
          status: :available
        })

      # Attacker (tenant B) tries to discover tenant A's gateways
      # This should return empty - first line of defense
      attacker_discovered_gateways = TenantRegistry.find_gateways(tenant_b)
      assert attacker_discovered_gateways == []

      # Attacker tries to guess the key - also fails
      assert [] = TenantRegistry.lookup(tenant_b, {:gateway, "secret-gateway"})

      # Even if attacker somehow got a PID (e.g., via observer before we added isolation),
      # TenantGuard would block the call - defense in depth
      # (We can't easily simulate this without exposing PIDs, but the mechanism is tested above)
    end

    test "legitimate same-tenant operations work correctly", %{tenant_a: tenant_a} do
      # Tenant A's gateway registration
      {:ok, _} =
        TenantRegistry.register_gateway(tenant_a, "my-gateway", %{
          partition_id: "partition-1",
          status: :available
        })

      # Tenant A can find its gateway
      gateways = TenantRegistry.find_gateways(tenant_a)
      assert length(gateways) == 1

      # Tenant A can look it up
      assert [{pid, metadata}] = TenantRegistry.lookup(tenant_a, {:gateway, "my-gateway"})
      assert is_pid(pid)
      assert metadata[:partition_id] == "partition-1"

      # Tenant A can update heartbeat
      :ok = TenantRegistry.gateway_heartbeat(tenant_a, "my-gateway")
    end
  end

  describe "DynamicSupervisor isolation" do
    test "child processes started under tenant supervisor are isolated", %{tenant_a: tenant_a, tenant_b: tenant_b} do
      # Start a process under tenant A's supervisor
      child_spec_a = %{
        id: :test_agent_a,
        start: {Agent, :start_link, [fn -> "tenant-a-data" end]},
        restart: :temporary
      }

      {:ok, pid_a} = TenantRegistry.start_child(tenant_a, child_spec_a)

      # Start a process under tenant B's supervisor
      child_spec_b = %{
        id: :test_agent_b,
        start: {Agent, :start_link, [fn -> "tenant-b-data" end]},
        restart: :temporary
      }

      {:ok, pid_b} = TenantRegistry.start_child(tenant_b, child_spec_b)

      # Both processes are alive
      assert Process.alive?(pid_a)
      assert Process.alive?(pid_b)

      # Data is isolated
      assert Agent.get(pid_a, & &1) == "tenant-a-data"
      assert Agent.get(pid_b, & &1) == "tenant-b-data"

      # Terminate tenant A's supervisor
      :ok = TenantRegistry.terminate_child(tenant_a, pid_a)

      # Tenant A's process is dead, tenant B's is still alive
      Process.sleep(10)
      refute Process.alive?(pid_a)
      assert Process.alive?(pid_b)
    end
  end

  describe "slug alias lookup" do
    test "can look up tenant UUID from slug", %{tenant_a: tenant_a, tenant_b: tenant_b, tenant_slug_a: tenant_slug_a, tenant_slug_b: tenant_slug_b} do
      assert {:ok, ^tenant_a} = TenantRegistry.tenant_id_for_slug(tenant_slug_a)
      assert {:ok, ^tenant_b} = TenantRegistry.tenant_id_for_slug(tenant_slug_b)
    end

    test "can look up slug from tenant UUID", %{tenant_a: tenant_a, tenant_b: tenant_b, tenant_slug_a: tenant_slug_a, tenant_slug_b: tenant_slug_b} do
      assert {:ok, ^tenant_slug_a} = TenantRegistry.slug_for_tenant_id(tenant_a)
      assert {:ok, ^tenant_slug_b} = TenantRegistry.slug_for_tenant_id(tenant_b)
    end

    test "unknown slug returns error", _context do
      assert :error = TenantRegistry.tenant_id_for_slug("unknown-slug")
    end
  end
end
