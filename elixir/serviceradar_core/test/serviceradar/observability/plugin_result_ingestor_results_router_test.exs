defmodule ServiceRadar.Observability.PluginResultIngestorResultsRouterTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "results router leaves plugin result state ownership with the plugin ingestor" do
    previous_ingestor =
      Application.get_env(:serviceradar_core, :plugin_result_ingestor)

    Application.put_env(
      :serviceradar_core,
      :plugin_result_ingestor,
      PluginResultIngestor
    )

    on_exit(fn -> restore_env(:plugin_result_ingestor, previous_ingestor) end)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    enclosing_timestamp = DateTime.add(observed_at, 10, :second)
    :ok = ServiceStatusPubSub.subscribe()

    routed_status =
      Map.merge(status, %{
        available: true,
        agent_timestamp: enclosing_timestamp,
        message: Jason.encode!(payload)
      })

    assert {:reply, :ok, %{}} =
             ResultsRouter.handle_call({:results_update, routed_status}, self(), %{})

    assert [[reported_at, true, "edge plugin completed", _details] = reported_row] =
             history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    succeeded_at = marker_timestamp(reported_at, 1, "succeeded")

    assert [[true, "edge plugin completed", ^succeeded_at]] =
             current_state_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 1,
               "observation_timestamp" => observation_timestamp,
               "status" => "succeeded"
             }
           } = status |> current_state_details() |> Jason.decode!()

    assert observation_timestamp == DateTime.to_iso8601(observed_at)
    refute succeeded_at == enclosing_timestamp

    assert_receive {:service_status_updated,
                    %ServiceStatus{
                      agent_id: agent_id,
                      gateway_id: gateway_id,
                      timestamp: ^reported_at
                    }}

    assert agent_id == status.agent_id
    assert gateway_id == status.gateway_id
    refute_receive {:service_status_updated, _duplicate}, 50
  end

  test "buffered results router persists and broadcasts through the plugin ingestor" do
    previous_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    previous_batching = Application.get_env(:serviceradar_core, :results_router_batching)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor, PluginResultIngestor)
    Application.put_env(:serviceradar_core, :results_router_batching, true)

    on_exit(fn ->
      restore_env(:plugin_result_ingestor, previous_ingestor)
      restore_env(:results_router_batching, previous_batching)
    end)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    :ok = ServiceStatusPubSub.subscribe()

    routed_status =
      Map.merge(status, %{
        available: true,
        agent_timestamp: DateTime.add(observed_at, 15, :second),
        message: Jason.encode!(payload)
      })

    initial_state = %{buffer: [], buffer_size: 0, timer: nil}

    assert {:noreply, buffered_state} =
             ResultsRouter.handle_cast({:results_update, routed_status}, initial_state)

    assert buffered_state.buffer_size == 1
    assert [] = history_rows(status)

    assert {:noreply, flushed_state} = ResultsRouter.handle_info(:flush_results, buffered_state)
    if is_reference(flushed_state.timer), do: Process.cancel_timer(flushed_state.timer)

    assert [[reported_at, true, "edge plugin completed", _] = reported_row] =
             history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    succeeded_at = marker_timestamp(reported_at, 1, "succeeded")
    assert [[true, "edge plugin completed", ^succeeded_at]] = current_state_rows(status)

    assert_receive {:service_status_updated, %ServiceStatus{timestamp: ^reported_at}}
    refute_receive {:service_status_updated, _duplicate}, 50
  end
end
