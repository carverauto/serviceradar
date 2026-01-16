defmodule ServiceRadar.Cluster.TenantGuardTest do
  use ExUnit.Case, async: true

  # DB connection's search_path determines the schema
  # This module validates inter-process communication using markers like :instance or :platform

  alias ServiceRadar.Cluster.TenantGuard
  alias ServiceRadar.Cluster.TenantViolation

  @marker_1 :instance
  @marker_2 :other_instance

  describe "set_process_tenant/1 and get_process_tenant/0" do
    test "sets and gets marker for current process" do
      assert TenantGuard.get_process_tenant() == nil

      :ok = TenantGuard.set_process_tenant(@marker_1)

      assert TenantGuard.get_process_tenant() == @marker_1
    end

    test "supports atom markers for platform/admin" do
      :ok = TenantGuard.set_process_tenant(:platform)

      assert TenantGuard.get_process_tenant() == :platform
    end
  end

  describe "guard_tenant!/2" do
    test "allows access when caller marker matches expected marker" do
      # Start a process with a specific marker
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@marker_1)

          receive do
            :done -> :ok
          end
        end)

      # Give process time to set marker
      Process.sleep(10)

      # Should not raise
      assert :ok = TenantGuard.guard_tenant!(@marker_1, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end

    test "raises TenantViolation when markers don't match" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@marker_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert_raise TenantViolation, ~r/Cross-process access denied/, fn ->
        TenantGuard.guard_tenant!(@marker_2, {caller_pid, make_ref()})
      end

      send(caller_pid, :done)
    end

    test "allows platform marker to access any marker" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(:platform)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      # Platform can access any marker
      assert :ok = TenantGuard.guard_tenant!(@marker_1, {caller_pid, make_ref()})
      assert :ok = TenantGuard.guard_tenant!(@marker_2, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end

    test "allows super_admin marker to access any marker" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(:super_admin)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert :ok = TenantGuard.guard_tenant!(@marker_1, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end

    test "allows any marker to access platform processes" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@marker_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      # Any marker can access :platform processes
      assert :ok = TenantGuard.guard_tenant!(:platform, {caller_pid, make_ref()})

      send(caller_pid, :done)
    end
  end

  describe "guard_tenant!/1 (single arg)" do
    test "validates current process marker" do
      TenantGuard.set_process_tenant(@marker_1)

      assert :ok = TenantGuard.guard_tenant!(@marker_1)
    end

    test "raises when current process marker doesn't match" do
      TenantGuard.set_process_tenant(@marker_1)

      assert_raise TenantViolation, fn ->
        TenantGuard.guard_tenant!(@marker_2)
      end
    end
  end

  describe "validate_tenant/2" do
    test "returns :ok when markers match" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@marker_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert :ok = TenantGuard.validate_tenant(@marker_1, caller_pid)

      send(caller_pid, :done)
    end

    test "returns error when markers don't match" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@marker_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert {:error, :marker_mismatch} = TenantGuard.validate_tenant(@marker_2, caller_pid)

      send(caller_pid, :done)
    end
  end

  describe "resolve_caller_tenant/1" do
    test "resolves marker from local process dictionary" do
      caller_pid =
        spawn(fn ->
          TenantGuard.set_process_tenant(@marker_1)

          receive do
            :done -> :ok
          end
        end)

      Process.sleep(10)

      assert TenantGuard.resolve_caller_tenant(caller_pid) == @marker_1

      send(caller_pid, :done)
    end

    test "returns nil for process without marker set" do
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

  describe "TenantViolation exception" do
    test "formats message correctly" do
      exception = %TenantViolation{
        message: "Cross-process access denied",
        expected: @marker_1,
        actual: @marker_2
      }

      message = Exception.message(exception)

      assert message =~ "Cross-process access denied"
      assert message =~ inspect(@marker_1)
      assert message =~ inspect(@marker_2)
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
        marker = Keyword.fetch!(opts, :marker)
        set_process_tenant(marker)
        {:ok, %{marker: marker}}
      end

      def handle_call(:get_data, from, state) do
        guard_tenant!(state.marker, from)
        {:reply, {:ok, :data}, state}
      end
    end

    test "guard_tenant! works in GenServer callback" do
      {:ok, server} = TestServer.start_link(marker: @marker_1)

      # Set caller marker to match
      TenantGuard.set_process_tenant(@marker_1)

      assert {:ok, :data} = GenServer.call(server, :get_data)

      GenServer.stop(server)
    end

    test "guard_tenant! raises in GenServer when marker mismatch" do
      # Trap exits so the GenServer crash doesn't kill us
      Process.flag(:trap_exit, true)

      {:ok, server} = TestServer.start_link(marker: @marker_1)

      # Set caller marker to different marker
      TenantGuard.set_process_tenant(@marker_2)

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
