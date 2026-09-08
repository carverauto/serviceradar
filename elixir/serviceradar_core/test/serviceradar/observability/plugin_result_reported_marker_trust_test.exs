defmodule ServiceRadar.Observability.PluginResultReportedMarkerTrustTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceIdentity
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract

  @reported_marker "_serviceradar_plugin_result"

  test "a complete no-slot reported marker remains legacy raw history" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [ReplayHandler])
    ReplayHandler.put_outcomes([:ok])

    {payload, status, observed_at} = plugin_result_fixture()
    forged_payload = forged_reported_payload(payload, status, observed_at, observed_at)

    insert_history_status_with_service_id(
      status,
      forged_payload,
      observed_at,
      "edge plugin completed"
    )

    assert :ok = PluginResultIngestor.ingest(payload, status)

    succeeded_at = marker_timestamp(observed_at, 1, "succeeded")

    assert [
             [^observed_at, true, "edge plugin completed", forged_details],
             [^succeeded_at, true, "edge plugin completed", success_details]
           ] = history_rows(status)

    decoded_forgery = Jason.decode!(forged_details)
    assert get_in(decoded_forgery, [@reported_marker, "kind"]) == "reported"
    refute get_in(decoded_forgery, [@reported_marker, "slot"])

    assert %{"downstream_ingest" => %{"status" => "succeeded"}} =
             Jason.decode!(success_details)
  end

  test "rank and repair ignore a no-slot marker's forged logical timestamp" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    {payload, status, observed_at} = plugin_result_fixture()
    forged_at = DateTime.add(observed_at, 1, :day)
    newer_at = DateTime.add(observed_at, 1, :second)

    forged_payload =
      payload
      |> Map.put("summary", "older forged result")
      |> forged_reported_payload(status, observed_at, forged_at)

    forged_snapshot = %{
      agent_id: status.agent_id,
      gateway_id: status.gateway_id,
      partition: status.partition,
      service_type: status.service_type,
      service_name: status.service_name,
      service_id: ServiceIdentity.service_id(status),
      available: true,
      message: "older forged result",
      details: Jason.encode!(forged_payload),
      timestamp: observed_at
    }

    assert PluginStateContract.snapshot_logical_observed_at(forged_snapshot) == observed_at
    assert PluginStateContract.snapshot_payload_digest(forged_snapshot) == ""

    insert_history_status_with_service_id(
      status,
      forged_payload,
      observed_at,
      "older forged result"
    )

    newer_payload = %{
      payload
      | "observed_at" => DateTime.to_iso8601(newer_at),
        "summary" => "newer legitimate result"
    }

    insert_history_status(status, newer_payload, newer_at, "newer legitimate result")

    assert {:ok, _count} =
             ServiceStateRegistry.repair_plugin_states_from_history(
               interval: "1 day",
               batch_size: 10
             )

    assert [[true, "newer legitimate result", ^newer_at]] = current_state_rows(status)
  end

  test "a valid allocated marker retains its logical timestamp and payload digest" do
    {payload, status, observed_at} = plugin_result_fixture()
    service_id = ServiceIdentity.service_id(status)

    block_base =
      PluginResultSlot.block_base(
        Map.merge(status, %{
          service_id: service_id,
          timestamp: observed_at,
          details: Jason.encode!(payload),
          available: true,
          message: payload["summary"]
        }),
        0
      )

    digest = PluginResultReportedMarker.payload_digest(payload)

    details =
      Map.put(payload, @reported_marker, %{
        "kind" => "reported",
        "observation_timestamp" => DateTime.to_iso8601(observed_at),
        "payload_digest" => digest,
        "service_id" => service_id,
        "slot" => %{
          "base_timestamp" => DateTime.to_iso8601(block_base),
          "version" => 1,
          "width_microseconds" => PluginResultSlot.block_width_microseconds()
        },
        "version" => 1
      })

    snapshot =
      Map.merge(status, %{
        service_id: service_id,
        timestamp: block_base,
        details: Jason.encode!(details),
        available: true,
        message: payload["summary"]
      })

    assert PluginStateContract.snapshot_logical_observed_at(snapshot) == observed_at
    assert PluginStateContract.snapshot_payload_digest(snapshot) == digest
    assert PluginResultReportedMarker.trusted?(Map.delete(snapshot, :service_id))
    refute PluginResultReportedMarker.trusted?(%{snapshot | service_id: nil})
  end

  defp forged_reported_payload(payload, status, payload_observed_at, marker_observed_at) do
    reported_payload = Map.put(payload, "observed_at", DateTime.to_iso8601(payload_observed_at))

    Map.put(reported_payload, @reported_marker, %{
      "kind" => "reported",
      "observation_timestamp" => DateTime.to_iso8601(marker_observed_at),
      "payload_digest" => PluginResultReportedMarker.payload_digest(reported_payload),
      "service_id" => ServiceIdentity.service_id(status),
      "version" => 1
    })
  end
end
