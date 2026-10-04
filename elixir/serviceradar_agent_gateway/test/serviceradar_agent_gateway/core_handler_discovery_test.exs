defmodule ServiceRadarAgentGateway.CoreHandlerDiscoveryTest do
  @moduledoc """
  Status forwarding against a real multi-node cluster: one peer hosts the core
  status handler, another peer is connected but does not answer at all (its OS
  process is stopped with SIGSTOP, which is what a hung or partitioned node
  looks like until the distribution tick gives up on it), and the handler can
  move between the two the way it does on a core coordinator failover.
  """
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.ClusterProcessLocator
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers
  alias ServiceRadarAgentGateway.StatusProcessor

  # Discovery probes wait up to 5s for each node. A push that waits on the hung
  # node therefore takes at least that long; one that does not is far quicker.
  @push_budget_ms 2_000

  setup do
    if !Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:core_handler_discovery_test, :shortnames])
      on_exit(fn -> :net_kernel.stop() end)
    end

    existing = Process.whereis(ServiceRadar.StatusHandler)
    StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)
    on_exit(fn -> StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing) end)

    previous_otlp = Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_module)

    Application.put_env(
      :serviceradar_agent_gateway,
      :otlp_relay_publisher_module,
      __MODULE__.DisabledOtlpRelayPublisherStub
    )

    on_exit(fn ->
      if previous_otlp do
        Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher_module, previous_otlp)
      else
        Application.delete_env(:serviceradar_agent_gateway, :otlp_relay_publisher_module)
      end
    end)

    # Connected first, so it is probed no later than the node that answers.
    {spare_peer, spare_node} = start_peer(:discovery_spare)
    {core_peer, core_node} = start_peer(:discovery_core)
    install_status_handler(core_peer)

    if !Process.whereis(ClusterProcessLocator), do: start_supervised!(ClusterProcessLocator)

    %{spare_peer: spare_peer, spare_node: spare_node, core_peer: core_peer, core_node: core_node}
  end

  test "a status push is not delayed by a connected node that never answers", context do
    assert context.spare_node in Node.list()
    assert context.core_node in Node.list()

    with_stopped_peer(context.spare_peer, fn ->
      {elapsed_ms, result} = timed(fn -> StatusProcessor.process(status("first")) end)
      assert result == :ok
      assert_receive {:core_status_update, %{message: "first"}}, 1_000
      assert elapsed_ms < @push_budget_ms, "first push took #{elapsed_ms}ms"

      {elapsed_ms, result} = timed(fn -> StatusProcessor.process(status("second")) end)
      assert result == :ok
      assert_receive {:core_status_update, %{message: "second"}}, 1_000
      assert elapsed_ms < @push_budget_ms, "second push took #{elapsed_ms}ms"
    end)
  end

  test "a push follows the status handler when it moves to another node", context do
    assert :ok = StatusProcessor.process(status("before"))
    assert_receive {:core_status_update, %{message: "before"}}, 1_000

    old_handler = :peer.call(context.core_peer, Process, :whereis, [ServiceRadar.StatusHandler])
    assert node(old_handler) == context.core_node
    kill_and_await(old_handler)
    install_status_handler(context.spare_peer)

    assert_eventually(fn ->
      ClusterProcessLocator.nodes(ServiceRadar.StatusHandler) == [context.spare_node]
    end)

    assert :ok = StatusProcessor.process(status("after"))
    assert_receive {:core_status_update, %{message: "after"}}, 1_000
  end

  defp assert_eventually(check, attempts \\ 50) do
    cond do
      check.() ->
        :ok

      attempts > 1 ->
        Process.sleep(20)
        assert_eventually(check, attempts - 1)

      true ->
        flunk("condition never held")
    end
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  defp status(message) do
    %{
      service_name: "agent",
      service_type: "agent",
      source: "status",
      agent_id: "agent-discovery-1",
      gateway_id: "gateway-discovery-1",
      partition: "default",
      message: message
    }
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp start_peer(prefix) do
    name = :"#{prefix}_#{System.unique_integer([:positive])}"

    peer =
      start_supervised!(%{
        id: name,
        start:
          {:peer, :start_link,
           [
             %{
               name: name,
               connection: :standard_io,
               args: [~c"+S", ~c"1", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
             }
           ]},
        restart: :temporary
      })

    node = :peer.call(peer, :erlang, :node, [])
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    assert Node.connect(node)
    {peer, node}
  end

  # The handler runs on the peer and relays every status it is sent back here,
  # which is the observable proof that the gateway reached the right node.
  defp install_status_handler(peer) do
    if !:peer.call(peer, :code, :is_loaded, [__MODULE__.RelayHandler]) do
      :peer.call(peer, Code, :compile_string, [
        """
        defmodule #{inspect(__MODULE__.RelayHandler)} do
          def start(owner) do
            pid = spawn(fn -> loop(owner) end)
            Process.register(pid, ServiceRadar.StatusHandler)
            pid
          end

          defp loop(owner) do
            receive do
              {:"$gen_cast", {:status_update, status}} ->
                send(owner, {:core_status_update, status})
                loop(owner)
            end
          end
        end
        """
      ])
    end

    :peer.call(peer, __MODULE__.RelayHandler, :start, [self()])
  end

  # SIGSTOP keeps the distribution connection up (the tick timeout is far longer
  # than the test) while the node answers nothing. Resume it before the peer is
  # shut down: :peer.stop/1 talks to the node over stdio.
  defp with_stopped_peer(peer, fun) do
    os_pid = :peer.call(peer, :os, :getpid, [])
    {_, 0} = System.cmd("kill", ["-STOP", to_string(os_pid)])

    try do
      fun.()
    after
      System.cmd("kill", ["-CONT", to_string(os_pid)])
    end
  end

  defmodule DisabledOtlpRelayPublisherStub do
    @moduledoc false
    def publish_relay(_status), do: :disabled
  end
end
