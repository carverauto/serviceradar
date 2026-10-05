defmodule ServiceRadar.StatusAdmissionIsolationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Admission.Lane
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch
  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.StatusHandler

  defmodule HeldPluginIngestor do
    @moduledoc false
    def ingest(_payload, _status) do
      {test_pid, release_ref} =
        Application.fetch_env!(:serviceradar_core, :status_admission_held_plugin)

      send(test_pid, {:plugin_ingest_started, release_ref, self()})

      receive do
        {:release_plugin, ^release_ref} ->
          send(test_pid, {:plugin_ingest_finished, release_ref})
          :ok
      end
    end
  end

  setup do
    parent = self()
    release_ref = make_ref()

    original_handler = Application.get_env(:serviceradar_core, StatusHandler, [])

    original_queue =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_server)

    original_async = Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_async)
    original_plugin_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)

    original_plugin_holder =
      Application.get_env(:serviceradar_core, :status_admission_held_plugin)

    Application.put_env(:serviceradar_core, StatusHandler,
      flow_attribution_publisher: {__MODULE__, :held_flow_persist, [parent, release_ref]}
    )

    Application.put_env(:serviceradar_core, :plugin_result_ingestor, HeldPluginIngestor)
    Application.put_env(:serviceradar_core, :status_admission_held_plugin, {parent, release_ref})

    endpoint_queue = spawn_link(fn -> endpoint_queue_loop() end)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true)

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_queue_server,
      endpoint_queue
    )

    topology = ServiceRadar.TestSupport.start_ingestion_topology!()

    on_exit(fn ->
      restore_env(StatusHandler, original_handler)
      restore_env(:endpoint_inventory_ingestor_queue_server, original_queue)
      restore_env(:endpoint_inventory_ingestor_async, original_async)
      restore_env(:plugin_result_ingestor, original_plugin_ingestor)
      restore_env(:status_admission_held_plugin, original_plugin_holder)
    end)

    %{handler: StatusHandler, release_ref: release_ref, topology: topology}
  end

  test "worker-tree downtime rejects admission without restarting the dispatcher", %{
    topology: topology
  } do
    handler = Process.whereis(StatusHandler)

    status = %{
      source: "synthetic-heartbeat",
      service_name: "agent",
      agent_id: "agent01",
      partition: "test-partition",
      message: nil
    }

    descriptor = Lane.descriptor(status, 15_000)

    assert :ok = Supervisor.terminate_child(topology, ServiceRadar.Ingestion.Supervisor)

    assert {:error, {:admission_lane_unavailable, :noproc}} =
             GenServer.call(handler, {:reserve_status, descriptor}, 500)

    assert Process.whereis(StatusHandler) == handler
    assert Process.alive?(handler)

    assert {:ok, _workers} =
             Supervisor.restart_child(topology, ServiceRadar.Ingestion.Supervisor)

    assert {:ok, {lane, _reservation}} =
             GenServer.call(handler, {:reserve_status, descriptor}, 500)

    assert Process.alive?(lane)
    assert Process.whereis(StatusHandler) == handler
  end

  test "held retained plugin ingestion does not delay flow completion", %{
    handler: handler,
    release_ref: release_ref
  } do
    Application.put_env(
      :serviceradar_core,
      StatusHandler,
      Keyword.put(
        Application.get_env(:serviceradar_core, StatusHandler, []),
        :flow_attribution_publisher,
        {__MODULE__, :persist_flow_immediately, [self()]}
      )
    )

    plugin_call =
      Task.async(fn ->
        GenServer.call(handler, {:status_update, retained_plugin_status()}, 5_000)
      end)

    assert_receive {:plugin_ingest_started, ^release_ref, plugin_worker}

    assert :ok = GenServer.call(handler, {:status_update, flow_status()}, 500)
    assert_receive :flow_persisted_immediately
    refute Task.yield(plugin_call, 0)

    send(plugin_worker, {:release_plugin, release_ref})
    assert {:ok, :ok} = Task.yield(plugin_call, 1_000)
  end

  test "capability-retained casts use the bounded plugin lane", %{
    handler: handler,
    release_ref: release_ref
  } do
    GenServer.cast(handler, {:status_update, retained_plugin_status()})

    assert_receive {:plugin_ingest_started, ^release_ref, plugin_worker}
    send(plugin_worker, {:release_plugin, release_ref})
    assert_receive {:plugin_ingest_finished, ^release_ref}
  end

  test "held flow persistence does not block unrelated status admission", %{
    handler: handler,
    release_ref: release_ref
  } do
    flow_call =
      Task.async(fn ->
        GenServer.call(handler, {:status_update, flow_status()}, 5_000)
      end)

    assert_receive {:flow_persist_started, ^release_ref, flow_worker}

    unrelated_statuses = [
      %{source: "workload-identity", message: nil},
      %{source: "addon:test", message: nil},
      %{source: "plugin:test", message: nil},
      %{service_name: "agent", message: nil},
      %{
        source: "results",
        service_type: "endpoint_inventory",
        message: Jason.encode!(%{"scan_id" => "scan-1"})
      }
    ]

    for status <- unrelated_statuses do
      reply = Task.async(fn -> GenServer.call(handler, {:status_update, status}, 500) end)
      assert {:ok, _result} = Task.yield(reply, 250)
    end

    refute Task.yield(flow_call, 0)
    send(flow_worker, {:release_flow, release_ref})
    assert {:ok, :ok} = Task.yield(flow_call, 1_000)
  end

  def held_flow_persist(_events, _partition, _agent_id, test_pid, release_ref) do
    send(test_pid, {:flow_persist_started, release_ref, self()})

    receive do
      {:release_flow, ^release_ref} -> :ok
    end
  end

  def persist_flow_immediately(_events, _partition, _agent_id, test_pid) do
    send(test_pid, :flow_persisted_immediately)
    :ok
  end

  defp flow_status do
    %{
      source: "flow-attribution",
      service_type: "passive-netprobe",
      service_name: "flow-attribution",
      agent_id: "agent-a",
      partition: "prod-east",
      message:
        FlowAttributionEventBatch.encode(%FlowAttributionEventBatch{
          events: [],
          dropped_since_last: 1
        })
    }
  end

  defp retained_plugin_status do
    %{
      source: "plugin-result",
      service_type: "plugin",
      service_name: "example",
      agent_id: "agent-a",
      delivery_capabilities: ["plugin-result-retained:v1"],
      message: Jason.encode!(%{"status" => "OK", "summary" => "plugin result"})
    }
  end

  defp endpoint_queue_loop do
    receive do
      {:"$gen_call", from, {:enqueue, _payload, _opts, {:reply_to, reply_to}, _timeout}} ->
        GenServer.reply(from, :ok)
        GenServer.reply(reply_to, :ok)
        endpoint_queue_loop()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
