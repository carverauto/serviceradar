defmodule ServiceRadar.Observability.PluginResultIngestorIdentityNormalizationTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceIdentity

  test "plugin result history and current state share one normalized identity" do
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])
    {payload, status, observed_at} = plugin_result_fixture()

    padded_status = %{
      status
      | agent_id: "  #{status.agent_id}  ",
        gateway_id: "  #{status.gateway_id}  ",
        partition: "   ",
        service_type: "  #{status.service_type}  ",
        service_name: "  #{status.service_name}  "
    }

    normalized_status = %{status | partition: "default"}
    expected_service_id = ServiceIdentity.service_id(normalized_status)

    lower_bound =
      DateTime.add(
        observed_at,
        -PluginResultSlot.allocation_window_microseconds(),
        :microsecond
      )

    assert :ok = PluginResultIngestor.ingest(payload, padded_status)

    assert [
             [
               normalized_agent_id,
               normalized_gateway_id,
               "default",
               normalized_service_type,
               normalized_service_name,
               ^expected_service_id,
               reported_at,
               details
             ]
           ] =
             Repo.query!(
               """
               SELECT
                 agent_id,
                 gateway_id,
                 partition,
                 service_type,
                 service_name,
                 service_id::text,
                 timestamp,
                 details
               FROM platform.service_status
               WHERE timestamp >= $1
                 AND timestamp <= $2
                 AND service_id::text = $3
               ORDER BY timestamp
               """,
               [lower_bound, observed_at, expected_service_id]
             ).rows

    assert normalized_agent_id == status.agent_id
    assert normalized_gateway_id == status.gateway_id
    assert normalized_service_type == status.service_type
    assert normalized_service_name == status.service_name

    assert get_in(Jason.decode!(details), ["_serviceradar_plugin_result", "service_id"]) ==
             expected_service_id

    assert reported_at ==
             assert_reported_event_block(
               [reported_at, true, "edge plugin completed", details],
               observed_at
             )

    assert [[true, _message, _last_observed_at]] = current_state_rows(normalized_status)
    assert [] = current_state_rows(padded_status)
  end
end
