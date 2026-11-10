defmodule ServiceRadar.Cluster.ClusterRPCTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Cluster.ClusterRPC
  alias ServiceRadar.Edge.AgentGatewaySync

  test "skips an older peer that returns :undef and succeeds on a capable peer without logging" do
    undef_exit =
      {:badrpc,
       {:EXIT,
        {:undef,
         [
           {AgentGatewaySync, :refresh_sweep_leases, ["agent-1", self()], []}
         ]}}}

    rpc_call = fn
      :core_old@host, AgentGatewaySync, :refresh_sweep_leases, ["agent-1", _], _timeout ->
        undef_exit

      :core_new@host, AgentGatewaySync, :refresh_sweep_leases, ["agent-1", _], _timeout ->
        :ok
    end

    log =
      capture_log(fn ->
        assert :ok =
                 ClusterRPC.call_unwrap(
                   [:core_old@host, :core_new@host],
                   AgentGatewaySync,
                   :refresh_sweep_leases,
                   ["agent-1", self()],
                   rpc_call: rpc_call,
                   undef_wait_ms: 0
                 )
      end)

    assert log == ""
  end

  test "waits boundedly when only an old peer exists and succeeds once a capable peer joins" do
    {:ok, state} = Agent.start_link(fn -> [:core_old@host] end)

    Task.start(fn ->
      Process.sleep(40)
      Agent.update(state, fn _ -> [:core_old@host, :core_new@host] end)
    end)

    rpc_call = fn
      :core_old@host, Mod, :new_fun, [:arg], _timeout ->
        {:badrpc, {:EXIT, {:undef, [{Mod, :new_fun, [:arg], []}]}}}

      :core_new@host, Mod, :new_fun, [:arg], _timeout ->
        {:ok, :from_capable_peer}
    end

    log =
      capture_log(fn ->
        assert {:ok, {:ok, :from_capable_peer}} =
                 ClusterRPC.call(
                   fn -> Agent.get(state, & &1) end,
                   Mod,
                   :new_fun,
                   [:arg],
                   rpc_call: rpc_call,
                   undef_wait_ms: 500,
                   undef_poll_ms: 15
                 )
      end)

    assert log == ""
  end

  test "returns {:error, :peer_too_old} without crashing or logging when bound expires" do
    rpc_call = fn :core_old@host, Mod, :new_fun, [:arg], _timeout ->
      {:badrpc, {:EXIT, {:undef, [{Mod, :new_fun, 1, []}]}}}
    end

    log =
      capture_log(fn ->
        assert {:error, :peer_too_old} =
                 ClusterRPC.call_unwrap(
                   [:core_old@host],
                   Mod,
                   :new_fun,
                   [:arg],
                   rpc_call: rpc_call,
                   undef_wait_ms: 30,
                   undef_poll_ms: 10
                 )
      end)

    assert log == ""
  end

  test "does not mistake an internal :undef inside the remote function for :peer_too_old" do
    internal_undef =
      {:badrpc,
       {:EXIT,
        {:undef,
         [
           {SomeInternalDependency, :missing_helper, [], []},
           {Mod, :new_fun, 1, [file: ~c"lib/mod.ex", line: 12]}
         ]}}}

    rpc_call = fn :core_new@host, Mod, :new_fun, [:arg], _timeout ->
      internal_undef
    end

    refute ClusterRPC.peer_too_old?(internal_undef, Mod, :new_fun, [:arg])

    assert {:error, {:EXIT, {:undef, [{SomeInternalDependency, :missing_helper, [], []} | _]}}} =
             ClusterRPC.call_unwrap(
               [:core_new@host],
               Mod,
               :new_fun,
               [:arg],
               rpc_call: rpc_call,
               undef_wait_ms: 0
             )
  end
end
