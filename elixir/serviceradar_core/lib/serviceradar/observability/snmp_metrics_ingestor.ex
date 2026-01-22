defmodule ServiceRadar.Observability.SnmpMetricsIngestor do
  @moduledoc """
  Ingests SNMP metric payloads into timeseries_metrics.

  Expected payload format:

      %{"results" => [%{...}]}

  Each result may include:
    - host / target / host_ip
    - metric (name)
    - oid
    - value
    - timestamp
    - data_type
    - scale
    - delta
    - if_index
    - interface_uid
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Observability.TimeseriesMetric

  @spec ingest(map() | list(), map()) :: :ok | {:error, term()}
  def ingest(payload, status) when is_map(payload) or is_list(payload) do
    actor = SystemActor.system(:snmp_metrics_ingestor)
    created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      payload
      |> normalize_results()
      |> Enum.map(&build_metric_row(&1, status, actor, created_at))
      |> Enum.reject(&is_nil/1)

    if rows == [] do
      :ok
    else
      case Ash.bulk_create(rows, TimeseriesMetric, :create,
             actor: actor,
             domain: ServiceRadar.Observability,
             return_records?: false,
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success} -> :ok
        %Ash.BulkResult{status: :error, errors: errors} = result ->
          {:error, errors || result}
        {:ok, _} -> :ok
        {:error, error} -> {:error, error}
        other -> {:error, other}
      end
    end
  rescue
    e ->
      Logger.error("SNMP metrics ingest failed: #{inspect(e)}")
      {:error, e}
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  defp normalize_results(%{"results" => results}) when is_list(results), do: results
  defp normalize_results(results) when is_list(results), do: results
  defp normalize_results(_), do: []

  defp build_metric_row(result, status, actor, created_at) when is_map(result) do
    host =
      fetch_string(result, [
        "target",
        "host",
        "host_ip",
        "hostIp",
        "target_device_ip",
        "targetDeviceIp",
        "ip"
      ])

    metric_name =
      fetch_string(result, [
        "metric",
        "metric_name",
        "metricName",
        "name"
      ])

    oid = fetch_string(result, ["oid", "oid_name", "oidName"])

    {value, numeric?} = parse_numeric(fetch_value(result, ["value"]))

    if is_nil(host) or is_nil(metric_name) or not numeric? do
      nil
    else
      device_id = resolve_device_id(host, status, actor)
      if_index = parse_if_index(result, oid)
      interface_uid = fetch_string(result, ["interface_uid", "interfaceUid"])
      scale = parse_float(fetch_value(result, ["scale"]))
      delta = parse_bool(fetch_value(result, ["delta", "is_delta"]))
      data_type = fetch_string(result, ["data_type", "dataType"])
      unit = fetch_string(result, ["unit"])

      %{
        timestamp:
          FieldParser.parse_timestamp(
            fetch_value(result, ["timestamp", "time", "ts"]) ||
              status[:agent_timestamp] ||
              status[:timestamp]
          ),
        gateway_id: status[:gateway_id] || "unknown",
        agent_id: status[:agent_id],
        metric_name: metric_name,
        metric_type: "snmp",
        device_id: device_id,
        value: value,
        unit: unit,
        tags: build_tags(host, metric_name, interface_uid),
        partition: status[:partition],
        scale: scale,
        is_delta: delta,
        target_device_ip: host,
        if_index: if_index,
        metadata: build_metadata(oid, data_type, interface_uid),
        created_at: created_at
      }
    end
  end

  defp build_metric_row(_result, _status, _actor, _created_at), do: nil

  defp resolve_device_id(nil, _status, _actor), do: nil
  defp resolve_device_id("", _status, _actor), do: nil

  defp resolve_device_id(host, status, actor) do
    partition = status[:partition] || "default"

    keys =
      if is_binary(partition) and partition != "" do
        [%{kind: :partition_ip, value: "#{partition}:#{host}"}, %{kind: :ip, value: host}]
      else
        [%{kind: :ip, value: host}]
      end

    case DeviceLookup.get_canonical_device(keys, actor: actor, ip_hint: host) do
      {:ok, %{record: %{canonical_device_id: device_id}}} when is_binary(device_id) -> device_id
      _ -> nil
    end
  end

  defp build_tags(host, metric, interface_uid) do
    %{}
    |> maybe_put("target", host)
    |> maybe_put("metric", metric)
    |> maybe_put("interface_uid", interface_uid)
  end

  defp build_metadata(oid, data_type, interface_uid) do
    %{}
    |> maybe_put("oid", oid)
    |> maybe_put("data_type", data_type)
    |> maybe_put("interface_uid", interface_uid)
  end

  defp parse_if_index(result, oid) do
    value = fetch_value(result, ["if_index", "ifIndex", "interface_index", "interfaceIndex"])

    case value do
      int when is_integer(int) -> int
      bin when is_binary(bin) ->
        case Integer.parse(bin) do
          {parsed, _} -> parsed
          :error -> parse_if_index_from_oid(oid)
        end
      _ ->
        parse_if_index_from_oid(oid)
    end
  end

  defp parse_if_index_from_oid(nil), do: nil
  defp parse_if_index_from_oid(""), do: nil

  defp parse_if_index_from_oid(oid) when is_binary(oid) do
    oid
    |> String.trim()
    |> String.split(".")
    |> List.last()
    |> case do
      nil -> nil
      "" -> nil
      last ->
        case Integer.parse(last) do
          {parsed, _} -> parsed
          :error -> nil
        end
    end
  end

  defp parse_numeric(nil), do: {nil, false}
  defp parse_numeric(v) when is_integer(v), do: {v / 1, true}
  defp parse_numeric(v) when is_float(v), do: {v, true}
  defp parse_numeric(v) when is_boolean(v), do: {(if v, do: 1.0, else: 0.0), true}

  defp parse_numeric(v) when is_binary(v) do
    case Float.parse(v) do
      {parsed, _} -> {parsed, true}
      :error -> {nil, false}
    end
  end

  defp parse_numeric(_), do: {nil, false}

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v / 1

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_bool(nil), do: false
  defp parse_bool(v) when is_boolean(v), do: v

  defp parse_bool(v) when is_binary(v),
    do: String.downcase(v) in ["true", "1", "yes", "on"]

  defp parse_bool(_), do: false

  defp fetch_value(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp fetch_string(map, keys) do
    case fetch_value(map, keys) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
