defmodule ServiceRadar.Observability.AnomalyDetection.SampleExtractor do
  @moduledoc """
  Extracts scalar anomaly-analysis samples from telemetry stream messages.
  """

  alias ServiceRadar.EventWriter.Processors.Flows
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.EventWriter.Processors.OtelMetrics

  @event_id_keys [
    "event_id",
    :event_id,
    "eventId",
    :eventId,
    "uuid",
    :uuid,
    "uuidv8",
    :uuidv8,
    "message_id",
    :message_id,
    "messageId",
    :messageId
  ]

  @type sample :: %{
          required(:series_key) => String.t(),
          required(:event_id) => String.t(),
          required(:order_key) => term(),
          required(:value) => number(),
          required(:observed_at_unix_nano) => non_neg_integer() | nil,
          required(:subject) => String.t(),
          required(:metric_class) => String.t(),
          optional(:metadata) => map()
        }

  @doc """
  Extracts zero or more scalar samples from a Broadway message.
  """
  @spec extract(map()) :: [sample()]
  def extract(%{metadata: metadata} = message) do
    subject = subject(metadata)

    cond do
      String.starts_with?(subject, "metrics.") ->
        extract_metrics(message, subject)

      String.starts_with?(subject, "otel.metrics") ->
        extract_otel_metrics(message, subject)

      subject in ["flows.raw.netflow", "flows.raw.sflow"] or
          String.starts_with?(subject, "flow.attributed.") ->
        extract_flow(message, subject)

      true ->
        []
    end
  end

  def extract(_message), do: []

  defp extract_metrics(message, subject) do
    case Metrics.parse_message(message) do
      %{family: family, payload: %{"status" => status}} ->
        sysmon_samples(family, status, subject)

      %{value: value} = row ->
        "snmp:#{row[:series_key] || series_identity(row)}"
        |> build_sample(
          value,
          timestamp_nano(row[:timestamp]),
          subject,
          "snmp",
          row
        )
        |> List.wrap()

      _ ->
        []
    end
  end

  defp extract_otel_metrics(message, subject) do
    message
    |> OtelMetrics.parse_message()
    |> List.wrap()
    |> Enum.flat_map(&otel_sample(&1, subject))
  end

  defp extract_flow(message, subject) do
    case Flows.parse_message(message) do
      %{bytes_total: value} = row ->
        "flow:#{subject}:#{row[:sampler_address] || "unknown"}:#{row[:src_endpoint_ip]}:#{row[:dst_endpoint_ip]}:#{row[:protocol_num]}"
        |> build_sample(
          value,
          timestamp_nano(row[:time]),
          subject,
          "flow",
          row
        )
        |> List.wrap()

      _ ->
        []
    end
  end

  defp sysmon_samples("cpu", status, subject) do
    host = host_identity(status)

    status
    |> Map.get("cpus", [])
    |> Enum.flat_map(fn cpu ->
      value = first_number(cpu, ["usage_percent", "usage"])
      core_id = Map.get(cpu, "core_id", Map.get(cpu, "id", "all"))

      "sysmon:cpu:#{host}:#{core_id}"
      |> build_sample(
        value,
        sysmon_timestamp(status),
        subject,
        "sysmon.cpu",
        cpu
      )
      |> List.wrap()
    end)
  end

  defp sysmon_samples("memory", status, subject) do
    memory = Map.get(status, "memory", %{})

    value =
      percent_or_number(memory, "used_bytes", "total_bytes", ["usage_percent", "used_percent"])

    "sysmon:memory:#{host_identity(status)}"
    |> build_sample(
      value,
      sysmon_timestamp(status),
      subject,
      "sysmon.memory",
      memory
    )
    |> List.wrap()
  end

  defp sysmon_samples("disk", status, subject) do
    host = host_identity(status)

    status
    |> Map.get("disks", [])
    |> Enum.flat_map(fn disk ->
      value =
        percent_or_number(disk, "used_bytes", "total_bytes", ["usage_percent", "used_percent"])

      mount = Map.get(disk, "mount_point", Map.get(disk, "name", "unknown"))

      "sysmon:disk:#{host}:#{mount}"
      |> build_sample(
        value,
        sysmon_timestamp(status),
        subject,
        "sysmon.disk",
        disk
      )
      |> List.wrap()
    end)
  end

  defp sysmon_samples("process", status, subject) do
    processes = Map.get(status, "processes", [])

    "sysmon:process_count:#{host_identity(status)}"
    |> build_sample(
      length(processes),
      sysmon_timestamp(status),
      subject,
      "sysmon.process",
      %{"process_count" => length(processes)}
    )
    |> List.wrap()
  end

  defp sysmon_samples(_family, _status, _subject), do: []

  defp otel_sample(%{value: value} = row, subject) do
    "otel:#{row[:service_name]}:#{row[:metric_name]}:#{row[:attributes_hash]}"
    |> build_sample(
      value,
      timestamp_nano(row[:timestamp]),
      subject,
      "otel.metric_point",
      row
    )
    |> List.wrap()
  end

  defp otel_sample(%{duration_ms: value} = row, subject) do
    "otel:span_duration:#{row[:service_name]}:#{row[:span_name]}:#{row[:span_id]}"
    |> build_sample(
      value,
      timestamp_nano(row[:timestamp]),
      subject,
      "otel.span_duration",
      row
    )
    |> List.wrap()
  end

  defp otel_sample(_row, _subject), do: []

  defp build_sample(_series_key, value, _timestamp, _subject, _metric_class, _metadata)
       when not is_number(value), do: nil

  defp build_sample(_series_key, value, _timestamp, _subject, _metric_class, _metadata)
       when value != value, do: nil

  defp build_sample(series_key, value, timestamp, subject, metric_class, metadata) do
    %{
      series_key: series_key,
      event_id: event_id(series_key, timestamp, subject, value, metadata),
      order_key: order_key(series_key, timestamp, subject, value, metadata),
      value: value * 1.0,
      observed_at_unix_nano: timestamp,
      subject: subject,
      metric_class: metric_class,
      metadata: metadata
    }
  end

  defp first_number(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_number(value) -> value
        _ -> nil
      end
    end)
  end

  defp first_number(_map, _keys), do: nil

  defp percent_or_number(map, used_key, total_key, fallback_keys) do
    case {Map.get(map, used_key), Map.get(map, total_key)} do
      {used, total} when is_number(used) and is_number(total) and total > 0 ->
        used * 100.0 / total

      _ ->
        first_number(map, fallback_keys)
    end
  end

  defp series_identity(row) do
    Enum.map_join(
      [
        row[:agent_id],
        row[:gateway_id],
        row[:target_device_ip],
        row[:if_index],
        row[:metric_name]
      ],
      ":",
      &to_string/1
    )
  end

  defp host_identity(status) do
    Map.get(status, "host_id") || Map.get(status, "host_ip") || Map.get(status, "agent_id") ||
      "unknown"
  end

  defp sysmon_timestamp(status), do: timestamp_nano(Map.get(status, "timestamp"))

  defp timestamp_nano(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :nanosecond)

  defp timestamp_nano(value) when is_integer(value) and value >= 0, do: value

  defp timestamp_nano(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :nanosecond)
      _ -> nil
    end
  end

  defp timestamp_nano(_value), do: nil

  defp event_id(series_key, timestamp, subject, value, metadata) do
    explicit_event_id(metadata) ||
      stable_hash([series_key, timestamp, subject, value])
  end

  defp order_key(series_key, timestamp, subject, value, metadata) do
    case explicit_event_id(metadata) do
      event_id when is_binary(event_id) -> event_id
      nil -> {timestamp || 0, stable_hash([series_key, timestamp, subject, value])}
    end
  end

  defp explicit_event_id(metadata) when is_map(metadata) do
    Enum.find_value(@event_id_keys, fn key ->
      case Map.get(metadata, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp explicit_event_id(_metadata), do: nil

  defp stable_hash(parts) do
    parts
    |> Enum.map_join("|", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp subject(metadata) when is_map(metadata),
    do: metadata[:base_subject] || metadata[:subject] || ""

  defp subject(_metadata), do: ""
end
