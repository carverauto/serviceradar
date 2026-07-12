defmodule ServiceRadar.Observability.PluginResultIngestorOrderingTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  test "a failing duplicate cannot downgrade an already successful observation" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])

    ReplayHandler.put_outcomes([
      :ok,
      {:error, :late_duplicate_failure},
      {:error, :repeated_duplicate_failure}
    ])

    {payload, status, observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(payload, status)
    reported_at = reported_event_block_base(status, observed_at)

    assert {:error,
            {:plugin_result_handlers_failed, [{ReplayHandler, ":late_duplicate_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    recovered_at = marker_timestamp(reported_at, 1, "succeeded")
    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)

    assert {:error,
            {:plugin_result_handlers_failed, [{ReplayHandler, ":repeated_duplicate_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert [[true, "edge plugin completed", ^recovered_at]] = current_state_rows(status)

    assert [
             [^reported_at, true, "edge plugin completed", _],
             [failed_at, false, _, _],
             [^recovered_at, true, "edge plugin completed", _]
           ] = history_rows(status)

    assert failed_at == marker_timestamp(reported_at, 1, "failed")
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

    newer_succeeded_at =
      status
      |> reported_event_block_base(newer_at, "newer critical result")
      |> marker_timestamp(1, "succeeded")

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

    assert older_succeeded_at ==
             older_status
             |> reported_event_block_base(older_at, "delayed critical result")
             |> marker_timestamp(1, "succeeded")

    assert newer_succeeded_at ==
             newer_status
             |> reported_event_block_base(newer_at, "newer healthy result")
             |> marker_timestamp(1, "succeeded")
  end

  test "unavailable wins equal-timestamp cross-gateway conflicts in either arrival order" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    for arrival_order <- [:healthy_first, :critical_first] do
      {healthy_payload, healthy_status, observed_at} = plugin_result_fixture()
      suffix = System.unique_integer([:positive])
      healthy_status = %{healthy_status | gateway_id: "gateway-z-healthy-#{suffix}"}
      critical_status = %{healthy_status | gateway_id: "gateway-a-critical-#{suffix}"}

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

      succeeded_at =
        critical_status
        |> reported_event_block_base(observed_at, "same-time cross-gateway critical")
        |> marker_timestamp(1, "succeeded")

      assert [
               [
                 critical_gateway,
                 false,
                 "same-time cross-gateway critical",
                 ^succeeded_at,
                 "active"
               ],
               [healthy_gateway, true, "edge plugin completed", ^succeeded_at, "inactive"]
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

    assert [[false, "same-time critical result", first_succeeded_at]] =
             current_state_rows(first_status)

    assert first_succeeded_at ==
             first_status
             |> reported_event_block_base(observed_at, "same-time critical result")
             |> marker_timestamp(1, "succeeded")

    {_payload, second_status, _observed_at} = plugin_result_fixture()

    assert :ok = PluginResultIngestor.ingest(unavailable_payload, second_status)
    assert :ok = PluginResultIngestor.ingest(healthy_payload, second_status)

    assert [[false, "same-time critical result", second_succeeded_at]] =
             current_state_rows(second_status)

    assert second_succeeded_at ==
             second_status
             |> reported_event_block_base(observed_at, "same-time critical result")
             |> marker_timestamp(1, "succeeded")
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

  test "successful handling upgrades a legacy raw row with durable success proof" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok, {:error, :late_failure}])

    {payload, status, observed_at} = plugin_result_fixture()
    insert_history_status(status, payload, observed_at, "edge plugin completed")
    :ok = ServiceStatusPubSub.subscribe()

    seed_service_state(status, observed_at,
      available: true,
      message: "edge plugin completed",
      state: "active"
    )

    succeeded_at = marker_timestamp(observed_at, 1, "succeeded")
    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert_receive {:service_status_updated, %ServiceStatus{timestamp: ^succeeded_at}}

    assert {:error, {:plugin_result_handlers_failed, [{ReplayHandler, ":late_failure"}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert_receive {:service_status_updated, %ServiceStatus{timestamp: ^succeeded_at}}

    failed_at = marker_timestamp(observed_at, 1, "failed")

    assert [
             [^observed_at, true, "edge plugin completed", _legacy_details],
             [^failed_at, false, _failure_message, failure_details],
             [^succeeded_at, true, "edge plugin completed", success_details]
           ] = history_rows(status)

    assert %{"downstream_ingest" => %{"generation" => 1, "status" => "failed"}} =
             Jason.decode!(failure_details)

    assert %{"downstream_ingest" => %{"generation" => 1, "status" => "succeeded"}} =
             Jason.decode!(success_details)

    assert [[true, "edge plugin completed", ^succeeded_at, "active"]] =
             current_state_rows_with_state(status)
  end

  test "a partial reported marker cannot suppress legacy success proof" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok])

    {payload, status, observed_at} = plugin_result_fixture()

    spoofed_payload =
      Map.put(payload, "_serviceradar_plugin_result", %{"kind" => "reported"})

    insert_history_status(status, spoofed_payload, observed_at, "edge plugin completed")

    seed_service_state(status, observed_at,
      available: true,
      message: "edge plugin completed",
      state: "active"
    )

    assert :ok = PluginResultIngestor.ingest(payload, status)

    succeeded_at = marker_timestamp(observed_at, 1, "succeeded")

    assert [
             [^observed_at, true, "edge plugin completed", _legacy_details],
             [^succeeded_at, true, "edge plugin completed", success_details]
           ] = history_rows(status)

    assert %{
             "downstream_ingest" => %{
               "generation" => 1,
               "status" => "succeeded"
             }
           } = Jason.decode!(success_details)
  end
end
