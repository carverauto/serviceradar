defmodule ServiceRadar.Observability.TelemetryIndexReadTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Observability.TelemetryIndexRead
  alias ServiceRadar.Observability.TelemetryUnavailable

  @moduletag :db_free

  @uuid "11111111-1111-1111-1111-111111111111"

  defp with_starrocks(enabled?) do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :enabled, enabled?))

    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
  end

  test "routes to CNPG when the warehouse is disabled" do
    with_starrocks(false)

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.Log, table: "logs") == :cnpg
    assert TelemetryIndexRead.mode(ServiceRadar.Observability.OtelTrace, table: nil) == :cnpg
  end

  test "routes to the warehouse table when enabled and one exists" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.Log, table: "logs") ==
             {:starrocks, "logs"}

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.OtelMetric,
             table: "otel_metrics"
           ) == {:starrocks, "otel_metrics"}

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.TimeseriesMetric,
             table: "timeseries_metrics"
           ) == {:starrocks, "timeseries_metrics"}
  end

  test "reports unavailable when enabled and no warehouse table exists" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.OtelTrace, table: nil) ==
             {:unavailable, ServiceRadar.Observability.OtelTrace}
  end

  test "delegates to the CNPG data layer when the warehouse is disabled" do
    with_starrocks(false)

    query =
      ServiceRadar.Observability.Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.set_context(%{cnpg_read: fn _data_layer_query -> {:ok, :cnpg_records} end})

    assert TelemetryIndexRead.read(query, :data_layer_query, [table: "logs"], %{}) ==
             {:ok, :cnpg_records}
  end

  test "serves the warehouse table when enabled, rendering filter, sort and page bounds" do
    with_starrocks(true)

    parent = self()

    query =
      ServiceRadar.Observability.Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(trace_id == "abc123")
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(101)
      |> Ash.Query.offset(20)
      |> Ash.Query.set_context(%{
        starrocks_query: fn sql ->
          send(parent, {:sql, sql})

          {:ok,
           %{
             columns: ["timestamp", "id", "trace_id"],
             rows: [["2026-01-01 00:00:00.000000", @uuid, "abc123"]]
           }}
        end
      })

    assert {:ok, [record]} =
             TelemetryIndexRead.read(query, :data_layer_query, [table: "logs"], %{})

    assert record.id == @uuid
    assert record.trace_id == "abc123"
    assert %DateTime{} = record.timestamp

    assert_received {:sql, sql}

    assert sql =~ "FROM serviceradar.logs"
    assert sql =~ "`trace_id` = 'abc123'"
    assert sql =~ "ORDER BY `timestamp` DESC"
    assert sql =~ "LIMIT 101"
    assert sql =~ "OFFSET 20"
  end

  test "returns the unavailable error when enabled and no warehouse table exists" do
    with_starrocks(true)

    query = ServiceRadar.Observability.OtelTrace |> Ash.Query.for_read(:api_index)

    assert {:error, %TelemetryUnavailable{resource: ServiceRadar.Observability.OtelTrace}} =
             TelemetryIndexRead.read(query, :data_layer_query, [table: nil], %{})
  end
end
