defmodule ServiceRadar.EventWriter.Processors.Events do
  @moduledoc """
  Processor for syslog/SNMP trap events in OCSF Event Log Activity format.

  Parses JSON events from NATS (including CloudEvents-wrapped payloads) and
  inserts them into the `ocsf_events` hypertable using OCSF v1.7.0
  Event Log Activity schema (class_uid: 1008).
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.TenantContext

  require Logger

  @impl true
  def table_name, do: "ocsf_events"

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
      Logger.error("OCSF events batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata} = message) do
    tenant_id = TenantContext.resolve_tenant_id(message)

    if is_nil(tenant_id) do
      Logger.error("OCSF event missing tenant_id", subject: metadata[:subject])
      nil
    else
      case Jason.decode(data) do
        {:ok, json} ->
          parse_event(json, metadata, data, tenant_id)

        {:error, _} ->
          Logger.debug("Failed to parse events message as JSON")
          nil
      end
    end
  end

  # Private functions

  defp parse_event(json, metadata, raw_data, tenant_id) when is_map(json) do
    {payload, event_meta} = unwrap_cloudevent(json)

    {message, severity_id, log_level, log_version} = classify_payload(payload)
    event_meta_subject = Map.get(event_meta, :subject)
    event_meta_source = Map.get(event_meta, :source)
    event_meta_time = Map.get(event_meta, :time)
    event_time = event_timestamp(payload, event_meta)
    activity_id = OCSF.activity_log_create()

    source_ip = payload["_remote_addr"] || payload["remote_addr"] || payload["source"]
    host = payload["host"] || payload["hostname"]

    src_endpoint = OCSF.build_endpoint(ip: parse_ip(source_ip), hostname: host)
    device = OCSF.build_device(hostname: host, ip: parse_ip(source_ip))

    %{
      id: UUID.uuid4(),
      time: event_time,
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      severity_id: severity_id,
      message: message,
      severity: OCSF.severity_name(severity_id),
      activity_name: OCSF.log_activity_name(activity_id),
      status_id: 1,
      status: "Success",
      status_code: nil,
      status_detail: nil,
      metadata:
        OCSF.build_metadata(
          version: "1.7.0",
          correlation_uid: metadata[:subject] || event_meta_subject,
          original_time: event_meta_time
        ),
      observables: build_observables(source_ip, host),
      trace_id: payload["trace_id"] || payload["traceId"],
      span_id: payload["span_id"] || payload["spanId"],
      actor: OCSF.build_actor(app_name: event_meta_source || "syslog"),
      device: device,
      src_endpoint: src_endpoint,
      log_name: event_meta_subject || metadata[:subject] || "events",
      log_provider: host || payload["source"] || "unknown",
      log_level: log_level,
      log_version: log_version,
      unmapped: payload || %{},
      raw_data: raw_data,
      tenant_id: tenant_id,
      created_at: DateTime.utc_now()
    }
  end

  defp parse_event(_json, _metadata, _raw_data, _tenant_id), do: nil

  defp unwrap_cloudevent(%{"specversion" => _} = json) do
    meta = %{
      subject: json["subject"],
      source: json["source"],
      type: json["type"],
      time: json["time"]
    }

    {decode_cloudevent_data(json), meta}
  end

  defp unwrap_cloudevent(json), do: {json, %{}}

  defp decode_cloudevent_data(%{"data" => data}) when is_map(data), do: data

  defp decode_cloudevent_data(%{"data" => data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> decoded
      _ -> %{"message" => data}
    end
  end

  defp decode_cloudevent_data(%{"data_base64" => data}) when is_binary(data) do
    with {:ok, decoded} <- Base.decode64(data),
         {:ok, payload} <- Jason.decode(decoded) do
      payload
    else
      _ -> %{}
    end
  end

  defp decode_cloudevent_data(_), do: %{}

  defp classify_payload(%{"varbinds" => _} = payload) do
    message = payload["message"] || "SNMP trap received"
    {message, OCSF.severity_informational(), payload["severity"], payload["version"]}
  end

  defp classify_payload(payload) when is_map(payload) do
    message =
      payload["short_message"] || payload["message"] || payload["msg"] ||
        payload["body"] || payload["event"] || "Event received"

    severity_id =
      payload
      |> Map.get("level")
      |> parse_level(payload["severity"])

    log_level = payload["severity"] || payload["level"]
    log_version = payload["version"]

    {message, severity_id, log_level, log_version}
  end

  defp classify_payload(_), do: {"Event received", OCSF.severity_unknown(), nil, nil}

  defp parse_level(nil, severity_text), do: severity_from_text(severity_text)
  defp parse_level(level, _severity_text) when is_integer(level), do: severity_from_level(level)
  defp parse_level(level, severity_text) when is_binary(level) do
    case Integer.parse(level) do
      {int, _} -> severity_from_level(int)
      :error -> severity_from_text(severity_text)
    end
  end

  defp parse_level(_, severity_text), do: severity_from_text(severity_text)

  defp severity_from_level(level) do
    case level do
      0 -> OCSF.severity_fatal()
      1 -> OCSF.severity_critical()
      2 -> OCSF.severity_critical()
      3 -> OCSF.severity_high()
      4 -> OCSF.severity_medium()
      5 -> OCSF.severity_low()
      6 -> OCSF.severity_informational()
      7 -> OCSF.severity_informational()
      _ -> OCSF.severity_unknown()
    end
  end

  defp severity_from_text(nil), do: OCSF.severity_unknown()

  defp severity_from_text(text) when is_binary(text) do
    case String.downcase(text) do
      "fatal" -> OCSF.severity_fatal()
      "critical" -> OCSF.severity_critical()
      "error" -> OCSF.severity_high()
      "warn" -> OCSF.severity_medium()
      "warning" -> OCSF.severity_medium()
      "notice" -> OCSF.severity_low()
      "info" -> OCSF.severity_informational()
      "informational" -> OCSF.severity_informational()
      "debug" -> OCSF.severity_informational()
      _ -> OCSF.severity_unknown()
    end
  end

  defp severity_from_text(_), do: OCSF.severity_unknown()

  defp event_timestamp(payload, meta) do
    meta_time = Map.get(meta, :time)

    cond do
      is_binary(meta_time) -> FieldParser.parse_timestamp(meta_time)
      is_number(payload["timestamp"]) -> parse_gelf_timestamp(payload["timestamp"])
      payload["time"] -> FieldParser.parse_timestamp(payload["time"])
      true -> DateTime.utc_now()
    end
  end

  defp parse_gelf_timestamp(timestamp) when is_float(timestamp) do
    seconds = trunc(timestamp)
    nanos = trunc((timestamp - seconds) * 1_000_000_000)
    DateTime.from_unix!(seconds * 1_000_000_000 + nanos, :nanosecond)
  end

  defp parse_gelf_timestamp(timestamp) when is_integer(timestamp) do
    FieldParser.parse_timestamp(timestamp)
  end

  defp parse_gelf_timestamp(_), do: DateTime.utc_now()

  defp build_observables(nil, nil), do: []

  defp build_observables(source_ip, host) do
    []
    |> maybe_add_observable(host, "Hostname", 1)
    |> maybe_add_observable(source_ip, "IP Address", 2)
  end

  defp maybe_add_observable(observables, nil, _type, _type_id), do: observables
  defp maybe_add_observable(observables, "", _type, _type_id), do: observables

  defp maybe_add_observable(observables, value, type, type_id) do
    [%{name: value, type: type, type_id: type_id} | observables]
  end

  defp parse_ip(nil), do: nil

  defp parse_ip(value) when is_binary(value) do
    value
    |> String.split(":")
    |> List.first()
  end

  defp parse_ip(_), do: nil

end
