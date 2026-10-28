defmodule ServiceRadar.Observability.PluginResultIngestorHandlerGenerationTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Observability.PluginResultProvenance
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract

  @module_hash String.duplicate("ab", 32)

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

    ReplayHandler.put_outcomes([:ok, :ok])
    SecondaryReplayHandler.put_outcomes([{:error, :new_handler_failure}, :ok])

    assert {:error,
            {:plugin_result_handlers_failed, [{SecondaryReplayHandler, ":new_handler_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    second_failure_at = marker_timestamp(reported_at, 2, "failed")
    assert [[false, _, ^second_failure_at]] = current_state_rows(status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    second_success_at = marker_timestamp(reported_at, 2, "succeeded")
    assert [[true, "edge plugin completed", ^second_success_at]] = current_state_rows(status)

    # The second set's success commits the result; a redelivery leaves it alone.
    assert :ok = PluginResultIngestor.ingest(payload, status)

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
    ReplayHandler.put_outcomes([{:error, :set_a_failure}, {:error, :set_a_returned}])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":set_a_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    reported_at = reported_event_block_base(status, observed_at)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [SecondaryReplayHandler])
    SecondaryReplayHandler.put_outcomes([:ok])
    assert :ok = PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":set_a_returned"}]}} =
             PluginResultIngestor.ingest(payload, status)

    first_failure_at = marker_timestamp(reported_at, 1, "failed")
    second_set_recovery_at = marker_timestamp(reported_at, 2, "succeeded")
    returned_failure_at = marker_timestamp(reported_at, 3, "failed")

    assert [
             [^reported_at, true, _, _],
             [^first_failure_at, false, _, _],
             [^second_set_recovery_at, true, _, _],
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

  describe "host-stamped result provenance" do
    test "reported row and state keep the host's provenance, not the plugin's claim" do
      Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
      {payload, status, _observed_at} = plugin_result_fixture()

      forged = %{
        "plugin_package_id" => "forged-package",
        "content_hash" => String.duplicate("0", 64)
      }

      payload =
        payload
        |> Map.put("_serviceradar_plugin_result", %{"provenance" => forged})
        |> Map.put("downstream_ingest", %{"provenance" => forged})

      status = Map.put(status, :plugin_provenance, host_provenance("assignment-reported-1"))

      assert :ok = PluginResultIngestor.ingest(payload, status)

      assert [[_reported_at, true, _message, details]] = reported_history_rows(status)

      assert PluginResultProvenance.from_details(details) ==
               stored_provenance("assignment-reported-1")

      assert PluginResultProvenance.from_details(current_state_details(status)) ==
               stored_provenance("assignment-reported-1")
    end

    test "downstream-ingest outcomes keep the provenance of the result they processed" do
      for {handler, outcome} <- [{SuccessfulHandler, "succeeded"}, {FailingHandler, "failed"}] do
        Application.put_env(:serviceradar_core, :plugin_result_handlers, [handler])
        {payload, status, _observed_at} = plugin_result_fixture()
        assignment_id = Ecto.UUID.generate()
        status = Map.put(status, :plugin_provenance, host_provenance(assignment_id))

        _ = PluginResultIngestor.ingest(payload, status)

        details = current_state_details(status)
        assert %{"downstream_ingest" => %{"status" => ^outcome}} = Jason.decode!(details)

        assert PluginResultProvenance.from_details(details) ==
                 stored_provenance(assignment_id)

        assert PluginStateContract.state_assignment_id(%{details: details}) == assignment_id

        assert {:ok, %{rows: [[sql_assignment_id]]}} =
                 ServiceRadar.Repo.query(
                   "SELECT " <> PluginStateContract.extracted_assignment_id_sql("$1::text"),
                   [details]
                 )

        assert sql_assignment_id == assignment_id
      end
    end

    test "results from agents without provenance ingest unchanged" do
      Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
      {payload, status, _observed_at} = plugin_result_fixture()

      assert :ok = PluginResultIngestor.ingest(payload, status)

      assert [[_reported_at, true, "edge plugin completed", details]] =
               reported_history_rows(status)

      marker = details |> Jason.decode!() |> Map.fetch!("_serviceradar_plugin_result")
      refute Map.has_key?(marker, "provenance")
      assert PluginResultProvenance.from_details(details) == nil
    end

    test "malformed provenance fields are dropped rather than trusted" do
      Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
      {payload, status, _observed_at} = plugin_result_fixture()

      status =
        Map.put(status, :plugin_provenance, %{
          assignment_id: " assignment-trimmed-1 ",
          plugin_package_id: "",
          plugin_version: "2.0.0\nforged",
          content_hash: String.upcase(@module_hash)
        })

      assert :ok = PluginResultIngestor.ingest(payload, status)

      assert [[_reported_at, true, _message, details]] = reported_history_rows(status)

      assert PluginResultProvenance.from_details(details) == %{
               "assignment_id" => "assignment-trimmed-1"
             }
    end
  end

  defp host_provenance(assignment_id) do
    %{
      assignment_id: assignment_id,
      plugin_id: "example-check",
      plugin_package_id: "example-check-package-2",
      plugin_version: "2.0.0",
      content_hash: @module_hash
    }
  end

  defp stored_provenance(assignment_id) do
    %{
      "assignment_id" => assignment_id,
      "plugin_id" => "example-check",
      "plugin_package_id" => "example-check-package-2",
      "plugin_version" => "2.0.0",
      "content_hash" => @module_hash
    }
  end
end
