defmodule ServiceRadar.EventWriter.Processors.OtelTraces do
  @moduledoc """
  Processor for OpenTelemetry trace messages.

  Parses OTEL traces from NATS JetStream and inserts them into
  the `otel_traces` hypertable.

  ## Message Format

  Supports both JSON and protobuf formats:

  - Protobuf: OpenTelemetry `ExportTraceServiceRequest`
  - JSON: Trace span data with attributes

  Identifiers are normalized to the canonical contract (32/16 character
  lowercase hex, NULL for absent/zero ids) via `ServiceRadar.EventWriter.OtelId`.

  ## Table Schema

  ```sql
  CREATE TABLE otel_traces (
    timestamp TIMESTAMPTZ NOT NULL,
    trace_id TEXT,
    span_id TEXT,
    parent_span_id TEXT,
    name TEXT,
    kind INTEGER,
    start_time_unix_nano BIGINT,
    end_time_unix_nano BIGINT,
    service_name TEXT,
    service_version TEXT,
    service_instance TEXT,
    scope_name TEXT,
    scope_version TEXT,
    scope_attributes TEXT,
    status_code INTEGER,
    status_message TEXT,
    trace_state TEXT,
    attributes TEXT,
    resource_attributes TEXT,
    events TEXT,
    links TEXT,
    dropped_attributes_count INTEGER NOT NULL DEFAULT 0,
    dropped_events_count INTEGER NOT NULL DEFAULT 0,
    dropped_links_count INTEGER NOT NULL DEFAULT 0,
    service_namespace TEXT NOT NULL DEFAULT '',
    deployment_environment TEXT NOT NULL DEFAULT '',
    ingest_identity TEXT NOT NULL DEFAULT '',
    ingest_agent_id TEXT NOT NULL DEFAULT '',
    ingest_partition TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, trace_id, span_id)
  );
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceRequest
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Trace.V1.ResourceSpans
  alias Opentelemetry.Proto.Trace.V1.ScopeSpans
  alias Opentelemetry.Proto.Trace.V1.Span
  alias Opentelemetry.Proto.Trace.V1.Span.SpanKind
  alias Opentelemetry.Proto.Trace.V1.Status
  alias Opentelemetry.Proto.Trace.V1.Status.StatusCode
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.IngestAttribution
  alias ServiceRadar.EventWriter.OtelId
  alias ServiceRadar.EventWriter.OtlpAttributes
  alias ServiceRadar.EventWriter.SignalTelemetry
  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
  alias ServiceRadar.Observability.OtelPubSub
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @impl true
  def table_name, do: "otel_traces"

  @impl true
  def process_batch(messages) do
    SignalTelemetry.emit(:traces, :received, length(messages))

    # DB connection's search_path determines the schema
    {rows, rejected} = build_rows(messages)
    SignalTelemetry.emit(:traces, :rejected, rejected)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_trace_rows(rows)
    end
  rescue
    e ->
      Logger.error("OtelTraces batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    attribution = IngestAttribution.from_metadata(metadata)

    case_result =
      case Jason.decode(data) do
        {:ok, json} ->
          parse_json_trace(json, metadata)

        {:error, _} ->
          # Try protobuf parsing
          parse_protobuf_trace(data, metadata)
      end

    IngestAttribution.attach(case_result, attribution)
  end

  # Private functions

  defp build_rows(messages) do
    parsed = Enum.map(messages, &parse_message/1)
    rejected = Enum.count(parsed, &is_nil/1)

    rows =
      parsed
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&List.wrap/1)

    {rows, rejected}
  end

  defp insert_trace_rows(rows) do
    # DB connection's search_path determines the schema
    {count, _} =
      BulkInsert.insert_all(
        table_name(),
        rows,
        on_conflict: :nothing,
        returning: false
      )

    SignalTelemetry.emit(:traces, :written, count)
    OtelPubSub.broadcast_traces(%{count: count})
    if count > 0, do: request_summary_refresh()
    {:ok, count}
  end

  defp request_summary_refresh do
    case %{} |> RefreshTraceSummariesWorker.new() |> ObanSupport.safe_insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.debug("Trace summaries prompt refresh unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp parse_json_trace(json, _metadata) do
    timestamp = FieldParser.parse_timestamp(json["timestamp"] || json["start_time_unix_nano"])

    resource_attributes =
      FieldParser.get_field(json, "resource_attributes", "resourceAttributes")

    %{
      timestamp: timestamp,
      trace_id: OtelId.normalize_trace_id(FieldParser.get_field(json, "trace_id", "traceId")),
      span_id: OtelId.normalize_span_id(FieldParser.get_field(json, "span_id", "spanId")),
      parent_span_id:
        OtelId.normalize_parent_span_id(
          FieldParser.get_field(json, "parent_span_id", "parentSpanId")
        ),
      name: json["name"],
      kind: json["kind"],
      start_time_unix_nano:
        FieldParser.safe_bigint(
          FieldParser.get_field(json, "start_time_unix_nano", "startTimeUnixNano")
        ),
      end_time_unix_nano:
        FieldParser.safe_bigint(
          FieldParser.get_field(json, "end_time_unix_nano", "endTimeUnixNano")
        ),
      service_name: FieldParser.get_field(json, "service_name", "serviceName", "unknown"),
      service_version: FieldParser.get_field(json, "service_version", "serviceVersion"),
      service_instance: FieldParser.get_field(json, "service_instance", "serviceInstance"),
      scope_name: FieldParser.get_field(json, "scope_name", "scopeName"),
      scope_version: FieldParser.get_field(json, "scope_version", "scopeVersion"),
      scope_attributes:
        encode_scope_attributes(
          FieldParser.get_field(json, "scope_attributes", "scopeAttributes")
        ),
      status_code: FieldParser.get_field(json, "status_code", "statusCode"),
      status_message: FieldParser.get_field(json, "status_message", "statusMessage"),
      trace_state:
        normalize_trace_state(FieldParser.get_field(json, "trace_state", "traceState")),
      attributes: FieldParser.encode_json(json["attributes"]),
      resource_attributes: FieldParser.encode_json(resource_attributes),
      events: FieldParser.encode_json(json["events"]),
      links: FieldParser.encode_json(json["links"]),
      dropped_attributes_count:
        dropped_count(
          FieldParser.get_field(json, "dropped_attributes_count", "droppedAttributesCount")
        ),
      dropped_events_count:
        dropped_count(FieldParser.get_field(json, "dropped_events_count", "droppedEventsCount")),
      dropped_links_count:
        dropped_count(FieldParser.get_field(json, "dropped_links_count", "droppedLinksCount")),
      service_namespace:
        json_string_field(json, "service_namespace", "serviceNamespace") ||
          service_namespace(resource_attributes),
      deployment_environment:
        json_string_field(json, "deployment_environment", "deploymentEnvironment") ||
          deployment_environment(resource_attributes),
      created_at: DateTime.utc_now()
    }
  end

  defp parse_protobuf_trace(data, metadata) do
    case decode_export_traces(data) do
      {:ok, %ExportTraceServiceRequest{} = request} ->
        parse_export_traces(request, metadata)

      {:error, reason} ->
        Logger.debug("Failed to decode OTLP traces protobuf: #{inspect(reason)}")
        nil
    end
  end

  defp decode_export_traces(data) do
    {:ok, ExportTraceServiceRequest.decode(data)}
  rescue
    error -> {:error, error}
  end

  defp parse_export_traces(%ExportTraceServiceRequest{resource_spans: resource_spans}, metadata) do
    Enum.flat_map(resource_spans, &parse_resource_spans(&1, metadata))
  end

  defp parse_resource_spans(
         %ResourceSpans{resource: resource, scope_spans: scope_spans},
         metadata
       ) do
    resource_attributes = OtlpAttributes.key_values_to_map(resource && resource.attributes)

    service_name =
      resource_attributes["service.name"] || resource_attributes["service_name"] || "unknown"

    service_version =
      resource_attributes["service.version"] || resource_attributes["service_version"]

    service_instance =
      resource_attributes["service.instance.id"] || resource_attributes["service_instance"]

    Enum.flat_map(scope_spans, fn scope_span ->
      parse_scope_spans(
        scope_span,
        service_name,
        service_version,
        service_instance,
        resource_attributes,
        metadata
      )
    end)
  end

  defp parse_resource_spans(_, _metadata), do: []

  defp parse_scope_spans(
         %ScopeSpans{scope: scope, spans: spans},
         service_name,
         service_version,
         service_instance,
         resource_attributes,
         _metadata
       ) do
    {scope_name, scope_version, scope_attributes} = parse_scope(scope)
    encoded_resource_attributes = FieldParser.encode_json(resource_attributes)
    service_namespace = service_namespace(resource_attributes)
    deployment_environment = deployment_environment(resource_attributes)

    Enum.map(spans, fn %Span{} = span ->
      %{
        timestamp: span_timestamp(span),
        trace_id: OtelId.normalize_trace_id(span.trace_id),
        span_id: OtelId.normalize_span_id(span.span_id),
        parent_span_id: OtelId.normalize_parent_span_id(span.parent_span_id),
        name: span.name,
        kind: enum_to_int(SpanKind, span.kind),
        start_time_unix_nano: FieldParser.safe_bigint(span.start_time_unix_nano),
        end_time_unix_nano: FieldParser.safe_bigint(span.end_time_unix_nano),
        service_name: service_name,
        service_version: service_version,
        service_instance: service_instance,
        scope_name: scope_name,
        scope_version: scope_version,
        scope_attributes: scope_attributes,
        status_code: status_code(span.status),
        status_message: status_message(span.status),
        trace_state: normalize_trace_state(span.trace_state),
        attributes: FieldParser.encode_json(OtlpAttributes.key_values_to_map(span.attributes)),
        resource_attributes: encoded_resource_attributes,
        events: FieldParser.encode_json(Enum.map(span.events, &event_to_map/1)),
        links: FieldParser.encode_json(Enum.map(span.links, &link_to_map/1)),
        dropped_attributes_count: dropped_count(span.dropped_attributes_count),
        dropped_events_count: dropped_count(span.dropped_events_count),
        dropped_links_count: dropped_count(span.dropped_links_count),
        service_namespace: service_namespace,
        deployment_environment: deployment_environment,
        created_at: DateTime.utc_now()
      }
    end)
  end

  defp parse_scope_spans(
         _,
         _service_name,
         _service_version,
         _service_instance,
         _resource_attributes,
         _metadata
       ), do: []

  defp parse_scope(%InstrumentationScope{name: name, version: version} = scope) do
    {name, version, encode_scope_attributes(OtlpAttributes.key_values_to_map(scope.attributes))}
  end

  defp parse_scope(_), do: {nil, nil, nil}

  # Instrumentation scope attributes are stored as sorted-key JSON text;
  # empty attribute sets are stored as NULL (never "{}").
  defp encode_scope_attributes(map) when is_map(map) do
    if map_size(map) == 0, do: nil, else: OtlpAttributes.stable_json(map)
  end

  defp encode_scope_attributes(value) when is_binary(value) and value not in ["", "{}"], do: value
  defp encode_scope_attributes(_), do: nil

  # span.trace_state: empty string means "absent" and is stored as NULL.
  defp normalize_trace_state(value) when is_binary(value) and value != "", do: value
  defp normalize_trace_state(_), do: nil

  defp dropped_count(value) when is_integer(value) and value >= 0, do: value

  defp dropped_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp dropped_count(_), do: 0

  # Resource attribute "service.namespace" (default '').
  defp service_namespace(resource_attributes),
    do: resource_attr_string(resource_attributes, ["service.namespace"])

  # Resource attribute "deployment.environment.name" falling back to the
  # legacy "deployment.environment" key (default '').
  defp deployment_environment(resource_attributes) do
    resource_attr_string(resource_attributes, [
      "deployment.environment.name",
      "deployment.environment"
    ])
  end

  defp resource_attr_string(attributes, keys) when is_map(attributes) do
    Enum.find_value(keys, "", fn key ->
      case attributes do
        %{^key => value} when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp resource_attr_string(_attributes, _keys), do: ""

  defp json_string_field(json, snake_key, camel_key) do
    case FieldParser.get_field(json, snake_key, camel_key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # Derive the row timestamp from the span start time, preserving
  # microsecond precision (TIMESTAMPTZ resolution).
  defp span_timestamp(%Span{start_time_unix_nano: start_ns, end_time_unix_nano: end_ns}) do
    cond do
      is_integer(start_ns) and start_ns > 0 -> from_unix_nano(start_ns)
      is_integer(end_ns) and end_ns > 0 -> from_unix_nano(end_ns)
      true -> DateTime.utc_now()
    end
  end

  defp from_unix_nano(ns) do
    DateTime.from_unix!(div(ns, 1000), :microsecond)
  rescue
    _ -> DateTime.utc_now()
  end

  defp status_code(%Status{code: code}), do: enum_to_int(StatusCode, code) || 0
  defp status_code(_), do: 0

  defp status_message(%Status{message: message}) when is_binary(message) and message != "",
    do: message

  defp status_message(_), do: nil

  defp enum_to_int(_module, value) when is_integer(value), do: value

  defp enum_to_int(module, value) when is_atom(value) and not is_nil(value) do
    module.value(value)
  rescue
    _ -> nil
  end

  defp enum_to_int(_module, _value), do: nil

  defp event_to_map(%Span.Event{} = event) do
    %{
      "time_unix_nano" => event.time_unix_nano,
      "name" => event.name,
      "attributes" => OtlpAttributes.key_values_to_map(event.attributes),
      "dropped_attributes_count" => event.dropped_attributes_count
    }
  end

  defp event_to_map(_), do: %{}

  defp link_to_map(%Span.Link{} = link) do
    %{
      "trace_id" => OtelId.normalize_trace_id(link.trace_id),
      "span_id" => OtelId.normalize_span_id(link.span_id),
      "trace_state" => link.trace_state,
      "attributes" => OtlpAttributes.key_values_to_map(link.attributes)
    }
  end

  defp link_to_map(_), do: %{}
end
