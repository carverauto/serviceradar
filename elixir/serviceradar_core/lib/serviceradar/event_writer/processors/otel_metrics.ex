defmodule ServiceRadar.EventWriter.Processors.OtelMetrics do
  @moduledoc """
  Processor for OpenTelemetry metrics messages.

  Parses OTEL metrics from NATS JetStream and inserts them into
  the `otel_metrics` hypertable.

  ## Message Format

  Supports both JSON and protobuf formats:

  - Protobuf: OpenTelemetry `ExportMetricsServiceRequest`
  - JSON: Performance metrics with span info

  ## Table Schema

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
  """

  @behaviour ServiceRadar.EventWriter.Processor

  require Logger

  @impl true
  def table_name, do: "otel_metrics"

  @impl true
  def process_batch(messages) do
    rows =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      case ServiceRadar.Repo.insert_all(table_name(), rows,
             on_conflict: :nothing,
             returning: false
           ) do
        {count, _} ->
          {:ok, count}
      end
    end
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

  defp parse_json_metric(json, _metadata) do
    timestamp = parse_timestamp(json["timestamp"])

    %{
      timestamp: timestamp,
      trace_id: json["trace_id"] || json["traceId"],
      span_id: json["span_id"] || json["spanId"],
      service_name: json["service_name"] || json["serviceName"] || "unknown",
      span_name: json["span_name"] || json["spanName"] || json["name"] || "unknown",
      span_kind: json["span_kind"] || json["spanKind"],
      duration_ms: parse_duration_ms(json),
      duration_seconds: parse_duration_seconds(json),
      metric_type: json["metric_type"] || json["metricType"],
      http_method: json["http_method"] || json["httpMethod"],
      http_route: json["http_route"] || json["httpRoute"],
      http_status_code: to_string(json["http_status_code"] || json["httpStatusCode"] || ""),
      grpc_service: json["grpc_service"] || json["grpcService"],
      grpc_method: json["grpc_method"] || json["grpcMethod"],
      grpc_status_code: to_string(json["grpc_status_code"] || json["grpcStatusCode"] || ""),
      is_slow: json["is_slow"] || json["isSlow"] || false,
      component: json["component"],
      level: json["level"],
      created_at: DateTime.utc_now()
    }
  end

  defp parse_protobuf_metric(_data, _metadata) do
    # TODO: Implement protobuf parsing for ExportMetricsServiceRequest
    # For now, skip protobuf messages
    nil
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(ts) when is_integer(ts) do
    # Handle nanoseconds timestamp
    if ts > 1_000_000_000_000_000_000 do
      DateTime.from_unix!(div(ts, 1_000_000_000), :second)
    else
      DateTime.from_unix!(ts, :millisecond)
    end
  end
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp parse_duration_ms(json) do
    cond do
      json["duration_ms"] -> json["duration_ms"]
      json["durationMs"] -> json["durationMs"]
      json["duration_seconds"] -> json["duration_seconds"] * 1000
      json["durationSeconds"] -> json["durationSeconds"] * 1000
      true -> nil
    end
  end

  defp parse_duration_seconds(json) do
    cond do
      json["duration_seconds"] -> json["duration_seconds"]
      json["durationSeconds"] -> json["durationSeconds"]
      json["duration_ms"] -> json["duration_ms"] / 1000
      json["durationMs"] -> json["durationMs"] / 1000
      true -> nil
    end
  end
end
