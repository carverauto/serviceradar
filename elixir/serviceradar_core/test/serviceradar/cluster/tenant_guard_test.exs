defmodule ServiceRadar.Cluster.TenantGuardTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Cluster.TenantGuard
  alias ServiceRadar.Cluster.TenantViolation

  @tenant_id_1 "tenant-abc-123"
  @tenant_id_2 "tenant-xyz-789"

  describe "set_process_tenant/1 and get_process_tenant/0" do
    test "sets and gets tenant for current process" do
      assert TenantGuard.get_process_tenant() == nil

      :ok = TenantGuard.set_process_tenant(@tenant_id_1)

      assert TenantGuard.get_process_tenant() == @tenant_id_1
    end

    test "supports atom tenants for platform/admin" do
      :ok = TenantGuard.set_process_tenant(:platform)

      assert TenantGuard.get_process_tenant() == :platform
    end
  end

  describe "guard_tenant!/2" do
    test "allows access when caller tenant matches expected tenant" do
      # Start a process with a specific tenant
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@tenant_id_1)

          receive do
            :done -> :ok
          end
        end)

      # Give process time to set tenant
      Process.sleep(10)

      # Should not raise
      assert :ok = TenantGuard.guard_tenant!(@tenant_id_1, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end

    test "raises TenantViolation when tenants don't match" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@tenant_id_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert_raise TenantViolation, ~r/Cross-tenant access denied/, fn ->
        TenantGuard.guard_tenant!(@tenant_id_2, {caller_pid, make_ref()})
      end

      send(caller_pid, :done)
    end

    test "allows platform tenant to access any tenant" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(:platform)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      # Platform can access any tenant
      assert :ok = TenantGuard.guard_tenant!(@tenant_id_1, {caller_pid, make_ref()})
      assert :ok = TenantGuard.guard_tenant!(@tenant_id_2, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end

    test "allows super_admin tenant to access any tenant" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(:super_admin)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert :ok = TenantGuard.guard_tenant!(@tenant_id_1, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end

    test "allows any tenant to access platform processes" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@tenant_id_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      # Any tenant can access :platform processes
      assert :ok = TenantGuard.guard_tenant!(:platform, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end
  end

  describe "guard_tenant!/1 (single arg)" do
    test "validates current process tenant" do
      TenantGuard.set_process_tenant(@tenant_id_1)

      assert :ok = TenantGuard.guard_tenant!(@tenant_id_1)
    end

    test "raises when current process tenant doesn't match" do
      TenantGuard.set_process_tenant(@tenant_id_1)

      assert_raise TenantViolation, fn ->
        TenantGuard.guard_tenant!(@tenant_id_2)
      end
    end
  end

  describe "validate_tenant/2" do
    test "returns :ok when tenants match" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@tenant_id_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert :ok = TenantGuard.validate_tenant(@tenant_id_1, caller_pid)

      send(caller_pid, :done)
    end

    test "returns error when tenants don't match" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@tenant_id_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert {:error, :tenant_mismatch} = TenantGuard.validate_tenant(@tenant_id_2, caller_pid)

      send(caller_pid, :done)
    end
  end

  describe "resolve_caller_tenant/1" do
    test "resolves tenant from local process dictionary" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@tenant_id_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert TenantGuard.resolve_caller_tenant(caller_pid) == @tenant_id_1

      send(caller_pid, :done)
    end

    test "returns nil for process without tenant set" do
      caller_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      assert TenantGuard.resolve_caller_tenant(caller_pid) == nil

      send(caller_pid, :done)
    end
  end

  describe "ash_opts/2" do
    test "adds tenant to options" do
      opts = TenantGuard.ash_opts(@tenant_id_1)

      assert opts[:tenant] == @tenant_id_1
    end

    test "merges with existing options" do
      opts = TenantGuard.ash_opts(@tenant_id_1, authorize?: false)

      assert opts[:tenant] == @tenant_id_1
      assert opts[:authorize?] == false
    end
  end

  describe "TenantViolation exception" do
    test "formats message correctly" do
      exception = %TenantViolation{
        message: "Cross-tenant access denied",
        expected: @tenant_id_1,
        actual: @tenant_id_2
      }

      message = Exception.message(exception)

      assert message =~ "Cross-tenant access denied"
      assert message =~ @tenant_id_1
      assert message =~ @tenant_id_2
    end
  end

  describe "__using__/1 macro" do
    defmodule TestServer do
      use GenServer
      use ServiceRadar.Cluster.TenantGuard

      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      def init(opts) do
        tenant_id = Keyword.fetch!(opts, :tenant_id)
        set_process_tenant(tenant_id)
        {:ok, %{tenant_id: tenant_id}}
      end

      def handle_call(:get_data, from, state) do
        guard_tenant!(state.tenant_id, from)
        {:reply, {:ok, :data}, state}
      end
    end

    test "guard_tenant! works in GenServer callback" do
      {:ok, server} = TestServer.start_link(tenant_id: @tenant_id_1)

      # Set caller tenant to match
      TenantGuard.set_process_tenant(@tenant_id_1)

      assert {:ok, :data} = GenServer.call(server, :get_data)

      GenServer.stop(server)
    end

    test "guard_tenant! raises in GenServer when tenant mismatch" do
      # Trap exits so the GenServer crash doesn't kill us
      Process.flag(:trap_exit, true)

      {:ok, server} = TestServer.start_link(tenant_id: @tenant_id_1)

      # Set caller tenant to different tenant
      TenantGuard.set_process_tenant(@tenant_id_2)

      # The exception is raised in the GenServer and propagates as an exit
      result =
        try do
          GenServer.call(server, :get_data)
        catch
          :exit, reason -> {:caught_exit, reason}
        end

      assert match?({:caught_exit, _}, result)
    end
  end
end
