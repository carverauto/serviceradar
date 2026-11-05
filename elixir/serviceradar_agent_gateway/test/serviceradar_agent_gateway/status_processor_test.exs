defmodule ServiceRadarAgentGateway.StatusProcessorTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Ingestion.Admission
  alias ServiceRadarAgentGateway.ClusterProcessLocator
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers
  alias ServiceRadarAgentGateway.StatusProcessor

  setup do
    StatusHandlerTestHelpers.legacy_core_transport!()

    existing = Process.whereis(ServiceRadar.StatusHandler)

    if is_pid(existing) do
      StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)
    end

    on_exit(fn -> StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing) end)

    previous =
      for key <- [:admission_protocol_module, :admission_probe_test_pid, :admission_probe_delay_ms],
          do: {key, Application.get_env(:serviceradar_agent_gateway, key)}

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    if !Process.whereis(ClusterProcessLocator), do: start_supervised!(ClusterProcessLocator)
    reset_admission_protocol_cache()
    on_exit(&reset_admission_protocol_cache/0)
    :ok
  end

  test "reserved forwarding hands a summary to the core status lane through a reservation" do
    Application.delete_env(:serviceradar_agent_gateway, :reserved_core_admission)
    parent = self()

    start_status_lane!(fn status ->
      send(parent, {:ingested, status})
      :ok
    end)

    start_supervised!({ServiceRadar.StatusHandler, []})

    assert :ok = StatusProcessor.process(summary("agent"))
    assert_receive {:ingested, %{service_name: "agent", source: "status", message: ~s({"sidecars":[]})}}, 1_000
  end

  test "reserved forwarding tolerates a slow admission probe, caches positive results per node, and invalidates on nodedown" do
    Application.delete_env(:serviceradar_agent_gateway, :reserved_core_admission)
    parent = self()

    start_status_lane!(fn status ->
      send(parent, {:ingested, status.service_name})
      :ok
    end)

    Application.put_env(:serviceradar_agent_gateway, :admission_protocol_module, __MODULE__.SlowAdmissionProbeStub)
    Application.put_env(:serviceradar_agent_gateway, :admission_probe_test_pid, parent)
    Application.put_env(:serviceradar_agent_gateway, :admission_probe_delay_ms, 80)

    start_supervised!({ServiceRadar.StatusHandler, []})

    # The first status takes an 80ms probe and succeeds instead of being misclassified as
    # :core_admission_protocol_unavailable.
    assert :ok = StatusProcessor.process(summary("first"))
    assert_receive :admission_probe_called, 1_000
    assert_receive {:ingested, "first"}, 1_000

    # A cached :reserved_v1 for the node avoids re-probing on the hot path, even when a probe
    # would now exceed its timeout.
    Application.put_env(:serviceradar_agent_gateway, :admission_probe_delay_ms, 500)
    assert :ok = StatusProcessor.process(summary("second"))
    refute_receive :admission_probe_called, 50
    assert_receive {:ingested, "second"}, 1_000

    # A node disconnect invalidates the cached admission protocol entry.
    send(ClusterProcessLocator, {:nodedown, node()})
    _ = :sys.get_state(ClusterProcessLocator)

    Application.put_env(:serviceradar_agent_gateway, :admission_probe_delay_ms, 10)
    assert :ok = StatusProcessor.process(summary("third"))
    assert_receive :admission_probe_called, 1_000
    assert_receive {:ingested, "third"}, 1_000
  end

  test "reserved forwarding distinguishes admission probe timeout from unsupported protocol and never sends unreserved" do
    Application.delete_env(:serviceradar_agent_gateway, :reserved_core_admission)
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:status_update, status}} -> send(parent, {:unexpected_unreserved, status})
          {:"$gen_cast", {:status_update, status}} -> send(parent, {:unexpected_unreserved, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)
    on_exit(fn -> StatusHandlerTestHelpers.kill_and_await(handler_pid) end)

    Application.put_env(:serviceradar_agent_gateway, :admission_protocol_module, __MODULE__.SlowAdmissionProbeStub)
    Application.put_env(:serviceradar_agent_gateway, :admission_probe_test_pid, parent)
    Application.put_env(:serviceradar_agent_gateway, :admission_probe_delay_ms, 400)

    assert {:error, :core_admission_probe_timeout} = StatusProcessor.process(summary("agent"))
    refute_receive {:unexpected_unreserved, _status}, 50

    # A core module without admission_protocol/0 fails closed.
    Application.put_env(
      :serviceradar_agent_gateway,
      :admission_protocol_module,
      __MODULE__.UnsupportedAdmissionProbeStub
    )

    assert {:error, :core_admission_protocol_unavailable} = StatusProcessor.process(summary("agent"))
    refute_receive {:unexpected_unreserved, _status}, 50
  end

  test "unreserved forwarding casts the summary to the local core status handler" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} -> send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)
    on_exit(fn -> StatusHandlerTestHelpers.kill_and_await(handler_pid) end)

    assert :ok = StatusProcessor.process(summary("agent"))
    assert_receive {:forwarded, forwarded}
    assert forwarded.service_name == "agent"
    assert forwarded.message == ~s({"sidecars":[]})
    assert is_integer(forwarded.timestamp)
  end

  test "returns a forwarding error when no core status handler is reachable" do
    assert {:error, :not_available} = StatusProcessor.process(summary("agent"))
  end

  defp summary(service_name) do
    %{
      service_name: service_name,
      service_type: "agent",
      source: "status",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: ~s({"sidecars":[]})
    }
  end

  # The real lane under the name core's admission routes every status reservation to.
  defp start_status_lane!(processor) do
    if !Process.whereis(ServiceRadar.Ingestion.Registry) do
      start_supervised!({Registry, keys: :unique, name: ServiceRadar.Ingestion.Registry})
    end

    tasks = start_supervised!({Task.Supervisor, []}, id: :status_lane_tasks)

    start_supervised!(
      {ServiceRadar.Admission.Lane,
       [
         name: Admission.server(:status),
         lane: :status,
         task_supervisor: tasks,
         processor: processor,
         concurrency: 1,
         source_max_bytes: 1_024 * 1_024,
         gateway_max_ms: 15_000,
         config: [
           max_items: 4,
           max_bytes: 2 * 1_024 * 1_024,
           max_items_per_agent: 4,
           queue_wait_ms: 2_000,
           worker_timeout_ms: 10_000,
           gateway_call_timeout_ms: 15_000
         ]
       ]}
    )
  end

  defp reset_admission_protocol_cache do
    if locator = Process.whereis(ClusterProcessLocator) do
      send(locator, {:nodedown, node()})
      _ = :sys.get_state(locator)
    end

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.SlowAdmissionProbeStub do
  @moduledoc false
  def admission_protocol do
    send(
      Application.fetch_env!(:serviceradar_agent_gateway, :admission_probe_test_pid),
      :admission_probe_called
    )

    delay_ms = Application.get_env(:serviceradar_agent_gateway, :admission_probe_delay_ms, 0)

    if is_integer(delay_ms) and delay_ms > 0 do
      Process.sleep(delay_ms)
    end

    :reserved_v1
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.UnsupportedAdmissionProbeStub do
  @moduledoc false
end
