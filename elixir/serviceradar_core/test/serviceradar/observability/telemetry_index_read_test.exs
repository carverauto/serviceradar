defmodule ServiceRadar.Observability.TelemetryIndexReadTest do
  use ExUnit.Case, async: false

  alias Ash.Error.Query.InvalidQuery
  alias AshJsonApi.Resource.Info
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Observability.JsonApiCompositeId
  alias ServiceRadar.Observability.Log
  alias ServiceRadar.Observability.OtelMetric
  alias ServiceRadar.Observability.OtelTrace
  alias ServiceRadar.Observability.OtelTraceSummary
  alias ServiceRadar.Observability.TelemetryIndexRead
  alias ServiceRadar.Observability.TimeseriesMetric
  alias ServiceRadar.Observability.TimeseriesMetricDiskHourly
  alias ServiceRadar.Observability.TimeseriesMetricHourly

  require Ash.Query

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

    assert TelemetryIndexRead.mode(Log, table: "logs") == :cnpg

    assert TelemetryIndexRead.mode(
             OtelTrace,
             index_read_opts(OtelTrace)
           ) == :cnpg

    assert TelemetryIndexRead.mode(
             OtelTraceSummary,
             index_read_opts(OtelTraceSummary)
           ) == :cnpg
  end

  test "routes otel metrics to the warehouse when enabled" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(
             OtelMetric,
             table: "otel_metrics"
           ) == {:starrocks, "otel_metrics"}

    assert TelemetryIndexRead.mode(
             ServiceRadar.Observability.OtelMetricPoint,
             table: "otel_metric_points"
           ) == {:starrocks, "otel_metric_points"}
  end

  test "routes logs and metrics to the warehouse once cut over" do
    with_starrocks(true, cutover_datasets: [:logs, :metrics])

    assert TelemetryIndexRead.mode(Log, table: "logs") ==
             {:starrocks, "logs"}

    assert TelemetryIndexRead.mode(
             TimeseriesMetric,
             table: "timeseries_metrics"
           ) == {:starrocks, "timeseries_metrics"}

    assert TelemetryIndexRead.mode(
             TimeseriesMetricHourly,
             table: "timeseries_metrics_hourly"
           ) == {:starrocks, "timeseries_metrics_hourly"}
  end

  test "routes metrics by warehouse enablement independently of log cutover" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(Log, table: "logs") == :cnpg

    assert TelemetryIndexRead.mode(
             TimeseriesMetric,
             table: "timeseries_metrics"
           ) == {:starrocks, "timeseries_metrics"}
  end

  test "routes traces and summaries to the warehouse when enabled, before any cutover" do
    with_starrocks(true)

    assert TelemetryIndexRead.mode(
             OtelTrace,
             index_read_opts(OtelTrace)
           ) == {:starrocks, "otel_traces"}

    assert TelemetryIndexRead.mode(
             OtelTraceSummary,
             index_read_opts(OtelTraceSummary)
           ) == {:starrocks, "otel_trace_summaries"}
  end

  test "keeps interface and disk hourly on CNPG when the warehouse is enabled" do
    with_starrocks(true)

    for resource <- [
          ServiceRadar.Observability.TimeseriesMetricInterfaceHourly,
          TimeseriesMetricDiskHourly
        ] do
      assert TelemetryIndexRead.mode(resource, index_read_opts(resource)) == :cnpg
    end
  end

  test "delegates to the CNPG data layer when the warehouse is disabled" do
    with_starrocks(false)

    query =
      Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.set_context(%{cnpg_read: fn _data_layer_query -> {:ok, :cnpg_records} end})

    assert TelemetryIndexRead.read(query, :data_layer_query, [table: "logs"], %{}) ==
             {:ok, :cnpg_records}
  end

  test "computes the CNPG total when page count is requested" do
    with_starrocks(false)

    query =
      Log
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
      Log
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
      Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(scope_name == "otel")

    assert {:error, error} =
             TelemetryIndexRead.read(filtered, :data_layer_query, [table: "logs"], %{})

    assert %InvalidQuery{field: :scope_name, class: :invalid} = error
    assert Exception.message(error) =~ "scope_name"
    assert [json_error] = AshJsonApi.Error.to_json_api_errors(nil, Log, error, :read)
    assert json_error.status_code == 400
    assert json_error.detail =~ "scope_name"

    sorted =
      Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.sort(scope_version: :asc)

    assert {:error, sort_error} =
             TelemetryIndexRead.read(sorted, :data_layer_query, [table: "logs"], %{})

    assert %InvalidQuery{field: :scope_version, class: :invalid} = sort_error
    assert Exception.message(sort_error) =~ "scope_version"
    assert [sort_json] = AshJsonApi.Error.to_json_api_errors(nil, Log, sort_error, :read)
    assert sort_json.status_code == 400
    assert sort_json.detail =~ "scope_version"
  end

  test "renders an in filter whose values Ash stored as a set" do
    with_starrocks(true, cutover_datasets: [:logs])

    parent = self()

    query =
      Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(trace_id in ["abc", "def"])
      |> Ash.Query.set_context(%{
        starrocks_query: fn sql ->
          send(parent, {:sql, sql})
          {:ok, %{columns: ["trace_id"], rows: [["abc"]]}}
        end
      })

    assert {:ok, [record]} =
             TelemetryIndexRead.read(query, :data_layer_query, [table: "logs"], %{})

    assert record.trace_id == "abc"
    assert_received {:sql, sql}
    assert sql =~ "WHERE "
    assert sql =~ "`trace_id` IN ("
    assert sql =~ "'abc'"
    assert sql =~ "'def'"
  end

  test "rejects an empty in filter as an invalid query" do
    with_starrocks(true, cutover_datasets: [:logs])

    query =
      Log
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(trace_id in [])

    assert {:error, error} =
             TelemetryIndexRead.read(query, :data_layer_query, [table: "logs"], %{})

    assert %InvalidQuery{class: :invalid} = error
    assert Exception.message(error) =~ "non-empty"
    assert [json_error] = AshJsonApi.Error.to_json_api_errors(nil, Log, error, :read)
    assert json_error.status_code == 400
    assert json_error.detail =~ "non-empty"
  end

  test "delegates to CNPG when enabled but the resource has no warehouse table" do
    with_starrocks(true)

    resource = TimeseriesMetricDiskHourly

    query =
      resource
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.set_context(%{cnpg_read: fn _data_layer_query -> {:ok, :cnpg_records} end})

    assert TelemetryIndexRead.read(query, :data_layer_query, index_read_opts(resource), %{}) ==
             {:ok, :cnpg_records}
  end

  test "serves traces and summaries from the warehouse when enabled" do
    with_starrocks(true)

    parent = self()

    trace_query =
      OtelTrace
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(trace_id == "abc123")
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(50)
      |> Ash.Query.set_context(%{starrocks_query: &reply_rows(&1, parent, :trace)})

    assert {:ok, [trace]} =
             TelemetryIndexRead.read(
               trace_query,
               :data_layer_query,
               index_read_opts(OtelTrace),
               %{}
             )

    assert trace.trace_id == "abc123"
    assert trace.span_id == "span1"
    assert trace.service_name == "api"
    assert %DateTime{} = trace.timestamp

    assert_received {:sql, trace_sql}
    assert trace_sql =~ "FROM serviceradar.otel_traces"
    assert trace_sql =~ "WHERE `trace_id` = 'abc123'"
    assert trace_sql =~ "ORDER BY `timestamp` DESC"
    assert trace_sql =~ "`span_id`"
    refute trace_sql =~ "COUNT(*)"

    summary_query =
      OtelTraceSummary
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.filter(root_service_name == "api")
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.set_context(%{starrocks_query: &reply_rows(&1, parent, :summary)})

    assert {:ok, [summary]} =
             TelemetryIndexRead.read(
               summary_query,
               :data_layer_query,
               index_read_opts(OtelTraceSummary),
               %{}
             )

    assert summary.trace_id == "abc123"
    assert summary.root_service_name == "api"
    assert summary.duration_ms == 12.5
    assert summary.span_count == 3
    assert summary.service_set == ["api", "db"]
    assert %DateTime{} = summary.timestamp

    assert_received {:sql, summary_sql}
    assert summary_sql =~ "FROM serviceradar.otel_trace_summaries"
    assert summary_sql =~ "WHERE `root_service_name` = 'api'"
    assert summary_sql =~ "ORDER BY `timestamp` DESC"
    assert summary_sql =~ "`service_set`"
    assert summary_sql =~ "`error_count`"
    refute summary_sql =~ "`refreshed_at`"
    refute summary_sql =~ "`error_rate`"
  end

  @sampled_at ~U[2026-01-01 00:00:00.000000Z]
  @sampled_at_sql "2026-01-01 00:00:00.000000"

  test "serves a null span id on an otel metrics page from either backend" do
    cnpg_record =
      struct(OtelMetric, %{
        timestamp: @sampled_at,
        span_name: "GET /",
        service_name: "api",
        span_id: nil
      })

    for backend <- [:cnpg, :warehouse] do
      [record] =
        read_index(
          OtelMetric,
          "otel_metrics",
          backend,
          [cnpg_record],
          ["timestamp", "span_name", "service_name", "span_id"],
          [@sampled_at_sql, "GET /", "api", nil]
        )

      assert record.span_id == nil
      assert_null_page(OtelMetric, record, "otel_metric", :span_id)
    end

    present = %{cnpg_record | span_id: "abc123abc123abcd"}

    assert AshJsonApi.Resource.encode_primary_key(prepared_record(OtelMetric, present)) ==
             joined_primary_key(OtelMetric, present)

    assert JsonApiCompositeId.decode_part(JsonApiCompositeId.encode_part(nil)) == nil
    assert JsonApiCompositeId.decode_part(JsonApiCompositeId.encode_part("")) == ""

    assert JsonApiCompositeId.decode_part(JsonApiCompositeId.encode_part(<<0x1F>>)) ==
             <<0x1F>>

    assert JsonApiCompositeId.decode_part(JsonApiCompositeId.encode_part(<<0x1F, 0x1F>>)) ==
             <<0x1F, 0x1F>>
  end

  test "serves a null device id on an hourly metrics page from either backend" do
    cnpg_record =
      struct(TimeseriesMetricHourly, %{
        bucket: @sampled_at,
        device_id: nil,
        metric_type: "cpu",
        metric_name: "usage"
      })

    for backend <- [:cnpg, :warehouse] do
      [record] =
        read_index(
          TimeseriesMetricHourly,
          "timeseries_metrics_hourly",
          backend,
          [cnpg_record],
          ["bucket", "device_id", "metric_type", "metric_name"],
          [@sampled_at_sql, nil, "cpu", "usage"]
        )

      assert record.device_id == nil
      assert_null_page(TimeseriesMetricHourly, record, "timeseries_metric_hourly", :device_id)
    end

    present = %{cnpg_record | device_id: "device-1"}

    assert AshJsonApi.Resource.encode_primary_key(
             prepared_record(TimeseriesMetricHourly, present)
           ) ==
             joined_primary_key(TimeseriesMetricHourly, present)
  end

  defp read_index(resource, table, :cnpg, records, _columns, _row) do
    with_starrocks(false)

    query =
      resource
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.set_context(%{cnpg_read: fn _data_layer_query -> {:ok, records} end})

    assert {:ok, read} = TelemetryIndexRead.read(query, :data_layer_query, [table: table], %{})
    read
  end

  defp read_index(resource, table, :warehouse, _records, columns, row) do
    cutover = if table == "timeseries_metrics_hourly", do: [:metrics], else: []
    with_starrocks(true, cutover_datasets: cutover)

    query =
      resource
      |> Ash.Query.for_read(:api_index)
      |> Ash.Query.set_context(%{
        starrocks_query: fn sql ->
          if String.contains?(sql, "COUNT(*)") do
            flunk("index page did not request a count: #{sql}")
          else
            {:ok, %{columns: columns, rows: [row]}}
          end
        end
      })

    assert {:ok, read} = TelemetryIndexRead.read(query, :data_layer_query, [table: table], %{})
    read
  end

  defp assert_null_page(resource, record, type, field) do
    action = Ash.Resource.Info.action(resource, :api_index)

    assert Enum.any?(action.preparations, fn
             %{preparation: {JsonApiCompositeId, _opts}} -> true
             _other -> false
           end)

    prepared = prepared_record(resource, record)

    body =
      %AshJsonApi.Request{
        url: "http://example.test/api/v2",
        includes_keyword: [],
        fields: %{},
        route: %{},
        domain: ServiceRadar.Observability,
        all_domains: [ServiceRadar.Observability],
        resource: resource
      }
      |> AshJsonApi.Serializer.serialize_many(offset_page([prepared]), [], %{})
      |> Jason.decode!()

    assert [row] = body["data"]
    assert row["type"] == type
    assert row["id"] == encoded_primary_key(resource, record)
    assert row["id"] == AshJsonApi.Resource.encode_primary_key(prepared)
    assert is_binary(row["id"])
    assert Map.get(row["attributes"], Atom.to_string(field)) == nil
    refute row["id"] == encoded_primary_key(resource, Map.put(record, field, ""))
    refute row["id"] == encoded_primary_key(resource, Map.put(record, field, <<0x1F>>))
  end

  defp prepared_record(resource, record) do
    query = JsonApiCompositeId.prepare(Ash.Query.new(resource), [], %{})
    [hook | _] = query.after_action
    assert {:ok, [prepared]} = hook.(query, [record])
    prepared
  end

  defp offset_page(records) do
    %Ash.Page.Offset{
      results: records,
      limit: 100,
      offset: 0,
      count: length(records),
      more?: false
    }
  end

  defp joined_primary_key(resource, record) do
    delimiter = Info.primary_key_delimiter(resource)
    keys = Info.primary_key_fields(resource)
    Enum.map_join(keys, delimiter, &to_string(Map.fetch!(record, &1)))
  end

  defp encoded_primary_key(resource, record) do
    delimiter = Info.primary_key_delimiter(resource)
    keys = Info.primary_key_fields(resource)
    Enum.map_join(keys, delimiter, &JsonApiCompositeId.encode_part(Map.fetch!(record, &1)))
  end

  defp index_read_opts(resource) do
    %{manual: {TelemetryIndexRead, opts}} = Ash.Resource.Info.action(resource, :api_index)
    opts
  end

  defp reply_rows(sql, parent, :trace) do
    send(parent, {:sql, sql})

    {:ok,
     %{
       columns: ["trace_id", "span_id", "timestamp", "service_name"],
       rows: [["abc123", "span1", "2026-01-01 00:00:00.000000", "api"]]
     }}
  end

  defp reply_rows(sql, parent, :summary) do
    send(parent, {:sql, sql})

    {:ok,
     %{
       columns: [
         "trace_id",
         "timestamp",
         "root_service_name",
         "duration_ms",
         "span_count",
         "service_set"
       ],
       rows: [["abc123", "2026-01-01 00:00:00.000000", "api", "12.5", "3", ~s(["api","db"])]]
     }}
  end
end
