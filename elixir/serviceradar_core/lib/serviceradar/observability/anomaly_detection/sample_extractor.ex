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
    :messageId,
    "ingress_id",
    :ingress_id,
    "ingressId",
    :ingressId
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
    ingress_metadata = ingress_metadata(message)

    cond do
      String.starts_with?(subject, "metrics.") ->
        extract_metrics(message, subject, ingress_metadata)

      String.starts_with?(subject, "otel.metrics") ->
        extract_otel_metrics(message, subject, ingress_metadata)

      subject in ["flows.raw.netflow", "flows.raw.sflow"] or
          String.starts_with?(subject, "flow.attributed.") ->
        extract_flow(message, subject, ingress_metadata)

      true ->
        []
    end
  end

  def extract(_message), do: []

  defp extract_metrics(message, subject, ingress_metadata) do
    case Metrics.parse_message(message) do
      %{family: family, payload: %{"status" => status}} ->
        sysmon_samples(family, status, subject, ingress_metadata)

      %{value: value} = row ->
        "snmp:#{row[:series_key] || series_identity(row)}"
        |> build_sample(
          value,
          timestamp_nano(row[:timestamp]),
          subject,
          "snmp",
          merge_ingress_metadata(row, ingress_metadata)
        )
        |> List.wrap()

      _ ->
        []
    end
  end

  defp extract_otel_metrics(message, subject, ingress_metadata) do
    message
    |> OtelMetrics.parse_message()
    |> List.wrap()
    |> Enum.flat_map(&otel_sample(&1, subject, ingress_metadata))
  end

  defp extract_flow(message, subject, ingress_metadata) do
    case Flows.parse_message(message) do
      %{bytes_total: value} = row ->
        "flow:#{subject}:#{row[:sampler_address] || "unknown"}:#{row[:src_endpoint_ip]}:#{row[:dst_endpoint_ip]}:#{row[:protocol_num]}"
        |> build_sample(
          value,
          timestamp_nano(row[:time]),
          subject,
          "flow",
          merge_ingress_metadata(row, ingress_metadata)
        )
        |> List.wrap()

      _ ->
        []
    end
  end

  defp sysmon_samples("cpu", status, subject, ingress_metadata) do
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
        merge_ingress_metadata(cpu, ingress_metadata)
      )
      |> List.wrap()
    end)
  end

  defp sysmon_samples("memory", status, subject, ingress_metadata) do
    memory = Map.get(status, "memory", %{})

    value =
      percent_or_number(memory, "used_bytes", "total_bytes", ["usage_percent", "used_percent"])

    "sysmon:memory:#{host_identity(status)}"
    |> build_sample(
      value,
      sysmon_timestamp(status),
      subject,
      "sysmon.memory",
      merge_ingress_metadata(memory, ingress_metadata)
    )
    |> List.wrap()
  end

  defp sysmon_samples("disk", status, subject, ingress_metadata) do
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
        merge_ingress_metadata(disk, ingress_metadata)
      )
      |> List.wrap()
    end)
  end

  defp sysmon_samples("process", status, subject, ingress_metadata) do
    processes = Map.get(status, "processes", [])

    "sysmon:process_count:#{host_identity(status)}"
    |> build_sample(
      length(processes),
      sysmon_timestamp(status),
      subject,
      "sysmon.process",
      merge_ingress_metadata(%{"process_count" => length(processes)}, ingress_metadata)
    )
    |> List.wrap()
  end

  defp sysmon_samples(_family, _status, _subject, _ingress_metadata), do: []

  defp otel_sample(%{value: value} = row, subject, ingress_metadata) do
    "otel:#{row[:service_name]}:#{row[:metric_name]}:#{row[:attributes_hash]}"
    |> build_sample(
      value,
      timestamp_nano(row[:timestamp]),
      subject,
      "otel.metric_point",
      merge_ingress_metadata(row, ingress_metadata)
    )
    |> List.wrap()
  end

  defp otel_sample(%{duration_ms: value} = row, subject, ingress_metadata) do
    "otel:span_duration:#{row[:service_name]}:#{row[:span_name]}:#{row[:span_id]}"
    |> build_sample(
      value,
      timestamp_nano(row[:timestamp]),
      subject,
      "otel.span_duration",
      merge_ingress_metadata(row, ingress_metadata)
    )
    |> List.wrap()
  end

  defp otel_sample(_row, _subject, _ingress_metadata), do: []

  defp build_sample(_series_key, value, _timestamp, _subject, _metric_class, _metadata)
       when not is_number(value), do: nil

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

  defp ingress_metadata(%{data: data, metadata: metadata}) do
    data
    |> ingress_metadata_from_payload()
    |> Map.merge(ingress_metadata_from_headers(metadata_headers(metadata)))
  end

  defp ingress_metadata(_message), do: %{}

  defp ingress_metadata_from_payload(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = payload} ->
        %{}
        |> maybe_put_metadata("ingress_id", non_empty_string(Map.get(payload, "ingress_id")))
        |> maybe_put_metadata(
          "ingress_timestamp_unix_nano",
          parse_non_negative_integer(Map.get(payload, "ingress_timestamp_unix_nano"))
        )

      _ ->
        %{}
    end
  end

  defp ingress_metadata_from_payload(_data), do: %{}

  defp ingress_metadata_from_headers(headers) do
    %{}
    |> maybe_put_metadata("ingress_id", header_value(headers, "sr-ingress-id"))
    |> maybe_put_metadata(
      "ingress_timestamp_unix_nano",
      headers |> header_value("sr-ingress-time-unix-nano") |> parse_non_negative_integer()
    )
  end

  defp metadata_headers(metadata) when is_map(metadata), do: Map.get(metadata, :headers)
  defp metadata_headers(_metadata), do: nil

  defp merge_ingress_metadata(metadata, ingress_metadata)
       when is_map(metadata) and map_size(ingress_metadata) > 0,
       do: Map.merge(metadata, ingress_metadata)

  defp merge_ingress_metadata(metadata, _ingress_metadata), do: metadata

  defp event_id(series_key, timestamp, subject, value, metadata) do
    sample_hash = stable_hash([series_key, timestamp, subject, value])

    case explicit_event_identity(metadata) do
      {:ingress_id, ingress_id} -> "#{ingress_id}:#{sample_hash}"
      {:event_id, event_id} -> event_id
      nil -> sample_hash
    end
  end

  defp order_key(series_key, timestamp, subject, value, metadata) do
    sample_hash = stable_hash([series_key, timestamp, subject, value])

    order_key(
      explicit_event_identity(metadata),
      order_timestamp(timestamp, metadata),
      timestamp,
      sample_hash
    )
  end

  defp order_key({:ingress_id, ingress_id}, order_timestamp, timestamp, sample_hash) do
    {order_timestamp, ingress_id, timestamp || 0, sample_hash}
  end

  defp order_key({:event_id, event_id}, order_timestamp, timestamp, sample_hash) do
    {order_timestamp, event_id, timestamp || 0, sample_hash}
  end

  defp order_key(nil, order_timestamp, timestamp, sample_hash) do
    {order_timestamp, sample_hash, timestamp || 0, sample_hash}
  end

  defp explicit_event_identity(metadata) when is_map(metadata) do
    Enum.find_value(@event_id_keys, fn key ->
      case Map.get(metadata, key) do
        value when is_binary(value) and value != "" -> {event_id_key_type(key), value}
        _ -> nil
      end
    end)
  end

  defp event_id_key_type(key) when key in ["ingress_id", :ingress_id, "ingressId", :ingressId],
    do: :ingress_id

  defp event_id_key_type(_key), do: :event_id

  defp order_timestamp(timestamp, metadata) do
    ingress_timestamp(metadata) || timestamp || 0
  end

  defp ingress_timestamp(metadata) when is_map(metadata) do
    Map.get(metadata, "ingress_timestamp_unix_nano") ||
      Map.get(metadata, :ingress_timestamp_unix_nano)
  end

  defp stable_hash(parts) do
    parts
    |> Enum.map_join("|", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp header_value(headers, key) when is_map(headers) do
    headers
    |> Enum.find_value(fn {header_key, value} ->
      if normalize_header_key(header_key) == key, do: normalize_header_value(value)
    end)
    |> non_empty_string()
  end

  defp header_value(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {header_key, value} ->
        if normalize_header_key(header_key) == key, do: normalize_header_value(value)

      _other ->
        nil
    end)
    |> non_empty_string()
  end

  defp header_value(_headers, _key), do: nil

  defp normalize_header_key(key) when is_binary(key), do: String.downcase(key)

  defp normalize_header_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase()

  defp normalize_header_key(key) when is_list(key) do
    key |> to_string() |> String.downcase()
  rescue
    _ -> ""
  end

  defp normalize_header_key(_key), do: ""

  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value([first | _rest]) when is_binary(first), do: first

  defp normalize_header_value(value) when is_list(value) do
    to_string(value)
  rescue
    _ -> nil
  end

  defp normalize_header_value(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_header_value(_value), do: nil

  defp non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_string(_value), do: nil

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp subject(metadata) when is_map(metadata),
    do: metadata[:base_subject] || metadata[:subject] || ""

  defp subject(_metadata), do: ""
end
