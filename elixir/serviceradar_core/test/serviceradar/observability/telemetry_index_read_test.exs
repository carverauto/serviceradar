defmodule ServiceRadar.Observability.TelemetryIndexReadTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Observability.TelemetryIndexRead

  @moduletag :db_free

  @uuid "11111111-1111-1111-1111-111111111111"

  defp with_starrocks(enabled?, opts \\ []) do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    config =
      prev
      |> Keyword.put(:enabled, enabled?)
      |> Keyword.put(:cutover_datasets, Keyword.get(opts, :cutover_datasets, []))

    Application.put_env(:serviceradar_core, StarRocks, config)

    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
  end

  test "routes to CNPG when the warehouse is disabled" do
    with_starrocks(false)

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.Log, table: "logs") == :cnpg
    assert TelemetryIndexRead.mode(ServiceRadar.Observability.OtelTrace, table: nil) == :cnpg
  end

  test "routes otel metrics to the warehouse when enabled" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.OtelMetric,
             table: "otel_metrics"
           ) == {:starrocks, "otel_metrics"}

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.OtelMetricPoint,
             table: "otel_metric_points"
           ) == {:starrocks, "otel_metric_points"}
  end

  test "routes logs and metrics to the warehouse once cut over" do
    with_starrocks(true, cutover_datasets: [:logs, :metrics])

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.Log, table: "logs") ==
             {:starrocks, "logs"}

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.TimeseriesMetric,
             table: "timeseries_metrics"
           ) == {:starrocks, "timeseries_metrics"}

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.TimeseriesMetricHourly,
             table: "timeseries_metrics_hourly"
           ) == {:starrocks, "timeseries_metrics_hourly"}
  end

  test "keeps logs and metrics on CNPG when enabled but not cut over" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.Log, table: "logs") == :cnpg

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.TimeseriesMetric,
             table: "timeseries_metrics"
           ) == :cnpg
  end

  test "keeps routes without a warehouse table on CNPG when enabled" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.OtelTrace, table: nil) == :cnpg

    assert TelemetryIndexRead.mode(ServiceRadar.Observability.OtelTraceSummary, table: nil) ==
             :cnpg
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

  test "computes the CNPG total when page count is requested" do
    with_starrocks(false)

    query =
      ServiceRadar.Observability.Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.page(count: true)
      |> Ash.Query.set_context(%{
        cnpg_read: fn _data_layer_query -> {:ok, :cnpg_records} end,
        cnpg_count: fn -> {:ok, 7} end
      })

    assert TelemetryIndexRead.read(query, :data_layer_query, [table: "logs"], %{}) ==
             {:ok, :cnpg_records, %{full_count: 7}}
  end

  test "serves the warehouse table when enabled, rendering filter, sort and page bounds" do
    with_starrocks(true, cutover_datasets: [:logs])

    parent = self()

    query =
      ServiceRadar.Observability.Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(trace_id == "abc123")
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(101)
      |> Ash.Query.offset(20)
      |> Ash.Query.page(count: true)
      |> Ash.Query.set_context(%{
        starrocks_query: fn sql ->
          send(parent, {:sql, sql})

          if String.contains?(sql, "COUNT(*)") do
            {:ok, %{columns: ["COUNT(*)"], rows: [[42]]}}
          else
            {:ok,
             %{
               columns: ["timestamp", "id", "trace_id"],
               rows: [["2026-01-01 00:00:00.000000", @uuid, "abc123"]]
             }}
          end
        end
      })

    assert {:ok, [record], %{full_count: 42}} =
             TelemetryIndexRead.read(query, :data_layer_query, [table: "logs"], %{})

    assert record.id == @uuid
    assert record.trace_id == "abc123"
    assert %DateTime{} = record.timestamp

    assert_received {:sql, data_sql}

    assert data_sql =~ "FROM serviceradar.logs"
    assert data_sql =~ "WHERE `trace_id` = 'abc123'"
    assert data_sql =~ "ORDER BY `timestamp` DESC"
    assert data_sql =~ "LIMIT 101"
    assert data_sql =~ "OFFSET 20"

    assert_received {:sql, count_sql}

    assert count_sql =~ "SELECT COUNT(*) FROM serviceradar.logs"
    assert count_sql =~ "WHERE `trace_id` = 'abc123'"
    refute count_sql =~ "LIMIT"
  end

  test "rejects filters and sorts on columns the warehouse table does not store" do
    with_starrocks(true, cutover_datasets: [:logs])

    filtered =
      ServiceRadar.Observability.Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(scope_name == "otel")

    assert {:error, {:unsupported_warehouse_filter_field, :scope_name}} =
             TelemetryIndexRead.read(filtered, :data_layer_query, [table: "logs"], %{})

    sorted =
      ServiceRadar.Observability.Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.sort(scope_version: :asc)

    assert {:error, {:unsupported_warehouse_sort_field, :scope_version}} =
             TelemetryIndexRead.read(sorted, :data_layer_query, [table: "logs"], %{})
  end

  test "delegates to CNPG when enabled but the resource has no warehouse table" do
    with_starrocks(true)

    query =
      ServiceRadar.Observability.OtelTrace
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.set_context(%{cnpg_read: fn _data_layer_query -> {:ok, :cnpg_records} end})

    assert TelemetryIndexRead.read(query, :data_layer_query, [table: nil], %{}) ==
             {:ok, :cnpg_records}
  end
end
