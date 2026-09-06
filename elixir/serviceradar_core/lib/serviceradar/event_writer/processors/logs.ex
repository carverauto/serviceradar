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
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.ArrayValue
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Common.V1.KeyValueList
  alias Opentelemetry.Proto.Logs.V1.LogRecord
  alias Opentelemetry.Proto.Logs.V1.ResourceLogs
  alias Opentelemetry.Proto.Logs.V1.ScopeLogs
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.IngestAttribution
  alias ServiceRadar.EventWriter.OtelId
  alias ServiceRadar.EventWriter.SignalTelemetry
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.Observability.LogPromotionParser
  alias ServiceRadar.Observability.LogPubSub
  alias ServiceRadar.Observability.Zen.Normalizer, as: ZenNormalizer

  require Logger

  @redacted "[REDACTED]"
  @sensitive_log_keys ~w(
    authorization api_key apikey bearer cookie credential credentials jwt password
    private_key secret secret_key seed signing_key token nkey_seed nkey
  )
  @common_insert_placeholders %{
    trace_id: :logs_trace_id,
    span_id: :logs_span_id,
    severity_text: :logs_severity_text,
    body: :logs_body,
    event_name: :logs_event_name,
    source: :logs_source,
    source_ip: :logs_source_ip,
    service_name: :logs_service_name,
    service_version: :logs_service_version,
    service_instance: :logs_service_instance,
    scope_name: :logs_scope_name,
    scope_version: :logs_scope_version,
    attributes: :logs_attributes,
    resource_attributes: :logs_resource_attributes,
    scope_attributes: :logs_scope_attributes,
    ingest_identity: :logs_ingest_identity,
    ingest_agent_id: :logs_ingest_agent_id,
    ingest_partition: :logs_ingest_partition
  }

  @impl true
  def table_name, do: "logs"

  @impl true
  def process_batch(messages), do: process_batch(messages, [])

  def process_batch(messages, opts) do
    SignalTelemetry.emit(:logs, :received, length(messages))

    # DB connection's search_path determines the schema
    {rows, rejected} = build_rows(messages)
    SignalTelemetry.emit(:logs, :rejected, rejected)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_log_rows(rows, opts)
    end
  rescue
    e ->
      Logger.error("Logs batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    attribution = IngestAttribution.from_metadata(metadata)

    case_result =
      case Jason.decode(data) do
        {:ok, _} = decoded -> parse_log_payload(decoded, data, metadata)
        {:error, _} = error -> parse_log_payload(error, data, metadata)
      end

    case_result
    |> IngestAttribution.attach(attribution)
    |> redact_log_row()
  end

  @doc false
  def prepare_rows_for_insert(rows) when is_list(rows) do
    rows
    |> Enum.map(&encode_text_columns/1)
    |> replace_repeated_values_with_placeholders()
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

  defp insert_log_rows(rows, opts) do
    {rows_for_insert, placeholders} = prepare_rows_for_insert(rows)
    insert_opts = insert_options(placeholders)

    # DB connection's search_path determines the schema
    {count, _} =
      BulkInsert.insert_all(
        table_name(),
        rows_for_insert,
        insert_opts
      )

    with {:ok, _promoted} <- maybe_promote_logs(rows, opts) do
      SignalTelemetry.emit(:logs, :written, count)
      LogPubSub.broadcast_ingest(%{count: count})
      {:ok, count}
    end
  end

  defp parse_log_payload({:ok, json}, _data, metadata) do
    json
    |> normalize_json_log(metadata)
    |> parse_json_log(metadata)
  end

  defp parse_log_payload({:error, _}, data, metadata) do
    parse_protobuf_log(data, metadata)
  end

  defp normalize_json_log(json, metadata) when is_map(json) do
    case ZenNormalizer.normalize_json(metadata[:subject], json) do
      {:ok, normalized} when is_map(normalized) -> normalized
      _ -> json
    end
  end

  defp normalize_json_log(json, _metadata), do: json

  defp parse_json_log(json, metadata) when is_map(json) do
    log_id = generated_uuid()

    attributes =
      json
      |> log_attributes()
      |> attach_syslog_metadata(json)
      |> prune_empty_metadata()

    attributes = attach_ingest_metadata(attributes, metadata)
    resource_attributes = normalize_resource_attributes(json)
    {scope_name, scope_version} = parse_scope_fields(json)
    source = FieldParser.get_field(json, "source", "source") || source_kind(metadata[:subject])
    scope_attributes = parse_scope_attributes(json)
    {severity_text, severity_number} = log_severity(json)
    source_ip = normalize_source_ip(json)

    observed_timestamp = parse_observed_timestamp(json) || metadata[:received_at]

    %{
      id: log_id,
      timestamp: parse_timestamp(json),
      observed_timestamp: observed_timestamp,
      trace_id: OtelId.normalize_trace_id(FieldParser.get_field(json, "trace_id", "traceId")),
      span_id: OtelId.normalize_span_id(FieldParser.get_field(json, "span_id", "spanId")),
      trace_flags: parse_trace_flags(json),
      severity_text: severity_text,
      severity_number: severity_number,
      body: extract_body(json),
      event_name: FieldParser.get_field(json, "event_name", "eventName"),
      source: source,
      source_ip: source_ip,
      service_name:
        service_field(json, resource_attributes, "service_name", "serviceName", "service.name") ||
          default_service_name(json, resource_attributes),
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
      scope_attributes: scope_attributes,
      attributes: attributes,
      resource_attributes: resource_attributes,
      created_at: DateTime.utc_now()
    }
  end

  defp parse_json_log(_json, _metadata), do: nil

  defp log_attributes(json) when is_map(json) do
    json["attributes"]
    |> FieldParser.encode_jsonb()
    |> prune_empty_metadata()
    |> case do
      attributes when is_map(attributes) -> attributes
      _ -> %{}
    end
  end

  defp attach_syslog_metadata(attributes, json) when is_map(attributes) and is_map(json) do
    Enum.reduce(["_remote_addr", "_syslog_format", "_syslog_parse_fallback"], attributes, fn key,
                                                                                             acc ->
      case Map.get(json, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_source_ip(json) when is_map(json) do
    json
    |> source_ip_values()
    |> Enum.find_value(fn value ->
      value
      |> source_ip_candidates()
      |> Enum.find_value(&valid_source_ip/1)
    end)
  end

  defp normalize_source_ip(_json), do: nil

  defp source_ip_values(json) do
    Enum.reject(
      [
        FieldParser.get_field(json, "source_ip", "sourceIp"),
        json["_remote_addr"],
        # trapd publishes the sender as `source` ("ip:port"); the Zen rule
        # overwrites `source` with 'snmp', so this only fires for traps that
        # never went through logs.snmp normalization.
        json["source"]
      ],
      &is_nil/1
    )
  end

  defp source_ip_candidates(value) when is_binary(value) do
    value = String.trim(value)
    bracketless = bracketless_ip(value)

    [value, bracketless]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn candidate ->
      case String.split(candidate, ":", parts: 2) do
        [prefix, address] -> [candidate, prefix, address, bracketless_ip(address)]
        _ -> [candidate]
      end
    end)
    |> Enum.uniq()
  end

  defp source_ip_candidates(_value), do: []

  defp bracketless_ip(value) when is_binary(value) do
    case Regex.run(~r/^\[([^\]]+)\](?::\d+)?$/, value, capture: :all_but_first) do
      [ip] -> ip
      _ -> value
    end
  end

  defp bracketless_ip(_value), do: nil

  defp valid_source_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _address} -> value
      _ -> nil
    end
  end

  defp valid_source_ip(_value), do: nil

  # Resolves {severity_text, severity_number}. When an explicit severity_text /
  # severity is present it wins. Otherwise a numeric GELF/syslog `level` is mapped
  # through the shared LogPromotionParser.severity_from_level/1 helper so we always
  # populate BOTH columns (by_severity filtering + severity_color need
  # severity_number) and never store a bare 0-7 int as severity_text. This is the
  # Elixir-side complement to the bundled `syslog_severity` Zen rule.
  defp log_severity(json) do
    text = FieldParser.get_field(json, "severity_text", "severityText") || json["severity"]

    number =
      json
      |> FieldParser.get_field("severity_number", "severityNumber")
      |> FieldParser.safe_bigint()

    cond do
      is_binary(text) and text != "" ->
        {text, number}

      not is_nil(json["level"]) ->
        {level_text, level_number} = LogPromotionParser.severity_from_level(json["level"])
        {level_text, number || level_number}

      true ->
        {text, number}
    end
  end

  defp parse_scope_fields(json) when is_map(json) do
    scope_name = FieldParser.get_field(json, "scope_name", "scopeName")
    scope_version = FieldParser.get_field(json, "scope_version", "scopeVersion")

    merge_scope_fields(json["scope"], scope_name, scope_version)
  end

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

  defp parse_observed_timestamp(json) when is_map(json) do
    case json["observed_timestamp"] ||
           json["observedTimestamp"] ||
           json["observed_time_unix_nano"] ||
           json["observedTimeUnixNano"] do
      nil -> nil
      value -> FieldParser.parse_timestamp(value)
    end
  end

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

  defp default_service_name(json, resource_attributes) when is_map(json) do
    FieldParser.get_field(json, "application_name", "applicationName") ||
      FieldParser.get_field(json, "app_name", "appName") ||
      FieldParser.get_field(json, "host", "hostname") ||
      resource_attributes["host.name"] ||
      resource_attributes["host_name"]
  end

  defp default_service_name(_json, _resource_attributes), do: nil

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
      log_id = generated_uuid()
      source = source_kind(metadata[:subject])

      [
        %{
          id: log_id,
          timestamp: parse_otel_timestamp(log_record),
          trace_id: OtelId.normalize_trace_id(log_record.trace_id),
          span_id: OtelId.normalize_span_id(log_record.span_id),
          severity_text: log_record.severity_text,
          severity_number: FieldParser.safe_bigint(log_record.severity_number),
          body: any_value_to_body(log_record.body),
          source: source,
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
       ), do: []

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
      is_binary(json["message"]) -> json["message"]
      is_binary(json["msg"]) -> json["msg"]
      is_binary(json["short_message"]) -> json["short_message"]
      # SNMP trap text is assembled by the snmp_severity Zen rule, which knows
      # which varbind carries the message. The old fallback here took
      # varbinds[0], which on a well-formed trap is sysUpTime -- a bare
      # TimeTicks count presented to operators as the log body.
      true -> nil
    end
  end

  defp attach_ingest_metadata(attributes, metadata) when is_map(attributes) do
    ingest = build_ingest_metadata(metadata)

    if map_size(ingest) == 0 do
      prune_empty_metadata(attributes)
    else
      attributes
      |> merge_ingest_metadata(ingest)
      |> prune_empty_metadata()
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
    subject
    |> String.trim()
    |> String.split(".", parts: 3)
    |> case do
      ["logs", source | _] when source != "" -> source
      _ -> nil
    end
  end

  defp source_kind(_), do: nil

  defp redact_log_row(nil), do: nil

  defp redact_log_row(rows) when is_list(rows), do: Enum.map(rows, &redact_log_row/1)

  defp redact_log_row(row) when is_map(row) do
    row
    |> redact_text_field(:body)
    |> redact_metadata_field(:attributes)
    |> redact_metadata_field(:resource_attributes)
    |> redact_metadata_field(:scope_attributes)
  end

  defp redact_text_field(row, key) do
    case Map.get(row, key) do
      value when is_binary(value) -> Map.put(row, key, redact_secret_text(value))
      _ -> row
    end
  end

  defp redact_metadata_field(row, key) do
    case Map.get(row, key) do
      value when is_map(value) or is_list(value) -> Map.put(row, key, redact_secret_value(value))
      value when is_binary(value) -> Map.put(row, key, redact_secret_text(value))
      _ -> row
    end
  end

  defp redact_secret_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_log_key?(key) do
        {key, @redacted}
      else
        {key, redact_secret_value(nested)}
      end
    end)
  end

  defp redact_secret_value(value) when is_list(value), do: Enum.map(value, &redact_secret_value/1)
  defp redact_secret_value(value) when is_binary(value), do: redact_secret_text(value)
  defp redact_secret_value(value), do: value

  defp redact_secret_text(value) when is_binary(value) do
    value
    |> redact_erlang_secret("nkey_seed")
    |> redact_erlang_secret("jwt")
    |> redact_json_secret("nkey_seed")
    |> redact_json_secret("jwt")
    |> redact_json_secret("token")
    |> redact_json_secret("password")
    |> redact_json_secret("secret")
    |> redact_json_secret("api_key")
    |> redact_assignment_secret("authorization")
    |> redact_assignment_secret("token")
    |> redact_assignment_secret("password")
    |> redact_assignment_secret("secret")
    |> redact_assignment_secret("api_key")
  end

  defp redact_erlang_secret(value, key) do
    Regex.replace(~r/(#{Regex.escape(key)}\s*=>\s*<<")[^"]*(">>)/i, value, "\\1#{@redacted}\\2")
  end

  defp redact_json_secret(value, key) do
    Regex.replace(~r/("#{Regex.escape(key)}"\s*:\s*")[^"]*(")/i, value, "\\1#{@redacted}\\2")
  end

  defp redact_assignment_secret(value, key) do
    Regex.replace(~r/(#{Regex.escape(key)}\s*[=:]\s*)[^\s,}\]]+/i, value, "\\1#{@redacted}")
  end

  defp sensitive_log_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> then(fn normalized ->
      normalized in @sensitive_log_keys or
        Enum.any?(@sensitive_log_keys, fn key -> String.ends_with?(normalized, "_#{key}") end)
    end)
  end

  defp generated_uuid do
    Ecto.UUID.dump!(Ecto.UUID.generate())
  end

  defp encode_text_columns(row) when is_map(row) do
    row
    |> maybe_stringify_text(:trace_id)
    |> maybe_stringify_text(:span_id)
    |> maybe_stringify_text(:severity_text)
    |> maybe_stringify_text(:body)
    |> maybe_stringify_text(:event_name)
    |> maybe_stringify_text(:source)
    |> maybe_stringify_text(:source_ip)
    |> maybe_stringify_text(:service_name)
    |> maybe_stringify_text(:service_version)
    |> maybe_stringify_text(:service_instance)
    |> maybe_stringify_text(:scope_name)
    |> maybe_stringify_text(:scope_version)
    |> maybe_encode_text(:attributes)
    |> maybe_encode_text(:resource_attributes)
    |> maybe_encode_text(:scope_attributes)
  end

  defp maybe_encode_text(row, key) do
    case Map.get(row, key) do
      value when is_map(value) or is_list(value) ->
        Map.put(row, key, FieldParser.encode_json(value))

      _ ->
        row
    end
  end

  defp maybe_stringify_text(row, key) do
    case Map.get(row, key) do
      nil -> row
      value when is_binary(value) -> row
      value -> Map.put(row, key, to_string(value))
    end
  end

  defp replace_repeated_values_with_placeholders(rows) do
    {prepared_rows, placeholders} =
      Enum.reduce(@common_insert_placeholders, {rows, %{}}, fn {column, placeholder},
                                                               {current_rows,
                                                                current_placeholders} ->
        case repeated_value(current_rows, column) do
          {:ok, value} ->
            rows_with_placeholder =
              Enum.map(current_rows, fn row ->
                if Map.get(row, column) == value do
                  Map.put(row, column, {:placeholder, placeholder})
                else
                  row
                end
              end)

            {rows_with_placeholder, Map.put(current_placeholders, placeholder, value)}

          :skip ->
            {current_rows, current_placeholders}
        end
      end)

    {prepared_rows, placeholders}
  end

  defp repeated_value(rows, column) do
    values =
      Enum.flat_map(rows, fn row ->
        case Map.fetch(row, column) do
          {:ok, nil} -> []
          {:ok, {:placeholder, _}} -> []
          {:ok, value} -> [value]
          :error -> []
        end
      end)

    case Enum.uniq(values) do
      [value] when length(values) > 1 -> {:ok, value}
      _ -> :skip
    end
  end

  defp insert_options(placeholders) when map_size(placeholders) == 0 do
    [on_conflict: :nothing, returning: false]
  end

  defp insert_options(placeholders) do
    [on_conflict: :nothing, returning: false, placeholders: placeholders]
  end

  defp maybe_promote_logs(rows, opts) do
    # DB connection's search_path determines the schema
    promotion_rows = Enum.map(rows, &canonicalize_generated_log_id/1)
    LogPromotion.promote(promotion_rows, opts)
  end

  # Log rows use raw UUID bytes for PostgreSQL inserts. Promotion metadata is
  # JSON, so cross the representation boundary here while the UUID contract is
  # explicit instead of asking LogPromotion to infer UUIDs from byte length.
  defp canonicalize_generated_log_id(%{id: id} = row) when is_binary(id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> Map.put(row, :id, uuid)
      :error -> row
    end
  end

  defp canonicalize_generated_log_id(row), do: row

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

  defp prune_empty_metadata(%{} = map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = prune_empty_metadata(value)

      if empty_metadata_value?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp prune_empty_metadata(list) when is_list(list) do
    list
    |> Enum.map(&prune_empty_metadata/1)
    |> Enum.reject(&empty_metadata_value?/1)
  end

  defp prune_empty_metadata(value), do: value

  defp empty_metadata_value?(nil), do: true
  defp empty_metadata_value?(%{} = map), do: map_size(map) == 0
  defp empty_metadata_value?([]), do: true
  defp empty_metadata_value?(_value), do: false
end
