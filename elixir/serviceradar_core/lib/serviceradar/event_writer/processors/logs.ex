defmodule ServiceRadar.EventWriter.Processors.Logs do
  @moduledoc """
  Processor for OpenTelemetry log messages.

  Parses OTEL logs from NATS JetStream and inserts them into the `logs`
  hypertable using the native OTEL schema.

  ## Message Format

  Supports:
  - JSON log records (OTEL-style fields)
  - OTLP protobuf `ExportLogsServiceRequest`
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest

  alias Opentelemetry.Proto.Common.V1.{
    AnyValue,
    ArrayValue,
    InstrumentationScope,
    KeyValue,
    KeyValueList
  }

  alias Opentelemetry.Proto.Logs.V1.{LogRecord, ResourceLogs, ScopeLogs}
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Observability.LogPromotion

  require Logger

  @impl true
  def table_name, do: "logs"

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    rows = build_rows(messages)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_log_rows(rows)
    end
  rescue
    e ->
      Logger.error("Logs batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case Jason.decode(data) do
      {:ok, _} = decoded -> parse_log_payload(decoded, data, metadata)
      {:error, _} = error -> parse_log_payload(error, data, metadata)
    end
  end

  # Private functions

  defp build_rows(messages) do
    messages
    |> Enum.flat_map(&List.wrap(parse_message(&1)))
    |> Enum.reject(&is_nil/1)
  end

  defp insert_log_rows(rows) do
    # DB connection's search_path determines the schema
    case ServiceRadar.Repo.insert_all(
           table_name(),
           rows,
           on_conflict: :nothing,
           returning: false
         ) do
      {count, _} ->
        maybe_promote_logs(rows)
        {:ok, count}
    end
  end

  defp parse_log_payload({:ok, json}, _data, metadata) do
    parse_json_log(json, metadata)
  end

  defp parse_log_payload({:error, _}, data, metadata) do
    parse_protobuf_log(data, metadata)
  end

  defp parse_json_log(json, metadata) when is_map(json) do
    log_id = Ash.UUID.generate()
    attributes = FieldParser.encode_jsonb(json["attributes"]) || %{}
    attributes = attach_ingest_metadata(attributes, metadata)
    resource_attributes = normalize_resource_attributes(json)
    {scope_name, scope_version} = parse_scope_fields(json)

    %{
      id: log_id,
      timestamp: parse_timestamp(json),
      observed_timestamp: parse_observed_timestamp(json),
      trace_id: FieldParser.get_field(json, "trace_id", "traceId"),
      span_id: FieldParser.get_field(json, "span_id", "spanId"),
      trace_flags: parse_trace_flags(json),
      severity_text:
        FieldParser.get_field(json, "severity_text", "severityText") || json["level"],
      severity_number:
        json
        |> FieldParser.get_field("severity_number", "severityNumber")
        |> FieldParser.safe_bigint(),
      body: extract_body(json),
      event_name: FieldParser.get_field(json, "event_name", "eventName"),
      service_name:
        service_field(json, resource_attributes, "service_name", "serviceName", "service.name"),
      service_version:
        service_field(
          json,
          resource_attributes,
          "service_version",
          "serviceVersion",
          "service.version"
        ),
      service_instance:
        service_field(
          json,
          resource_attributes,
          "service_instance",
          "serviceInstance",
          "service.instance.id"
        ),
      scope_name: scope_name,
      scope_version: scope_version,
      scope_attributes: parse_scope_attributes(json),
      attributes: attributes,
      resource_attributes: resource_attributes,
      created_at: DateTime.utc_now()
    }
  end

  defp parse_json_log(_json, _metadata), do: nil

  defp parse_scope_fields(json) when is_map(json) do
    scope_name = FieldParser.get_field(json, "scope_name", "scopeName")
    scope_version = FieldParser.get_field(json, "scope_version", "scopeVersion")

    json["scope"]
    |> merge_scope_fields(scope_name, scope_version)
  end

  defp parse_scope_fields(_), do: {nil, nil}

  defp parse_scope_attributes(json) when is_map(json) do
    json
    |> FieldParser.get_field("scope_attributes", "scopeAttributes")
    |> case do
      nil -> json["scope"]
      value -> value
    end
    |> FieldParser.encode_jsonb()
    |> case do
      nil -> %{}
      value -> value
    end
  end

  defp parse_scope_attributes(_), do: %{}

  defp parse_observed_timestamp(json) when is_map(json) do
    case json["observed_timestamp"] ||
           json["observedTimestamp"] ||
           json["observed_time_unix_nano"] ||
           json["observedTimeUnixNano"] do
      nil -> nil
      value -> FieldParser.parse_timestamp(value)
    end
  end

  defp parse_observed_timestamp(_), do: nil

  defp parse_trace_flags(json) when is_map(json) do
    case json["trace_flags"] || json["traceFlags"] || json["flags"] do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_trace_flags(_), do: nil

  defp normalize_resource_attributes(json) do
    json
    |> resource_attributes_source()
    |> FieldParser.encode_jsonb()
    |> case do
      nil -> %{}
      value -> value
    end
  end

  defp resource_attributes_source(json) do
    FieldParser.get_field(json, "resource_attributes", "resourceAttributes") || json["resource"]
  end

  defp service_field(json, resource_attributes, snake_key, camel_key, resource_key) do
    FieldParser.get_field(json, snake_key, camel_key) || resource_attributes[resource_key]
  end

  defp merge_scope_fields(%{} = scope_map, scope_name, scope_version) do
    scope_name =
      scope_name ||
        FieldParser.get_field(scope_map, "name", "scopeName") ||
        FieldParser.get_field(scope_map, "scope_name", "scopeName")

    scope_version =
      scope_version ||
        FieldParser.get_field(scope_map, "version", "scopeVersion") ||
        FieldParser.get_field(scope_map, "scope_version", "scopeVersion")

    {scope_name, scope_version}
  end

  defp merge_scope_fields(scope, scope_name, scope_version)
       when is_binary(scope) and scope != "" do
    {scope_name || scope, scope_version}
  end

  defp merge_scope_fields(_, scope_name, scope_version), do: {scope_name, scope_version}

  defp parse_protobuf_log(data, metadata) do
    case decode_export_logs(data) do
      {:ok, %ExportLogsServiceRequest{} = request} ->
        parse_export_logs(request, metadata)

      {:error, reason} ->
        Logger.debug("Failed to decode OTLP logs protobuf: #{inspect(reason)}")
        nil
    end
  end

  defp decode_export_logs(data) do
    {:ok, ExportLogsServiceRequest.decode(data)}
  rescue
    error -> {:error, error}
  end

  defp parse_export_logs(%ExportLogsServiceRequest{resource_logs: resource_logs}, metadata) do
    Enum.flat_map(resource_logs, &parse_resource_logs(&1, metadata))
  end

  defp parse_resource_logs(%ResourceLogs{resource: resource, scope_logs: scope_logs}, metadata) do
    resource_attributes = key_values_to_map(resource && resource.attributes)

    service_name =
      resource_attributes["service.name"] || resource_attributes["service_name"]

    service_version =
      resource_attributes["service.version"] || resource_attributes["service_version"]

    service_instance =
      resource_attributes["service.instance.id"] || resource_attributes["service_instance"]

    Enum.flat_map(scope_logs, fn scope_log ->
      parse_scope_logs(
        scope_log,
        service_name,
        service_version,
        service_instance,
        resource_attributes,
        metadata
      )
    end)
  end

  defp parse_resource_logs(_, _metadata), do: []

  defp parse_scope_logs(
         %ScopeLogs{scope: scope, log_records: log_records},
         service_name,
         service_version,
         service_instance,
         resource_attributes,
         metadata
       ) do
    {scope_name, scope_version} = parse_scope(scope)

    Enum.flat_map(log_records, fn log_record ->
      log_attributes = key_values_to_map(log_record.attributes)
      log_attributes = attach_ingest_metadata(log_attributes, metadata)
      log_id = Ash.UUID.generate()

      [
        %{
          id: log_id,
          timestamp: parse_otel_timestamp(log_record),
          trace_id: bytes_to_hex(log_record.trace_id),
          span_id: bytes_to_hex(log_record.span_id),
          severity_text: log_record.severity_text,
          severity_number: FieldParser.safe_bigint(log_record.severity_number),
          body: any_value_to_body(log_record.body),
          service_name: service_name,
          service_version: service_version,
          service_instance: service_instance,
          scope_name: scope_name,
          scope_version: scope_version,
          attributes: log_attributes,
          resource_attributes: resource_attributes,
          created_at: DateTime.utc_now()
        }
      ]
    end)
  end

  defp parse_scope_logs(
         _,
         _service_name,
         _service_version,
         _service_instance,
         _resource_attributes,
         _metadata
       ),
       do: []

  defp parse_scope(%InstrumentationScope{name: name, version: version}), do: {name, version}
  defp parse_scope(_), do: {nil, nil}

  defp parse_otel_timestamp(%LogRecord{time_unix_nano: time, observed_time_unix_nano: observed}) do
    cond do
      is_integer(time) and time > 0 -> FieldParser.parse_timestamp(time)
      is_integer(observed) and observed > 0 -> FieldParser.parse_timestamp(observed)
      true -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(json) do
    FieldParser.parse_timestamp(
      json["timestamp"] ||
        json["time_unix_nano"] ||
        json["timeUnixNano"] ||
        json["observed_time_unix_nano"] ||
        json["observedTimeUnixNano"]
    )
  end

  defp extract_body(json) do
    cond do
      is_binary(json["body"]) -> json["body"]
      is_map(json["body"]) or is_list(json["body"]) -> FieldParser.encode_json(json["body"])
      json["message"] -> json["message"]
      json["msg"] -> json["msg"]
      json["short_message"] -> json["short_message"]
      true -> nil
    end
  end

  defp attach_ingest_metadata(attributes, metadata) when is_map(attributes) do
    ingest = build_ingest_metadata(metadata)

    if map_size(ingest) == 0 do
      attributes
    else
      merge_ingest_metadata(attributes, ingest)
    end
  end

  defp attach_ingest_metadata(attributes, _metadata), do: attributes || %{}

  defp build_ingest_metadata(metadata) do
    %{}
    |> maybe_put_ingest(:subject, metadata[:subject])
    |> maybe_put_ingest(:reply_to, metadata[:reply_to])
    |> maybe_put_ingest(:received_at, iso8601(metadata[:received_at]))
    |> maybe_put_ingest(:source_kind, source_kind(metadata[:subject]))
  end

  defp merge_ingest_metadata(attributes, ingest) do
    Map.update(attributes, "serviceradar.ingest", ingest, &merge_ingest_value(&1, ingest))
  end

  defp merge_ingest_value(existing, ingest) when is_map(existing), do: Map.merge(existing, ingest)
  defp merge_ingest_value(_existing, ingest), do: ingest

  defp maybe_put_ingest(map, _key, nil), do: map
  defp maybe_put_ingest(map, key, value), do: Map.put(map, to_string(key), value)

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(_), do: nil

  defp source_kind(subject) when is_binary(subject) do
    cond do
      String.starts_with?(subject, "logs.syslog") -> "syslog"
      String.starts_with?(subject, "logs.snmp") -> "snmp"
      String.starts_with?(subject, "logs.otel") -> "otel"
      true -> nil
    end
  end

  defp source_kind(_), do: nil

  defp maybe_promote_logs(rows) do
    # DB connection's search_path determines the schema
    _ = LogPromotion.promote(rows)
    :ok
  end

  defp key_values_to_map(values) when is_list(values) do
    Enum.reduce(values, %{}, fn
      %KeyValue{key: key, value: value}, acc when is_binary(key) and key != "" ->
        Map.put(acc, key, any_value_to_term(value))

      _, acc ->
        acc
    end)
  end

  defp key_values_to_map(_), do: %{}

  defp any_value_to_body(%AnyValue{} = value) do
    case any_value_to_term(value) do
      nil ->
        nil

      body when is_binary(body) ->
        body

      body ->
        case Jason.encode(body) do
          {:ok, encoded} -> encoded
          _ -> inspect(body)
        end
    end
  end

  defp any_value_to_body(_), do: nil

  defp any_value_to_term(%AnyValue{value: {:string_value, value}}), do: value
  defp any_value_to_term(%AnyValue{value: {:bool_value, value}}), do: value
  defp any_value_to_term(%AnyValue{value: {:int_value, value}}), do: value
  defp any_value_to_term(%AnyValue{value: {:double_value, value}}), do: value

  defp any_value_to_term(%AnyValue{value: {:bytes_value, value}}) when is_binary(value),
    do: Base.encode64(value)

  defp any_value_to_term(%AnyValue{value: {:array_value, %ArrayValue{values: values}}}) do
    Enum.map(values, &any_value_to_term/1)
  end

  defp any_value_to_term(%AnyValue{value: {:kvlist_value, %KeyValueList{values: values}}}) do
    key_values_to_map(values)
  end

  defp any_value_to_term(_), do: nil

  defp bytes_to_hex(<<>>), do: nil
  defp bytes_to_hex(nil), do: nil
  defp bytes_to_hex(bytes) when is_binary(bytes), do: Base.encode16(bytes, case: :lower)
end
