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

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.TenantContext
  alias ServiceRadar.Observability.LogPromotion
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Common.V1.{AnyValue, ArrayValue, InstrumentationScope, KeyValue, KeyValueList}
  alias Opentelemetry.Proto.Logs.V1.{LogRecord, ResourceLogs, ScopeLogs}

  require Logger

  @impl true
  def table_name, do: "logs"

  @impl true
  def process_batch(messages) do
    schema = TenantContext.current_schema()

    if is_nil(schema) do
      Logger.error("Logs batch missing tenant schema context")
      {:error, :missing_tenant_schema}
    else
      rows =
        messages
        |> Enum.flat_map(&List.wrap(parse_message(&1)))
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(rows) do
        {:ok, 0}
      else
        case ServiceRadar.Repo.insert_all(table_name(), rows,
               prefix: schema,
               on_conflict: :nothing,
               returning: false
             ) do
          {count, _} ->
            maybe_promote_logs(rows, schema)
            {:ok, count}
        end
      end
    end
  rescue
    e ->
      Logger.error("Logs batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata} = message) do
    tenant_id = TenantContext.resolve_tenant_id(message)

    if is_nil(tenant_id) do
      Logger.error("OTEL log missing tenant_id", subject: metadata[:subject])
      nil
    else
      case Jason.decode(data) do
        {:ok, json} ->
          case unwrap_cloudevent(json) do
            {:ok, payload} ->
              parse_json_log(payload, metadata, tenant_id)

            :error ->
              Logger.debug("Unsupported CloudEvent log payload")
              nil
          end

        {:error, _} ->
          parse_protobuf_log(data, metadata, tenant_id)
      end
    end
  end

  # Private functions

  defp parse_json_log(json, metadata, tenant_id) when is_map(json) do
    log_id = Ash.UUID.generate()
    attributes = FieldParser.encode_jsonb(json["attributes"]) || %{}
    attributes = attach_ingest_metadata(attributes, metadata)
    resource_attributes =
      json
      |> FieldParser.get_field("resource_attributes", "resourceAttributes")
      |> FieldParser.encode_jsonb()
      |> case do
        nil -> %{}
        value -> value
      end

    resource_lookup = resource_attributes

    %{
      id: log_id,
      timestamp: parse_timestamp(json),
      trace_id: FieldParser.get_field(json, "trace_id", "traceId"),
      span_id: FieldParser.get_field(json, "span_id", "spanId"),
      severity_text: FieldParser.get_field(json, "severity_text", "severityText") || json["level"],
      severity_number: FieldParser.safe_bigint(FieldParser.get_field(json, "severity_number", "severityNumber")),
      body: extract_body(json),
      service_name:
        FieldParser.get_field(json, "service_name", "serviceName") ||
          resource_lookup["service.name"],
      service_version:
        FieldParser.get_field(json, "service_version", "serviceVersion") ||
          resource_lookup["service.version"],
      service_instance:
        FieldParser.get_field(json, "service_instance", "serviceInstance") ||
          resource_lookup["service.instance.id"],
      scope_name: FieldParser.get_field(json, "scope_name", "scopeName"),
      scope_version: FieldParser.get_field(json, "scope_version", "scopeVersion"),
      attributes: attributes,
      resource_attributes: resource_attributes,
      tenant_id: tenant_id,
      created_at: DateTime.utc_now()
    }
  end

  defp parse_json_log(_json, _metadata, _tenant_id), do: nil

  defp parse_protobuf_log(data, metadata, tenant_id) do
    case decode_export_logs(data) do
      {:ok, %ExportLogsServiceRequest{} = request} ->
        parse_export_logs(request, metadata, tenant_id)

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

  defp parse_export_logs(%ExportLogsServiceRequest{resource_logs: resource_logs}, metadata, tenant_id) do
    Enum.flat_map(resource_logs, &parse_resource_logs(&1, metadata, tenant_id))
  end

  defp parse_resource_logs(%ResourceLogs{resource: resource, scope_logs: scope_logs}, metadata, tenant_id) do
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
        metadata,
        tenant_id
      )
    end)
  end

  defp parse_resource_logs(_, _metadata, _tenant_id), do: []

  defp parse_scope_logs(
         %ScopeLogs{scope: scope, log_records: log_records},
         service_name,
         service_version,
         service_instance,
         resource_attributes,
         metadata,
         tenant_id
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
          tenant_id: tenant_id,
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
         _metadata,
         _tenant_id
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
    ingest =
      %{}
      |> maybe_put_ingest(:subject, metadata[:subject])
      |> maybe_put_ingest(:reply_to, metadata[:reply_to])
      |> maybe_put_ingest(:received_at, iso8601(metadata[:received_at]))
      |> maybe_put_ingest(:source_kind, source_kind(metadata[:subject]))

    if map_size(ingest) == 0 do
      attributes
    else
      Map.update(attributes, "serviceradar.ingest", ingest, fn existing ->
        if is_map(existing) do
          Map.merge(existing, ingest)
        else
          ingest
        end
      end)
    end
  end

  defp attach_ingest_metadata(attributes, _metadata), do: attributes || %{}

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

  defp maybe_promote_logs(rows, schema) do
    tenant_id =
      case rows do
        [%{tenant_id: tenant_id} | _] -> tenant_id
        _ -> TenantContext.current_tenant_id()
      end

    _ = LogPromotion.promote(rows, tenant_id, schema)
    :ok
  end

  defp unwrap_cloudevent(%{"specversion" => _} = json) do
    cond do
      Map.has_key?(json, "data") ->
        decode_cloudevent_data(json["data"])

      Map.has_key?(json, "data_base64") ->
        decode_cloudevent_base64(json["data_base64"])

      true ->
        :error
    end
  end

  defp unwrap_cloudevent(json) when is_map(json), do: {:ok, json}
  defp unwrap_cloudevent(_), do: :error

  defp decode_cloudevent_data(%{} = data), do: {:ok, data}
  defp decode_cloudevent_data(data) when is_binary(data), do: Jason.decode(data)
  defp decode_cloudevent_data(_), do: :error

  defp decode_cloudevent_base64(data) when is_binary(data) do
    with {:ok, decoded} <- Base.decode64(data),
         {:ok, payload} <- Jason.decode(decoded) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp decode_cloudevent_base64(_), do: :error

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
      nil -> nil
      body when is_binary(body) -> body
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
