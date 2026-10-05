defmodule ServiceRadar.StatusHandlerOffSingletonTest do
  @moduledoc """
  StatusHandler hands database work to queues and callers to the router; it does
  no writes and no waiting of its own.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.ResultIngestion
  alias ServiceRadar.ResultsRouter
  alias ServiceRadar.StatusHandler

  defmodule HeldPluginIngestor do
    @moduledoc false
    def ingest(_payload, _status) do
      test_pid = Application.fetch_env!(:serviceradar_core, :off_singleton_test_pid)
      send(test_pid, {:plugin_ingest_started, self()})

      receive do
        :release -> :ok
      end
    end
  end

  setup do
    keys = [:plugin_result_ingestor, :off_singleton_test_pid, :results_router_batching]
    previous = Map.new(keys, &{&1, Application.fetch_env(:serviceradar_core, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_core, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_core, key)
      end)
    end)

    Application.put_env(:serviceradar_core, :off_singleton_test_pid, self())
    Application.put_env(:serviceradar_core, :results_router_batching, false)

    if !Process.whereis(ResultIngestion), do: start_supervised!(ResultIngestion)

    test_pid = self()
    handler_id = "off-singleton-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:serviceradar, :result_ingestion, :execution],
        [:serviceradar, :result_ingestion, :crash]
      ],
      fn _event, _measurements, %{class: class}, _ ->
        send(test_pid, {:ingested_by_queue, class})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, handler} = GenServer.start_link(StatusHandler, %{})
    %{handler: handler}
  end

  test "a workload identity snapshot is written by its queue, not the handler", %{
    handler: handler
  } do
    GenServer.cast(
      handler,
      {:status_update, %{source: "workload-identity", agent_id: "agent-a", message: nil}}
    )

    assert_receive {:ingested_by_queue, :workload_identity}, 1_000
  end

  test "add-on status from an agent status is written by its queue, not the handler", %{
    handler: handler
  } do
    GenServer.cast(
      handler,
      {:status_update, %{service_name: "agent", agent_id: "agent-a", message: nil}}
    )

    assert_receive {:ingested_by_queue, :addon_status}, 1_000
  end

  test "a result sent by call does not hold the handler while it is ingested", %{handler: handler} do
    Application.put_env(:serviceradar_core, :plugin_result_ingestor, HeldPluginIngestor)
    start_router!()

    plugin_call =
      Task.async(fn -> GenServer.call(handler, {:status_update, plugin_status()}, 5_000) end)

    assert_receive {:plugin_ingest_started, plugin_worker}, 1_000

    # The handler answers other work while the plugin ingest is held.
    _reply =
      GenServer.call(
        handler,
        {:status_update, %{source: "workload-identity", agent_id: "agent-b", message: nil}},
        500
      )

    send(plugin_worker, :release)
    assert {:ok, :ok} = Task.yield(plugin_call, 1_000)
  end

  defp start_router! do
    if Process.whereis(ResultsRouter), do: flunk("a ResultsRouter is already registered")
    {:ok, router} = GenServer.start_link(ResultsRouter, %{}, name: ResultsRouter)

    on_exit(fn ->
      if Process.alive?(router), do: Process.exit(router, :kill)
    end)

    router
  end

  # Not capability-retained, so it is not taken by the retained-plugin lane.
  defp plugin_status do
    %{
      source: "plugin-result",
      service_type: "plugin",
      service_name: "example",
      agent_id: "agent-a",
      message: Jason.encode!(%{"status" => "OK", "summary" => "plugin result"})
    }
  end
end
