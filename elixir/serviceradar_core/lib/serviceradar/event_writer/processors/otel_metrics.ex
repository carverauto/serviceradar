defmodule ServiceRadar.EventWriter.Processors.OtelMetrics do
  @moduledoc """
  Processor for OpenTelemetry metrics messages.

  Two distinct protobuf payload shapes arrive on the metrics subjects:

  - ServiceRadar `serviceradar.metric.v1.MetricBatch` span-derived
    performance samples (from the derived-metrics path) —
    inserted into the `otel_metrics` hypertable, unchanged behavior.
  - OTLP protobuf `ExportMetricsServiceRequest` (subject `otel.metrics.raw`) —
    sum/gauge/histogram data points are decoded into the `otel_metric_points`
    hypertable, keyed by (timestamp, metric_name, service_name, attributes_hash).

  `attributes_hash` follows recipe v2 (see `ServiceRadar.EventWriter.OtlpAttributes`):
  MD5 over `canonical_bytes(point_attributes) <> "\\n" <> service_instance_id
  <> "\\n" <> scope_name`, kept in lockstep with the Go gateway
  implementation. The stored `attributes` column is display JSON with map
  keys sorted at every nesting level.

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
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Metrics.V1.Sum
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.IngestAttribution
  alias ServiceRadar.EventWriter.OtelId
  alias ServiceRadar.EventWriter.OtlpAttributes
  alias ServiceRadar.EventWriter.SignalTelemetry
  alias Serviceradar.Metric.V1.MetricBatch, as: ServiceRadarMetricBatch
  alias ServiceRadar.Observability.OtelPubSub

  require Logger

  @metric_points_table "otel_metric_points"

  @impl true
  def table_name, do: "otel_metrics"

  def metric_points_table_name, do: @metric_points_table

  @impl true
  def process_batch(messages) do
    SignalTelemetry.emit(:metrics, :received, length(messages))

    # DB connection's search_path determines the schema
    {span_sample_rows, point_rows, rejected} = build_rows(messages)
    SignalTelemetry.emit(:metrics, :rejected, rejected)

    sample_count = insert_rows(table_name(), span_sample_rows)
    point_count = insert_rows(@metric_points_table, point_rows)

    SignalTelemetry.emit(:metrics, :written, sample_count)
    SignalTelemetry.emit(:metric_points, :written, point_count)

    OtelPubSub.broadcast_metrics(%{count: sample_count + point_count})

    {:ok, sample_count + point_count}
  rescue
    e ->
      Logger.error("OtelMetrics batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    attribution = IngestAttribution.from_metadata(metadata)

    case_result =
      if derived_metrics_subject?(metadata) do
        parse_derived_metric_batch(data, metadata)
      else
        parse_protobuf_metric(data, metadata)
      end

    IngestAttribution.attach(case_result, attribution)
  end

  # Private functions

  defp span_sample_row?(row), do: not Map.has_key?(row, :metric_name)

  defp build_rows(messages) do
    messages
    |> Enum.reduce({[], [], 0}, fn message, acc ->
      case parse_message(message) do
        rows when is_list(rows) ->
          Enum.reduce(rows, acc, &append_row/2)

        _ ->
          {span_sample_rows, point_rows, rejected} = acc
          {span_sample_rows, point_rows, rejected + 1}
      end
    end)
    |> then(fn {span_sample_rows, point_rows, rejected} ->
      {Enum.reverse(span_sample_rows), Enum.reverse(point_rows), rejected}
    end)
  end

  defp append_row(row, {span_sample_rows, point_rows, rejected}) do
    if span_sample_row?(row) do
      {[row | span_sample_rows], point_rows, rejected}
    else
      {span_sample_rows, [row | point_rows], rejected}
    end
  end

  defp insert_rows(_table, []), do: 0

  defp insert_rows(table, rows) do
    # DB connection's search_path determines the schema
    {count, _} =
      BulkInsert.insert_all(
        table,
        rows,
        on_conflict: :nothing,
        returning: false
      )

    count
  end

  defp derived_metrics_subject?(metadata) when is_map(metadata) do
    metadata
    |> subject()
    |> String.starts_with?("otel.metrics.derived")
  end

  defp derived_metrics_subject?(_metadata), do: false

  defp subject(metadata), do: to_string(metadata[:base_subject] || metadata[:subject] || "")

  defp parse_derived_metric_batch(data, metadata) do
    case decode_service_radar_metric_batch(data) do
      {:ok, %ServiceRadarMetricBatch{} = batch} ->
        parse_derived_metric_batch_rows(batch)

      {:error, reason} ->
        Logger.debug("Failed to decode derived metrics protobuf: #{inspect(reason)}",
          subject: subject(metadata)
        )

        nil
    end
  end

  defp decode_service_radar_metric_batch(data) do
    {:ok, ServiceRadarMetricBatch.decode(data)}
  rescue
    error -> {:error, error}
  end

  defp parse_derived_metric_batch_rows(%ServiceRadarMetricBatch{
         schema_version: "serviceradar.metric.v1",
         metrics: metrics
       })
       when is_list(metrics) do
    metrics
    |> Enum.reduce([], fn metric, rows ->
      metric.points
      |> list_or_empty()
      |> Enum.reduce(rows, fn point, rows ->
        [derived_span_row(point) | rows]
      end)
    end)
    |> Enum.reverse()
  end

  defp parse_derived_metric_batch_rows(_batch), do: nil

  defp derived_span_row(point) do
    attributes = entries_to_map(point.attributes)
    metadata = entries_to_map(point.metadata)
    created_at = DateTime.utc_now()

    %{
      timestamp: derived_timestamp(point, metadata),
      trace_id: OtelId.normalize_trace_id(metadata["trace_id"]),
      span_id: OtelId.normalize_span_id(metadata["span_id"]),
      service_name: attributes["service_name"] || "unknown",
      span_name: attributes["span_name"] || "unknown",
      span_kind: attributes["span_kind"],
      duration_ms: point.value,
      duration_seconds: parse_float(metadata["duration_seconds"]),
      metric_type: metadata["metric_type"],
      http_method: attributes["http_method"],
      http_route: attributes["http_route"],
      http_status_code: attributes["http_status_code"] || "",
      grpc_service: attributes["grpc_service"],
      grpc_method: attributes["grpc_method"],
      grpc_status_code: attributes["grpc_status_code"] || "",
      is_slow: parse_bool(metadata["is_slow"]),
      component: metadata["component"],
      level: metadata["level"],
      created_at: created_at
    }
  end

  defp derived_timestamp(%{observed_at_unix_nano: observed_at}, _metadata)
       when is_integer(observed_at) and observed_at > 0, do: point_timestamp(observed_at)

  defp derived_timestamp(_point, metadata), do: FieldParser.parse_timestamp(metadata["timestamp"])

  defp entries_to_map(entries) when is_list(entries) do
    Map.new(entries, fn entry -> {entry.key, entry.value} end)
  end

  defp entries_to_map(_entries), do: %{}

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_float(_value), do: nil

  defp parse_bool(value) when value in [true, false], do: value
  defp parse_bool(value) when is_binary(value), do: String.downcase(value) == "true"
  defp parse_bool(_value), do: false

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

    service_instance_id =
      case resource_attributes["service.instance.id"] do
        value when is_binary(value) -> value
        _ -> ""
      end

    Enum.flat_map(scope_metrics, fn
      %ScopeMetrics{scope: scope, metrics: metrics} ->
        identity = %{
          service_name: service_name,
          service_instance_id: service_instance_id,
          scope_name: scope_name(scope)
        }

        Enum.flat_map(metrics, &parse_metric(&1, identity))

      _ ->
        []
    end)
  end

  defp parse_resource_metrics(_), do: []

  defp scope_name(%InstrumentationScope{name: name}) when is_binary(name), do: name
  defp scope_name(_), do: ""

  defp parse_metric(%Metric{name: name, unit: unit, data: data}, identity) do
    unit = if unit == "", do: nil, else: unit

    case data do
      {:sum, %Sum{} = sum} ->
        Enum.map(
          sum.data_points,
          &number_point_row(&1, name, "sum", unit, identity,
            temporality: temporality(sum.aggregation_temporality),
            is_monotonic: sum.is_monotonic
          )
        )

      {:gauge, %Gauge{} = gauge} ->
        Enum.map(
          gauge.data_points,
          &number_point_row(&1, name, "gauge", unit, identity, [])
        )

      {:histogram, %Histogram{} = histogram} ->
        Enum.map(
          histogram.data_points,
          &histogram_point_row(&1, name, unit, identity,
            temporality: temporality(histogram.aggregation_temporality)
          )
        )

      {:exponential_histogram, %Opentelemetry.Proto.Metrics.V1.ExponentialHistogram{} = eh} ->
        reject_unsupported_points(name, "exponential_histogram", length(eh.data_points))

      {:summary, %Opentelemetry.Proto.Metrics.V1.Summary{} = summary} ->
        reject_unsupported_points(name, "summary", length(summary.data_points))

      _other ->
        []
    end
  end

  defp parse_metric(_, _identity), do: []

  # Decoding exponential histograms and summaries is a spec'd follow-up
  # (tasks.md 8.3); until then they are counted, never silently dropped.
  defp reject_unsupported_points(name, type, point_count) do
    SignalTelemetry.emit(:metric_points, :rejected, point_count)

    Logger.debug(
      "Dropping unsupported OTLP metric type #{type} for #{name} (#{point_count} data points)"
    )

    []
  end

  defp number_point_row(%NumberDataPoint{} = point, name, type, unit, identity, opts) do
    name
    |> base_point_row(type, unit, identity, point, opts)
    |> Map.put(:value, number_point_value(point))
  end

  defp histogram_point_row(%HistogramDataPoint{} = point, name, unit, identity, opts) do
    name
    |> base_point_row("histogram", unit, identity, point, opts)
    |> Map.merge(%{
      count: FieldParser.safe_bigint(point.count),
      sum: point.sum,
      bucket_counts: Jason.encode!(point.bucket_counts || []),
      explicit_bounds: Jason.encode!(point.explicit_bounds || [])
    })
  end

  defp base_point_row(name, type, unit, identity, point, opts) do
    canonical_attributes = OtlpAttributes.key_values_to_canonical_map(point.attributes)

    %{
      timestamp: point_timestamp(point.time_unix_nano),
      metric_name: name,
      metric_type: type,
      unit: unit,
      temporality: Keyword.get(opts, :temporality),
      is_monotonic: Keyword.get(opts, :is_monotonic),
      service_name: identity.service_name,
      service_instance_id: identity.service_instance_id,
      scope_name: identity.scope_name,
      start_time_unix_nano: positive_nano(point.start_time_unix_nano),
      attributes: OtlpAttributes.stable_json(canonical_attributes),
      attributes_hash:
        OtlpAttributes.attributes_hash(
          canonical_attributes,
          identity.service_instance_id,
          identity.scope_name
        ),
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

  defp positive_nano(ns) when is_integer(ns) and ns > 0, do: FieldParser.safe_bigint(ns)
  defp positive_nano(_), do: nil

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
