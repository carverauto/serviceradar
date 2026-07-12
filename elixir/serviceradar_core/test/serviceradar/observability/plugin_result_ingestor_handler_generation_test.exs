defmodule ServiceRadar.Observability.PluginResultIngestorHandlerGenerationTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "handler-set generations order new failures and same-set replay success" do
    {payload, status, observed_at} = plugin_result_fixture()

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok])

    assert :ok = PluginResultIngestor.ingest(payload, status)
    reported_at = reported_event_block_base(status, observed_at)

    first_success_at = marker_timestamp(reported_at, 1, "succeeded")
    assert [[true, "edge plugin completed", ^first_success_at]] = current_state_rows(status)

    assert [[^reported_at, true, "edge plugin completed", _]] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 1,
               "handler_set" => %{"id" => first_set_id},
               "status" => "succeeded"
             }
           } = status |> current_state_details() |> Jason.decode!()

    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [ReplayHandler, SecondaryReplayHandler]
    )

    ReplayHandler.put_outcomes([:ok, :ok, :ok])

    SecondaryReplayHandler.put_outcomes([
      {:error, :new_handler_failure},
      :ok,
      {:error, :replayed_failure}
    ])

    assert {:error,
            {:plugin_result_handlers_failed, [{SecondaryReplayHandler, ":new_handler_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    second_failure_at = marker_timestamp(reported_at, 2, "failed")
    assert [[false, _, ^second_failure_at]] = current_state_rows(status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    second_success_at = marker_timestamp(reported_at, 2, "succeeded")
    assert [[true, "edge plugin completed", ^second_success_at]] = current_state_rows(status)

    assert {:error,
            {:plugin_result_handlers_failed, [{SecondaryReplayHandler, ":replayed_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", ^second_success_at]] = current_state_rows(status)

    second_success_details = current_state_details(status)

    assert [
             [^reported_at, true, _, _],
             [^second_failure_at, false, _, second_failure_details],
             [^second_success_at, true, _, recovery_history_details]
           ] = history_rows(status)

    assert recovery_history_details == second_success_details

    assert %{
             "downstream_ingest" => %{
               "generation" => 2,
               "handler_set" => %{"id" => second_set_id},
               "status" => "failed"
             }
           } = Jason.decode!(second_failure_details)

    assert %{
             "downstream_ingest" => %{
               "generation" => 2,
               "handler_set" => %{"id" => ^second_set_id},
               "recovered_from_failure" => true,
               "status" => "succeeded"
             }
           } = Jason.decode!(second_success_details)

    refute first_set_id == second_set_id
  end

  test "a new handler set records recovery from the prior set's failure" do
    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok])

    assert :ok = PluginResultIngestor.ingest(payload, status)
    reported_at = reported_event_block_base(status, observed_at)

    failed_at = marker_timestamp(reported_at, 1, "failed")
    recovered_at = marker_timestamp(reported_at, 2, "succeeded")

    assert [
             [^reported_at, true, _, _],
             [^failed_at, false, _, _],
             [^recovered_at, true, _, recovery_details]
           ] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 2,
               "recovered_from_failure" => true,
               "status" => "succeeded"
             }
           } = Jason.decode!(recovery_details)

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)
    assert current_state_details(status) == recovery_details
  end

  test "returning to an older handler set allocates above the global generation" do
    {payload, status, observed_at} = plugin_result_fixture()

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :set_a_failure}, :ok, {:error, :set_a_returned}])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":set_a_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    reported_at = reported_event_block_base(status, observed_at)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [SecondaryReplayHandler])
    SecondaryReplayHandler.put_outcomes([:ok])
    assert :ok = PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":set_a_returned"}]}} =
             PluginResultIngestor.ingest(payload, status)

    first_failure_at = marker_timestamp(reported_at, 1, "failed")
    first_recovery_at = marker_timestamp(reported_at, 1, "succeeded")
    returned_failure_at = marker_timestamp(reported_at, 3, "failed")

    assert [
             [^reported_at, true, _, _],
             [^first_failure_at, false, _, _],
             [^first_recovery_at, true, _, _],
             [^returned_failure_at, false, _, returned_failure_details]
           ] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 3,
               "status" => "failed"
             }
           } = Jason.decode!(returned_failure_details)

    assert [[false, _, ^returned_failure_at]] = current_state_rows(status)
  end
end
