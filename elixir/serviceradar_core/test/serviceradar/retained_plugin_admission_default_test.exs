defmodule ServiceRadar.RetainedPluginAdmissionDefaultTest do
  @moduledoc """
  Capability-retained plugin results are admitted by the retained-plugin lane
  unless `retained_plugin_admission_enabled` is explicitly false.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.StatusHandler
  alias ServiceRadar.TestSupport

  defmodule HeldPluginIngestor do
    @moduledoc false
    def ingest(_payload, _status) do
      test_pid = Application.fetch_env!(:serviceradar_core, :retained_default_test_pid)
      send(test_pid, {:plugin_ingest_started, self()})

      receive do
        :release_plugin -> :ok
      end
    end
  end

  setup do
    original_handler = Application.get_env(:serviceradar_core, StatusHandler)
    original_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    original_pid = Application.get_env(:serviceradar_core, :retained_default_test_pid)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor, HeldPluginIngestor)
    Application.put_env(:serviceradar_core, :retained_default_test_pid, self())

    on_exit(fn ->
      restore_env(StatusHandler, original_handler)
      restore_env(:plugin_result_ingestor, original_ingestor)
      restore_env(:retained_default_test_pid, original_pid)
    end)

    :ok
  end

  test "without configuration, a capability-retained plugin result is ingested by the lane" do
    lane = start_retained_lane!(max_items_per_agent: 8)
    Application.put_env(:serviceradar_core, StatusHandler, retained_plugin_lane: lane)
    handler = start_handler!()

    call =
      Task.async(fn ->
        GenServer.call(handler, {:status_update, retained_plugin_status()}, 5_000)
      end)

    assert_receive {:plugin_ingest_started, worker}, 1_000
    refute worker == handler

    send(worker, :release_plugin)
    assert {:ok, :ok} = Task.yield(call, 1_000)
  end

  test "a full lane rejects at once instead of queueing behind held work" do
    lane = start_retained_lane!(max_items_per_agent: 1)
    Application.put_env(:serviceradar_core, StatusHandler, retained_plugin_lane: lane)
    handler = start_handler!()

    held =
      Task.async(fn ->
        GenServer.call(handler, {:status_update, retained_plugin_status()}, 5_000)
      end)

    assert_receive {:plugin_ingest_started, worker}, 1_000

    assert {:error, :per_agent_full} =
             GenServer.call(handler, {:status_update, retained_plugin_status()}, 500)

    send(worker, :release_plugin)
    assert {:ok, :ok} = Task.yield(held, 1_000)
  end

  test "the kill switch sends capability-retained results down the bounded compatibility lane" do
    TestSupport.start_ingestion_topology!()

    Application.put_env(:serviceradar_core, StatusHandler,
      retained_plugin_admission_enabled: false
    )

    handler = Process.whereis(StatusHandler)

    call =
      Task.async(fn ->
        GenServer.call(handler, {:status_update, retained_plugin_status()}, 5_000)
      end)

    assert_receive {:plugin_ingest_started, worker}, 1_000
    refute worker == handler
    assert Task.yield(call, 100) == nil

    send(worker, :release_plugin)
    assert {:ok, :ok} = Task.yield(call, 1_000)
  end

  defp start_handler! do
    {:ok, handler} = GenServer.start_link(StatusHandler, %{})
    handler
  end

  defp start_retained_lane!(overrides) do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    config =
      Keyword.merge(
        [
          max_items: 32,
          max_bytes: 64 * 1_024 * 1_024,
          max_items_per_agent: 8,
          queue_wait_ms: 100,
          worker_timeout_ms: 3_000,
          gateway_call_timeout_ms: 6_100
        ],
        overrides
      )

    start_supervised!(
      {ServiceRadar.Admission.RetainedPluginLane,
       name: Module.concat(__MODULE__, "lane_#{System.unique_integer([:positive])}"),
       task_supervisor: task_supervisor,
       config: config}
    )
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
