defmodule ServiceRadar.Observability.ServiceStateRegistryQueriesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Observability.ServiceStateRegistry.Queries

  test "reported payload count spans allocated blocks and legacy marker offsets" do
    sql = Queries.reported_payload_count_for_observation()

    assert sql =~ "service_status.timestamp >= ($6::text)::timestamptz -"

    assert sql =~
             "INTERVAL '#{PluginResultSlot.allocation_window_microseconds()} microseconds'"

    assert sql =~ "service_status.timestamp <= ($6::text)::timestamptz +"
    assert sql =~ "INTERVAL '256 microseconds'"

    assert sql =~ "observation_timestamp}' = $6::text"
    assert sql =~ "slot,width_microseconds}' = '257'"
    assert sql =~ "slot,base_timestamp"
    assert sql =~ "service_id}' = (CASE WHEN service_status.service_id ="
    assert sql =~ "THEN service_status.service_id END)::text"
    assert sql =~ "payload_digest}' ~ '^[0-9a-f]{64}$'"
  end
end
