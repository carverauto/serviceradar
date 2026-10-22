defmodule ServiceRadar.Observability.PluginResultIngestorReplayTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "records downstream handler failures as the current unavailable state" do
    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert_receive {:failing_handler_ingest, ^payload}

    assert [
             [reported_at, true, "edge plugin completed", _reported_details] = reported_row,
             [failed_at, false, failure_message, details] = failure_row
           ] = history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)
    failure_marker = assert_handler_marker_in_block(failure_row, reported_at, observed_at)
    assert failure_marker["status"] == "failed"

    assert failure_message ==
             "Plugin result downstream ingest failed: " <>
               "ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler"

    assert %{
             "downstream_ingest" => %{
               "status" => "failed",
               "generation" => 1,
               "handler_set" => %{
                 "id" => handler_set_id,
                 "version" => 1
               },
               "observation_timestamp" => observation_timestamp,
               "handlers" => [
                 %{
                   "handler" =>
                     "ServiceRadar.Observability.PluginResultIngestorTest.FailingHandler",
                   "error" => ":forced_failure"
                 }
               ]
             },
             "reported_result" => ^payload
           } = Jason.decode!(details)

    assert is_binary(handler_set_id)
    assert byte_size(handler_set_id) == 64
    assert observation_timestamp == DateTime.to_iso8601(observed_at)

    assert [[false, ^failure_message, ^failed_at]] = current_state_rows(status)
  end

  test "duplicate observations rerun handlers without duplicating history" do
    {payload, status, observed_at} = plugin_result_fixture()
    :ok = ServiceStatePubSub.subscribe()

    expected_error =
      {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}}

    assert ^expected_error = PluginResultIngestor.ingest(payload, status)
    assert_receive {:service_state_updated, _state}

    assert ^expected_error = PluginResultIngestor.ingest(payload, status)
    refute_receive {:service_state_updated, _state}, 50

    assert_receive {:failing_handler_ingest, ^payload}
    assert_receive {:failing_handler_ingest, ^payload}

    assert [reported_row, [failed_at, false, _, _] = failure_row] = history_rows(status)
    reported_at = assert_reported_event_block(reported_row, observed_at)

    assert %{"status" => "failed"} =
             assert_handler_marker_in_block(failure_row, reported_at, observed_at)

    assert failed_at == marker_timestamp(reported_at, 1, "failed")
  end

  test "interrupted deliveries are recorded, then the result is quarantined" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [InterruptingHandler])
    {payload, status, observed_at} = plugin_result_fixture()

    for _delivery <- 1..3, do: interrupted_delivery!(payload, status)

    assert {:error, {:plugin_result_handlers_failed, [{PluginResultIngestor, quarantine_error}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert quarantine_error ==
             "downstream ingest did not complete in 3 deliveries; result quarantined"

    refute_received {:interrupting_handler_ingest, _pid}

    assert [reported_row | marker_rows] = history_rows(status)
    reported_at = assert_reported_event_block(reported_row, observed_at)

    assert [
             %{"status" => "failed", "delivery" => %{"disposition" => "interrupted"} = first},
             %{"status" => "failed", "delivery" => %{"disposition" => "interrupted"} = second},
             %{"status" => "failed", "delivery" => %{"disposition" => "quarantined"} = quarantine}
           ] =
             Enum.map(marker_rows, &assert_handler_marker_in_block(&1, reported_at, observed_at))

    assert [1, 2, 3] = Enum.map([first, second, quarantine], & &1["interrupted_deliveries"])

    quarantine_message =
      "Plugin result quarantined: downstream ingest did not complete in 3 deliveries"

    assert [[false, ^quarantine_message, _quarantined_at]] = current_state_rows(status)

    assert %{"reported_result" => ^payload} =
             status |> current_state_details() |> Jason.decode!()

    # The quarantine is the committed outcome: a further redelivery answers with
    # it again and neither runs the handlers nor writes.
    assert {:error, {:plugin_result_handlers_failed, [{PluginResultIngestor, ^quarantine_error}]}} =
             PluginResultIngestor.ingest(payload, status)

    refute_received {:interrupting_handler_ingest, _pid}
    assert length(history_rows(status)) == 1 + length(marker_rows)
  end

  test "a redelivery that completes after an interruption records the recovery" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [InterruptingHandler])
    {payload, status, observed_at} = plugin_result_fixture()
    interrupted_delivery!(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert [reported_row | marker_rows] = history_rows(status)
    reported_at = assert_reported_event_block(reported_row, observed_at)

    assert [
             %{"status" => "failed", "delivery" => %{"disposition" => "interrupted"}},
             %{"status" => "succeeded", "recovered_from_failure" => true} = recovery
           ] =
             Enum.map(marker_rows, &assert_handler_marker_in_block(&1, reported_at, observed_at))

    refute Map.has_key?(recovery, "delivery")
    assert [[true, "edge plugin completed", _recovered_at]] = current_state_rows(status)
  end

  test "successful replay records recovery after an initial handler failure" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :transient_failure}, :ok])
    {payload, status, observed_at} = plugin_result_fixture(assignment?: false)

    package = create_repair_package!(status.service_name, plugin_id: "rich-replay-plugin")
    _assignment = create_repair_assignment_for_package!(status, package)

    payload =
      Map.merge(payload, %{
        "labels" => %{"plugin_id" => "rich-replay-plugin"},
        "display" => [%{"widget" => "stat_card", "label" => "Hosts", "value" => 20}],
        "ui" => %{"display" => [%{"widget" => "table", "rows" => [%{"host" => "edge"}]}]},
        "schema" => %{"type" => "object"},
        "schema_version" => 1,
        "facts" => %{"inventory_count" => 20},
        "reported_result" => "spoofed-result",
        "downstream_ingest" => %{
          "status" => "succeeded",
          "generation" => 999,
          "handler_set" => %{"id" => "spoofed", "version" => 999}
        },
        "_serviceradar_plugin_result" => %{"kind" => "spoofed"}
      })

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":transient_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    reported_payload = Map.delete(payload, "_serviceradar_plugin_result")

    assert [
             [reported_at, true, "edge plugin completed", _] = reported_row,
             [_failed_at, false, _, failure_history_details] = failure_row,
             [recovered_at, true, "edge plugin completed", recovery_history_details] =
               recovery_row
           ] = history_rows(status)

    assert reported_at == assert_reported_event_block(reported_row, observed_at)

    assert %{"generation" => 1, "status" => "failed"} =
             assert_handler_marker_in_block(failure_row, reported_at, observed_at)

    assert %{"generation" => 1, "status" => "succeeded"} =
             assert_handler_marker_in_block(recovery_row, reported_at, observed_at)

    assert %{
             "labels" => %{"plugin_id" => "rich-replay-plugin"},
             "display" => [%{"widget" => "stat_card"}],
             "downstream_ingest" => %{"status" => "failed"},
             "reported_result" => ^reported_payload
           } = Jason.decode!(failure_history_details)

    recovery_details = current_state_details(status)
    assert recovery_details == recovery_history_details

    decoded_recovery = Jason.decode!(recovery_details)

    assert %{
             "labels" => %{"plugin_id" => "rich-replay-plugin"},
             "display" => [%{"widget" => "stat_card"}],
             "ui" => %{"display" => [%{"widget" => "table"}]},
             "schema" => %{"type" => "object"},
             "schema_version" => 1,
             "facts" => %{"inventory_count" => 20},
             "reported_result" => ^reported_payload,
             "downstream_ingest" => %{
               "status" => "succeeded",
               "generation" => 1,
               "handler_set" => %{"id" => handler_set_id, "version" => 1},
               "recovered_from_failure" => true
             }
           } = decoded_recovery

    assert is_binary(handler_set_id)
    refute Map.has_key?(decoded_recovery, "_serviceradar_plugin_result")

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)

    Repo.query!(
      "DELETE FROM platform.service_state WHERE agent_id = $1 AND service_name = $2",
      [status.agent_id, status.service_name]
    )

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(interval: "1 day", limit: 100)

    assert %{
             "downstream_ingest" => %{
               "status" => "succeeded",
               "generation" => 1,
               "handler_set" => %{"version" => 1}
             }
           } = status |> current_state_details() |> Jason.decode!()

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)
  end

  # One delivery whose process dies mid-handler, as a worker the admission lane
  # kills at its budget does: the reported row commits, no outcome is recorded.
  defp interrupted_delivery!(payload, status) do
    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :deliver -> PluginResultIngestor.ingest(payload, status)
        end
      end)

    ServiceRadar.DataCase.allow_sandbox(pid)
    send(pid, :deliver)
    assert_receive {:interrupting_handler_ingest, ^pid}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end
end
