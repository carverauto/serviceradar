defmodule ServiceRadar.Observability.PluginResultIngestorReplayTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "records downstream handler failures as the current unavailable state" do
    {payload, status, observed_at} = plugin_result_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert_receive {:failing_handler_ingest, ^payload}

    assert [
             [^observed_at, true, "edge plugin completed", _reported_details],
             [failed_at, false, failure_message, details]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)

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

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [failed_at, false, _, _]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)
  end

  test "successful replay records recovery after an initial handler failure" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([{:error, :transient_failure}, :ok])
    {payload, status, observed_at} = plugin_result_fixture()

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

    failed_at = DateTime.add(observed_at, 1, :microsecond)
    recovered_at = DateTime.add(observed_at, 2, :microsecond)

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [^failed_at, false, _, failure_history_details],
             [^recovered_at, true, "edge plugin completed", recovery_history_details]
           ] = history_rows(status)

    assert %{
             "labels" => %{"plugin_id" => "rich-replay-plugin"},
             "display" => [%{"widget" => "stat_card"}],
             "downstream_ingest" => %{"status" => "failed"},
             "reported_result" => ^payload
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
             "reported_result" => ^payload,
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
  end

  test "a failing duplicate cannot downgrade an already successful observation" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])

    ReplayHandler.put_outcomes([
      :ok,
      {:error, :late_duplicate_failure},
      {:error, :repeated_duplicate_failure}
    ])

    {payload, status, observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert {:error,
            {:plugin_result_handlers_failed, [{ReplayHandler, ":late_duplicate_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    recovered_at = DateTime.add(observed_at, 2, :microsecond)
    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)

    assert {:error,
            {:plugin_result_handlers_failed, [{ReplayHandler, ":repeated_duplicate_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [failed_at, false, _, _],
             [^recovered_at, true, "edge plugin completed", _]
           ] = history_rows(status)

    assert failed_at == DateTime.add(observed_at, 1, :microsecond)
  end

  test "older observations cannot replace newer current state" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()
    newer_at = DateTime.add(observed_at, 10, :second)

    newer_payload = %{
      payload
      | "status" => "CRITICAL",
        "summary" => "newer critical result",
        "observed_at" => DateTime.to_iso8601(newer_at)
    }

    assert :ok = PluginResultIngestor.ingest(newer_payload, status)
    assert :ok = PluginResultIngestor.ingest(payload, status)

    newer_succeeded_at = DateTime.add(newer_at, 2, :microsecond)

    assert [[false, "newer critical result", ^newer_succeeded_at]] =
             current_state_rows(status)
  end

  test "delayed cross-gateway observation cannot deactivate newer logical state" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {older_payload, older_status, older_at} = plugin_result_fixture()
    newer_status = %{older_status | gateway_id: "#{older_status.gateway_id}-newer"}
    newer_at = DateTime.add(older_at, 10, :second)

    older_payload = %{
      older_payload
      | "status" => "CRITICAL",
        "summary" => "delayed critical result"
    }

    newer_payload = %{
      older_payload
      | "status" => "OK",
        "summary" => "newer healthy result",
        "observed_at" => DateTime.to_iso8601(newer_at)
    }

    assert :ok = PluginResultIngestor.ingest(newer_payload, newer_status)
    assert :ok = PluginResultIngestor.ingest(older_payload, older_status)

    assert [
             [older_gateway, false, "delayed critical result", older_succeeded_at, "inactive"],
             [newer_gateway, true, "newer healthy result", newer_succeeded_at, "active"]
           ] = logical_current_state_detail_rows(older_status)

    assert older_gateway == older_status.gateway_id
    assert newer_gateway == newer_status.gateway_id
    assert older_succeeded_at == DateTime.add(older_at, 2, :microsecond)
    assert newer_succeeded_at == DateTime.add(newer_at, 2, :microsecond)
  end

  test "unavailable wins equal-timestamp cross-gateway conflicts in either arrival order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    for arrival_order <- [:healthy_first, :critical_first] do
      {healthy_payload, healthy_status, observed_at} = plugin_result_fixture()
      critical_status = %{healthy_status | gateway_id: "#{healthy_status.gateway_id}-critical"}

      critical_payload = %{
        healthy_payload
        | "status" => "CRITICAL",
          "summary" => "same-time cross-gateway critical"
      }

      observations =
        case arrival_order do
          :healthy_first ->
            [{healthy_payload, healthy_status}, {critical_payload, critical_status}]

          :critical_first ->
            [{critical_payload, critical_status}, {healthy_payload, healthy_status}]
        end

      Enum.each(observations, fn {payload, status} ->
        assert :ok = PluginResultIngestor.ingest(payload, status)
      end)

      succeeded_at = DateTime.add(observed_at, 2, :microsecond)

      assert [
               [healthy_gateway, true, "edge plugin completed", ^succeeded_at, "inactive"],
               [
                 critical_gateway,
                 false,
                 "same-time cross-gateway critical",
                 ^succeeded_at,
                 "active"
               ]
             ] = logical_current_state_detail_rows(healthy_status)

      assert healthy_gateway == healthy_status.gateway_id
      assert critical_gateway == critical_status.gateway_id
    end
  end

  test "unavailable wins equal-timestamp current-state conflicts in either arrival order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {healthy_payload, first_status, observed_at} = plugin_result_fixture()

    unavailable_payload = %{
      healthy_payload
      | "status" => "CRITICAL",
        "summary" => "same-time critical result"
    }

    assert :ok = PluginResultIngestor.ingest(healthy_payload, first_status)
    assert :ok = PluginResultIngestor.ingest(unavailable_payload, first_status)
    assert :ok = PluginResultIngestor.ingest(healthy_payload, first_status)

    succeeded_at = DateTime.add(observed_at, 2, :microsecond)

    assert [[false, "same-time critical result", ^succeeded_at]] =
             current_state_rows(first_status)

    {_payload, second_status, _observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(unavailable_payload, second_status)
    assert :ok = PluginResultIngestor.ingest(healthy_payload, second_status)

    assert [[false, "same-time critical result", ^succeeded_at]] =
             current_state_rows(second_status)
  end

  test "a legacy raw state cannot prove downstream success on replay" do
    {payload, status, observed_at} = plugin_result_fixture()
    insert_history_status(status, payload, observed_at, "edge plugin completed")

    seed_service_state(status, observed_at,
      available: true,
      message: "edge plugin completed",
      state: "inactive"
    )

    other_gateway_status = %{status | gateway_id: "#{status.gateway_id}-other"}

    seed_service_state(other_gateway_status, observed_at,
      available: true,
      message: "edge plugin completed",
      state: "active"
    )

    assert {:error, {:plugin_result_handlers_failed, [{FailingHandler, ":forced_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    failed_at = DateTime.add(observed_at, 1, :microsecond)

    assert [
             [^observed_at, true, "edge plugin completed", _],
             [^failed_at, false, _, failure_details]
           ] = history_rows(status)

    assert %{"downstream_ingest" => %{"status" => "failed", "generation" => 1}} =
             Jason.decode!(failure_details)

    assert [[false, _, ^failed_at, "active"]] = current_state_rows_with_state(status)

    assert [[true, "edge plugin completed", ^observed_at, "inactive"]] =
             current_state_rows_with_state(other_gateway_status)
  end

  test "handler-set generations order new failures and same-set replay success" do
    {payload, status, observed_at} = plugin_result_fixture()

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok])

    assert :ok = PluginResultIngestor.ingest(payload, status)

    first_success_at = DateTime.add(observed_at, 2, :microsecond)
    assert [[true, "edge plugin completed", ^first_success_at]] = current_state_rows(status)

    assert [[^observed_at, true, "edge plugin completed", _]] = history_rows(status)

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

    second_failure_at = DateTime.add(observed_at, 3, :microsecond)
    assert [[false, _, ^second_failure_at]] = current_state_rows(status)

    assert :ok = PluginResultIngestor.ingest(payload, status)

    second_success_at = DateTime.add(observed_at, 4, :microsecond)
    assert [[true, "edge plugin completed", ^second_success_at]] = current_state_rows(status)

    assert {:error,
            {:plugin_result_handlers_failed, [{SecondaryReplayHandler, ":replayed_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", ^second_success_at]] = current_state_rows(status)

    second_success_details = current_state_details(status)

    assert [
             [^observed_at, true, _, _],
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

    failed_at = DateTime.add(observed_at, 1, :microsecond)
    recovered_at = DateTime.add(observed_at, 4, :microsecond)

    assert [
             [^observed_at, true, _, _],
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

    assert :ok = PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [SecondaryReplayHandler])
    SecondaryReplayHandler.put_outcomes([:ok])
    assert :ok = PluginResultIngestor.ingest(payload, status)

    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":set_a_returned"}]}} =
             PluginResultIngestor.ingest(payload, status)

    first_failure_at = DateTime.add(observed_at, 1, :microsecond)
    first_recovery_at = DateTime.add(observed_at, 2, :microsecond)
    returned_failure_at = DateTime.add(observed_at, 5, :microsecond)

    assert [
             [^observed_at, true, _, _],
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
