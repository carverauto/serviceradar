defmodule ServiceRadar.Observability.LogPromotionParser do
  @moduledoc """
  Parses processed log payloads into normalized log maps for promotion.
  """

  alias ServiceRadar.EventWriter.FieldParser

  @reserved_keys MapSet.new([
                   "@timestamp",
                   "_remote_addr",
                   "body",
                   "attributes",
                   "event_name",
                   "eventName",
                   "event",
                   "host",
                   "hostname",
                   "ip",
                   "ip_address",
                   "level",
                   "log",
                   "message",
                   "msg",
                   "observed_time_unix_nano",
                   "observedTimeUnixNano",
                   "observed_timestamp",
                   "observedTimestamp",
                   "remote_addr",
                   "resource",
                   "resource_attributes",
                   "resourceAttributes",
                   "scope",
                   "scope_attributes",
                   "scopeAttributes",
                   "scope.name",
                   "scope.version",
                   "scopeName",
                   "scopeVersion",
                   "scope_name",
                   "scope_version",
                   "service.instance",
                   "service.instance.id",
                   "service.name",
                   "service.version",
                   "service_instance",
                   "service_instance_id",
                   "service_name",
                   "service_version",
                   "severity",
                   "severity_number",
                   "severity_text",
                   "short_message",
                   "source",
                   "span_id",
                   "spanId",
                   "summary",
                   "time",
                   "timestamp",
                   "trace_flags",
                   "traceFlags",
                   "trace_id",
                   "traceId",
                   "ts"
                 ])

  @spec parse_payload(binary(), String.t(), DateTime.t()) :: [map()]
  def parse_payload(payload, subject, received_at \\ DateTime.utc_now())
      when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> normalize_decoded(decoded, subject, received_at)
      _ -> []
    end
  end

  defp normalize_decoded(entries, subject, received_at) when is_list(entries) do
    entries
    |> Enum.flat_map(&normalize_entry(&1, subject, received_at))
  end

  defp normalize_decoded(entry, subject, received_at) when is_map(entry) do
    normalize_entry(entry, subject, received_at)
  end

  defp normalize_decoded(_, _subject, _received_at), do: []

  defp normalize_entry(entry, subject, received_at) when is_map(entry) do
    timestamp = parse_timestamp(entry) || received_at
    {severity_text, severity_number} = normalize_severity(entry)

    body =
      first_string(entry, ["message", "short_message", "msg", "body", "event", "log", "summary"]) ||
        subject

    service_name = service_name(entry)
    attributes = build_attributes(entry, subject)
    resource_attributes = build_resource_attributes(entry)

    log = %{
      id: Ash.UUID.generate(),
      timestamp: timestamp,
      severity_text: severity_text,
      severity_number: severity_number,
      body: body,
      service_name: service_name,
      trace_id: first_string(entry, ["trace_id", "traceId"]),
      span_id: first_string(entry, ["span_id", "spanId"]),
      attributes: attributes,
      resource_attributes: resource_attributes,
      created_at: DateTime.utc_now()
    }

    [log]
  end

  defp normalize_entry(_, _subject, _received_at), do: []

  defp parse_timestamp(entry) when is_map(entry) do
    entry
    |> first_value(["timestamp", "time", "ts", "@timestamp"])
    |> parse_timestamp_value()
  end

  defp parse_timestamp_value(nil), do: nil

  defp parse_timestamp_value(value) when is_integer(value) do
    FieldParser.parse_timestamp(value)
  end

  defp parse_timestamp_value(value) when is_float(value) do
    FieldParser.parse_timestamp(round(value))
  end

  defp parse_timestamp_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {num, _} -> parse_timestamp_value(num)
      :error -> FieldParser.parse_timestamp(value)
    end
  end

  defp parse_timestamp_value(_), do: nil

  defp normalize_severity(entry) do
    cond do
      value = first_string(entry, ["severity_text", "severityText"]) ->
        normalize_severity_text(value)

      value = first_string(entry, ["severity"]) ->
        normalize_severity_text(value)

      Map.has_key?(entry, "level") ->
        severity_from_level(entry["level"])

      Map.has_key?(entry, "severity_number") ->
        severity_from_number(entry["severity_number"])

      true ->
        {"INFO", severity_number_for_text("INFO")}
    end
  end

  defp normalize_severity_text(text) when is_binary(text) do
    case String.downcase(String.trim(text)) do
      "fatal" -> {"FATAL", severity_number_for_text("FATAL")}
      "critical" -> {"FATAL", severity_number_for_text("FATAL")}
      "emergency" -> {"FATAL", severity_number_for_text("FATAL")}
      "alert" -> {"FATAL", severity_number_for_text("FATAL")}
      "very high" -> {"FATAL", severity_number_for_text("FATAL")}
      "very_high" -> {"FATAL", severity_number_for_text("FATAL")}
      "high" -> {"ERROR", severity_number_for_text("ERROR")}
      "error" -> {"ERROR", severity_number_for_text("ERROR")}
      "medium" -> {"WARN", severity_number_for_text("WARN")}
      "warn" -> {"WARN", severity_number_for_text("WARN")}
      "warning" -> {"WARN", severity_number_for_text("WARN")}
      "low" -> {"INFO", severity_number_for_text("INFO")}
      "info" -> {"INFO", severity_number_for_text("INFO")}
      "informational" -> {"INFO", severity_number_for_text("INFO")}
      "notice" -> {"INFO", severity_number_for_text("INFO")}
      "unknown" -> {"INFO", severity_number_for_text("INFO")}
      "debug" -> {"DEBUG", severity_number_for_text("DEBUG")}
      "trace" -> {"DEBUG", severity_number_for_text("DEBUG")}
      _ -> {"INFO", severity_number_for_text("INFO")}
    end
  end

  defp normalize_severity_text(_), do: {"INFO", severity_number_for_text("INFO")}

  defp severity_from_level(level) do
    case parse_numeric(level) do
      {:ok, value} ->
        case value do
          v when v in [0, 1, 2] -> {"FATAL", severity_number_for_text("FATAL")}
          3 -> {"ERROR", severity_number_for_text("ERROR")}
          4 -> {"WARN", severity_number_for_text("WARN")}
          v when v in [5, 6] -> {"INFO", severity_number_for_text("INFO")}
          7 -> {"DEBUG", severity_number_for_text("DEBUG")}
          _ -> {"INFO", severity_number_for_text("INFO")}
        end

      :error ->
        normalize_severity_text(to_string(level))
    end
  end

  defp severity_from_number(value) do
    case parse_numeric(value) do
      {:ok, number} ->
        text = severity_text_from_number(number)
        {text, number}

      :error ->
        {"INFO", severity_number_for_text("INFO")}
    end
  end

  defp severity_text_from_number(number) when is_integer(number) do
    cond do
      number >= 21 -> "FATAL"
      number >= 17 -> "ERROR"
      number >= 13 -> "WARN"
      number >= 9 -> "INFO"
      number >= 5 -> "DEBUG"
      true -> "INFO"
    end
  end

  defp severity_text_from_number(_), do: "INFO"

  defp severity_number_for_text(text) do
    case String.upcase(String.trim(text)) do
      "FATAL" -> 23
      "ERROR" -> 19
      "WARN" -> 15
      "WARNING" -> 15
      "DEBUG" -> 7
      "TRACE" -> 3
      _ -> 11
    end
  end

  defp service_name(entry) do
    service = first_string(entry, ["service.name", "service_name", "service", "serviceName"])
    host = first_string(entry, ["host", "hostname"])
    resource = build_resource_attributes(entry)

    cond do
      service && service != "" -> service
      host && host != "" -> host
      true -> first_string(resource, ["service.name", "service_name", "serviceName"]) || host
    end
  end

  defp build_attributes(entry, subject) do
    base_attributes =
      entry
      |> first_value(["attributes"])
      |> FieldParser.encode_jsonb()
      |> ensure_map()

    extra_attributes = build_extra_attributes(entry)

    base_attributes
    |> Map.merge(extra_attributes)
    |> put_ingest_subject(subject)
  end

  defp build_extra_attributes(entry) do
    Enum.reduce(entry, %{}, fn {key, value}, acc ->
      if skip_attribute?(key, value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp skip_attribute?(key, value) do
    MapSet.member?(@reserved_keys, key) or is_nil(value) or value == ""
  end

  defp put_ingest_subject(attributes, subject) when is_binary(subject) do
    serviceradar = ensure_map(Map.get(attributes, "serviceradar"))
    ingest = ensure_map(Map.get(serviceradar, "ingest"))
    ingest = Map.put(ingest, "subject", subject)
    serviceradar = Map.put(serviceradar, "ingest", ingest)
    Map.put(attributes, "serviceradar", serviceradar)
  end

  defp put_ingest_subject(attributes, _), do: attributes

  defp build_resource_attributes(entry) do
    resource =
      entry
      |> first_value(["resource_attributes", "resourceAttributes", "resource"])
      |> FieldParser.encode_jsonb()
      |> ensure_map()

    if map_size(resource) > 0 do
      resource
    else
      build_resource_fallback(entry)
    end
  end

  defp build_resource_fallback(entry) do
    ["host", "hostname", "remote_addr", "source", "ip", "ip_address"]
    |> Enum.reduce(%{}, fn key, acc ->
      value = first_string(entry, [key])
      if value && value != "", do: Map.put(acc, key, value), else: acc
    end)
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp first_value(entry, keys) when is_map(entry) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(entry, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp first_value(_, _), do: nil

  defp first_string(entry, keys) when is_map(entry) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(entry, key) do
        {:ok, value} when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed != "", do: trimmed, else: nil

        {:ok, value} when is_number(value) ->
          to_string(value)

        _ ->
          nil
      end
    end)
  end

  defp first_string(_, _), do: nil

  defp parse_numeric(value) when is_integer(value), do: {:ok, value}
  defp parse_numeric(value) when is_float(value), do: {:ok, round(value)}

  defp parse_numeric(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> {:ok, int}
      :error -> :error
    end
  end

  defp parse_numeric(_), do: :error
end
