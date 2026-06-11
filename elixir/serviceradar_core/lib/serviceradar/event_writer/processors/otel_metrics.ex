defmodule ServiceRadar.EventWriter.Processors.OtelMetrics do
  @moduledoc """
  Processor for OpenTelemetry metrics messages.

  Two distinct payload shapes arrive on the metrics subjects:

  - JSON span-derived performance samples (from the derived-metrics path) —
    inserted into the `otel_metrics` hypertable, unchanged behavior.
  - OTLP protobuf `ExportMetricsServiceRequest` (subject `otel.metrics.raw`) —
    sum/gauge/histogram data points are decoded into the `otel_metric_points`
    hypertable, keyed by (timestamp, metric_name, service_name, attributes_hash).

  Identifiers on span samples are normalized to the canonical contract via
  `ServiceRadar.EventWriter.OtelId`.

  ## otel_metrics Table Schema

  ```sql
  CREATE TABLE otel_metrics (
    timestamp TIMESTAMPTZ NOT NULL,
    trace_id TEXT,
    span_id TEXT,
    service_name TEXT,
    span_name TEXT,
    span_kind TEXT,
    duration_ms DOUBLE PRECISION,
    duration_seconds DOUBLE PRECISION,
    metric_type TEXT,
    http_method TEXT,
    http_route TEXT,
    http_status_code TEXT,
    grpc_service TEXT,
    grpc_method TEXT,
    grpc_status_code TEXT,
    is_slow BOOLEAN,
    component TEXT,
    level TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, span_name, service_name, span_id)
  );
  ```

  See `priv/repo/migrations/*create_otel_metric_points.exs` for the
  `otel_metric_points` schema.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Metrics.V1.Sum
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.OtelId
  alias ServiceRadar.EventWriter.OtlpAttributes

  require Logger

  @metric_points_table "otel_metric_points"

  @impl true
  def table_name, do: "otel_metrics"

  def metric_points_table_name, do: @metric_points_table

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    {span_sample_rows, point_rows} =
      messages
      |> Enum.flat_map(&List.wrap(parse_message(&1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.split_with(&span_sample_row?/1)

    sample_count = insert_rows(table_name(), span_sample_rows)
    point_count = insert_rows(@metric_points_table, point_rows)

    {:ok, sample_count + point_count}
  rescue
    e ->
      Logger.error("OtelMetrics batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case Jason.decode(data) do
      {:ok, json} ->
        parse_json_metric(json, metadata)

      {:error, _} ->
        # Try protobuf parsing
        parse_protobuf_metric(data, metadata)
    end
  end

  # Private functions

  defp span_sample_row?(row), do: not Map.has_key?(row, :metric_name)

  defp insert_rows(_table, []), do: 0

  defp insert_rows(table, rows) do
    # DB connection's search_path determines the schema
    {count, _} =
      ServiceRadar.Repo.insert_all(
        table,
        rows,
        on_conflict: :nothing,
        returning: false
      )

    count
  end

  defp parse_json_metric(json, _metadata) do
    if is_map(json) do
      timestamp = FieldParser.parse_timestamp(json["timestamp"])

      %{
        timestamp: timestamp,
        trace_id: OtelId.normalize_trace_id(FieldParser.get_field(json, "trace_id", "traceId")),
        span_id: OtelId.normalize_span_id(FieldParser.get_field(json, "span_id", "spanId")),
        service_name: FieldParser.get_field(json, "service_name", "serviceName", "unknown"),
        span_name:
          FieldParser.get_field(json, "span_name", "spanName") || json["name"] || "unknown",
        span_kind: FieldParser.get_field(json, "span_kind", "spanKind"),
        duration_ms: FieldParser.parse_duration_ms(json),
        duration_seconds: FieldParser.parse_duration_seconds(json),
        metric_type: FieldParser.get_field(json, "metric_type", "metricType"),
        http_method: FieldParser.get_field(json, "http_method", "httpMethod"),
        http_route: FieldParser.get_field(json, "http_route", "httpRoute"),
        http_status_code:
          to_string(FieldParser.get_field(json, "http_status_code", "httpStatusCode", "")),
        grpc_service: FieldParser.get_field(json, "grpc_service", "grpcService"),
        grpc_method: FieldParser.get_field(json, "grpc_method", "grpcMethod"),
        grpc_status_code:
          to_string(FieldParser.get_field(json, "grpc_status_code", "grpcStatusCode", "")),
        is_slow: FieldParser.get_field(json, "is_slow", "isSlow", false),
        component: json["component"],
        level: json["level"],
        created_at: DateTime.utc_now()
      }
    end
  end

  defp parse_protobuf_metric(data, metadata) do
    case decode_export_metrics(data) do
      {:ok, %ExportMetricsServiceRequest{} = request} ->
        parse_export_metrics(request, metadata)

      {:error, reason} ->
        Logger.debug("Failed to decode OTLP metrics protobuf: #{inspect(reason)}")
        nil
    end
  end

  defp decode_export_metrics(data) do
    {:ok, ExportMetricsServiceRequest.decode(data)}
  rescue
    error -> {:error, error}
  end

  defp parse_export_metrics(
         %ExportMetricsServiceRequest{resource_metrics: resource_metrics},
         _metadata
       ) do
    Enum.flat_map(resource_metrics, &parse_resource_metrics/1)
  end

  defp parse_resource_metrics(%ResourceMetrics{resource: resource, scope_metrics: scope_metrics}) do
    resource_attributes = OtlpAttributes.key_values_to_map(resource && resource.attributes)

    service_name =
      resource_attributes["service.name"] || resource_attributes["service_name"] || ""

    Enum.flat_map(scope_metrics, fn
      %ScopeMetrics{metrics: metrics} -> Enum.flat_map(metrics, &parse_metric(&1, service_name))
      _ -> []
    end)
  end

  defp parse_resource_metrics(_), do: []

  defp parse_metric(%Metric{name: name, unit: unit, data: data}, service_name) do
    unit = if unit == "", do: nil, else: unit

    case data do
      {:sum, %Sum{} = sum} ->
        Enum.map(
          sum.data_points,
          &number_point_row(&1, name, "sum", unit, service_name,
            temporality: temporality(sum.aggregation_temporality),
            is_monotonic: sum.is_monotonic
          )
        )

      {:gauge, %Gauge{} = gauge} ->
        Enum.map(
          gauge.data_points,
          &number_point_row(&1, name, "gauge", unit, service_name, [])
        )

      {:histogram, %Histogram{} = histogram} ->
        Enum.map(
          histogram.data_points,
          &histogram_point_row(&1, name, unit, service_name,
            temporality: temporality(histogram.aggregation_temporality)
          )
        )

      _other ->
        []
    end
  end

  defp parse_metric(_, _service_name), do: []

  defp number_point_row(%NumberDataPoint{} = point, name, type, unit, service_name, opts) do
    name
    |> base_point_row(type, unit, service_name, point.attributes, point.time_unix_nano, opts)
    |> Map.put(:value, number_point_value(point))
  end

  defp histogram_point_row(%HistogramDataPoint{} = point, name, unit, service_name, opts) do
    name
    |> base_point_row(
      "histogram",
      unit,
      service_name,
      point.attributes,
      point.time_unix_nano,
      opts
    )
    |> Map.merge(%{
      count: FieldParser.safe_bigint(point.count),
      sum: point.sum,
      bucket_counts: Jason.encode!(point.bucket_counts || []),
      explicit_bounds: Jason.encode!(point.explicit_bounds || [])
    })
  end

  defp base_point_row(name, type, unit, service_name, attributes, time_unix_nano, opts) do
    attributes_json = encode_point_attributes(attributes)

    %{
      timestamp: point_timestamp(time_unix_nano),
      metric_name: name,
      metric_type: type,
      unit: unit,
      temporality: Keyword.get(opts, :temporality),
      is_monotonic: Keyword.get(opts, :is_monotonic),
      service_name: service_name,
      attributes: attributes_json,
      attributes_hash: md5_hex(attributes_json),
      value: nil,
      count: nil,
      sum: nil,
      bucket_counts: nil,
      explicit_bounds: nil,
      created_at: DateTime.utc_now()
    }
  end

  defp number_point_value(%NumberDataPoint{value: {:as_double, value}}), do: value

  defp number_point_value(%NumberDataPoint{value: {:as_int, value}}) when is_integer(value),
    do: value * 1.0

  defp number_point_value(_), do: nil

  # Encode point attributes deterministically (sorted keys) so that
  # attributes_hash is stable for identical attribute sets.
  defp encode_point_attributes(attributes) do
    attributes
    |> OtlpAttributes.key_values_to_map()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp md5_hex(text) do
    :md5 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  defp point_timestamp(ns) when is_integer(ns) and ns > 0 do
    DateTime.from_unix!(div(ns, 1000), :microsecond)
  rescue
    _ -> DateTime.utc_now()
  end

  defp point_timestamp(_), do: DateTime.utc_now()

  defp temporality(value) when is_atom(value) and not is_nil(value) do
    case value do
      :AGGREGATION_TEMPORALITY_DELTA -> "delta"
      :AGGREGATION_TEMPORALITY_CUMULATIVE -> "cumulative"
      _ -> "unspecified"
    end
  end

  defp temporality(1), do: "delta"
  defp temporality(2), do: "cumulative"
  defp temporality(_), do: "unspecified"
end
