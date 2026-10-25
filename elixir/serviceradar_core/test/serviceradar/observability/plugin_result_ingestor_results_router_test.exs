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
    enclosing_timestamp = DateTime.shift(observed_at, second: 10)
    :ok = ServiceStatusPubSub.subscribe()

    routed_status =
      Map.merge(status, %{
        available: true,
        agent_timestamp: enclosing_timestamp,
        message: Jason.encode!(payload)
      })

    assert :ok = ServiceRadar.Ingestion.ResultIngestor.process_and_publish(routed_status)

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

  test "retained supervised delivery keeps plugin history and state under the plugin ingestor" do
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
        agent_timestamp: DateTime.shift(observed_at, second: 15),
        message: Jason.encode!(payload)
      })

    ServiceRadar.TestSupport.start_ingestion_topology!()
    routed_status = Map.put(routed_status, :delivery_capabilities, ["plugin-result-retained:v1"])
    assert [] = history_rows(status)

    assert :ok =
             GenServer.call(ServiceRadar.StatusHandler, {:status_update, routed_status}, 5_000)

    assert [[reported_at, true, "edge plugin completed", _] = reported_row] =
             history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    succeeded_at = marker_timestamp(reported_at, 1, "succeeded")
    assert [[true, "edge plugin completed", ^succeeded_at]] = current_state_rows(status)

    assert_receive {:service_status_updated, %ServiceStatus{timestamp: ^reported_at}}
    refute_receive {:service_status_updated, _duplicate}, 50
  end

  test "retained delivery quarantines a handler that repeatedly exceeds the worker budget and still ingests subsequent results" do
    alias ServiceRadar.Admission.Lane
    alias ServiceRadar.Admission.RetainedPluginLane
    alias ServiceRadar.Observability.PluginResultQuarantine

    defmodule SlowBudgetHandler do
      @moduledoc false
      def supports?(payload, _status),
        do: Map.get(payload, "summary") == "budget-exceeding-result"

      def ingest(_payload, _status, _opts) do
        if pid = Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_pid) do
          send(pid, :slow_budget_handler_attempted)
        end

        Process.sleep(2_000)
        :ok
      end
    end

    previous_ingestor = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    previous_max = Application.get_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts)

    Application.put_env(:serviceradar_core, :plugin_result_ingestor, PluginResultIngestor)
    Application.put_env(:serviceradar_core, :plugin_result_quarantine_max_timeouts, 2)
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [SlowBudgetHandler])
    PluginResultQuarantine.clear_all!()

    on_exit(fn ->
      PluginResultQuarantine.clear_all!()
      restore_env(:plugin_result_ingestor, previous_ingestor)
      restore_env(:plugin_result_quarantine_max_timeouts, previous_max)
    end)

    {slow_payload, slow_status, slow_observed_at} = plugin_result_fixture()
    slow_payload = Map.put(slow_payload, "summary", "budget-exceeding-result")

    slow_routed =
      Map.merge(slow_status, %{
        available: true,
        agent_timestamp: DateTime.shift(slow_observed_at, second: 15),
        message: Jason.encode!(slow_payload),
        delivery_capabilities: ["plugin-result-retained:v1"]
      })

    {good_payload, good_status, good_observed_at} = plugin_result_fixture()

    good_routed =
      Map.merge(good_status, %{
        available: true,
        agent_timestamp: DateTime.shift(good_observed_at, second: 15),
        message: Jason.encode!(good_payload),
        delivery_capabilities: ["plugin-result-retained:v1"]
      })

    task_sup =
      start_supervised!(
        {Task.Supervisor, name: :"db_test_retained_task_#{System.unique_integer([:positive])}"},
        id: {:db_task_sup, System.unique_integer([:positive])}
      )

    lease_sup =
      start_supervised!(
        {Task.Supervisor, name: :"db_test_retained_lease_#{System.unique_integer([:positive])}"},
        id: {:db_lease_sup, System.unique_integer([:positive])}
      )

    lane =
      start_supervised!(
        {RetainedPluginLane,
         name: :"db_test_retained_lane_#{System.unique_integer([:positive])}",
         task_supervisor: task_sup,
         lease_supervisor: lease_sup,
         config: [
           max_items: 8,
           max_bytes: 1_024 * 1_024,
           max_items_per_agent: 4,
           queue_wait_ms: 1_000,
           worker_timeout_ms: 500,
           gateway_call_timeout_ms: 15_000
         ]},
        id: {:db_lane, System.unique_integer([:positive])}
      )

    admit_and_await = fn st ->
      reply_ref = make_ref()
      assert :ok = Lane.admit(lane, st, {self(), reply_ref})
      assert_receive {^reply_ref, result}, 5_000
      result
    end

    assert {:error, :execution_timeout} = admit_and_await.(slow_routed)
    assert_receive :slow_budget_handler_attempted, 2_000

    assert {:error, :execution_timeout} = admit_and_await.(slow_routed)
    assert_receive :slow_budget_handler_attempted, 2_000

    quarantined = PluginResultQuarantine.get_attempt_for_status(slow_routed)
    assert quarantined.state == "quarantined"
    assert quarantined.attempt_count == 2
    assert quarantined.consecutive_timeout_count == 2
    assert quarantined.quarantine_reason == "execution_timeout_budget_exceeded"
    assert quarantined.payload_bytes == byte_size(slow_routed.message)

    # Redelivery does not run handlers again and acknowledges :ok
    assert :ok = admit_and_await.(slow_routed)
    refute_receive :slow_budget_handler_attempted, 80

    # Later result is ingested
    assert :ok = admit_and_await.(good_routed)
    assert [[_reported_at, true, "edge plugin completed", _]] = history_rows(good_status)
  end
end
