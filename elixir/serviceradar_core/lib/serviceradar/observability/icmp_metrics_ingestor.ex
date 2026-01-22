defmodule ServiceRadar.Observability.IcmpMetricsIngestor do
  @moduledoc """
  Ingests ICMP check results into timeseries_metrics.

  Expected payload formats:

      %{\"results\" => [%{...}]}
      %{\"result\" => %{...}}
      [%{...}]
      %{...}

  Each result may include:
    - host/target/ip
    - response_time_ns (or response_time)
    - packet_loss
    - available
    - device_id (optional)
    - timestamp (optional)
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Observability.TimeseriesMetric

  @spec ingest(map() | list(), map()) :: :ok | {:error, term()}
  def ingest(payload, status) when is_map(payload) or is_list(payload) do
    actor = SystemActor.system(:icmp_metrics_ingestor)
    created_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      payload
      |> normalize_results()
      |> Enum.map(&build_metric_row(&1, status, actor, created_at))
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
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
      Logger.error("ICMP metrics ingest failed: #{inspect(e)}")
      {:error, e}
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  defp normalize_results(%{"results" => results}) when is_list(results), do: results
  defp normalize_results(%{"result" => result}) when is_map(result), do: [result]
  defp normalize_results(results) when is_list(results), do: results
  defp normalize_results(result) when is_map(result), do: [result]
  defp normalize_results(_), do: []

  defp build_metric_row(result, status, actor, created_at) when is_map(result) do
    host =
      fetch_string(result, [
        "target",
        "host",
        "host_ip",
        "hostIp",
        "ip",
        "address"
      ])

    response_time =
      fetch_value(result, [
        "response_time_ns",
        "responseTimeNs",
        "response_time",
        "responseTime",
        "round_trip",
        "roundTrip"
      ])

    response_time_ns = parse_duration_ns(response_time)

    if response_time_ns == nil do
      nil
    else
      device_id =
        fetch_string(result, [
          "device_id",
          "deviceId",
          "device_uid",
          "deviceUid"
        ])

      device_id = device_id || resolve_device_id(host, status, actor)

      %{
        timestamp:
          FieldParser.parse_timestamp(
            fetch_value(result, ["timestamp", "time", "ts"]) ||
              status[:agent_timestamp] ||
              status[:timestamp]
          ),
        gateway_id: status[:gateway_id] || "unknown",
        agent_id: status[:agent_id],
        metric_name: "icmp_response_time_ns",
        metric_type: "icmp",
        device_id: device_id,
        value: FieldParser.parse_value(response_time_ns),
        unit: "ns",
        tags: build_tags(result, host),
        partition: status[:partition],
        target_device_ip: host,
        metadata: build_metadata(result),
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

  defp build_tags(result, host) do
    base = %{}

    base
    |> maybe_put("check_id", fetch_string(result, ["check_id", "checkId"]))
    |> maybe_put("check_name", fetch_string(result, ["check_name", "checkName", "name"]))
    |> maybe_put("target", host)
    |> maybe_put("available", fetch_bool(result, ["available", "success"]))
    |> maybe_put("packet_loss", fetch_float(result, ["packet_loss", "packetLoss"]))
  end

  defp build_metadata(result) do
    %{}
    |> maybe_put("check_id", fetch_string(result, ["check_id", "checkId"]))
    |> maybe_put("check_name", fetch_string(result, ["check_name", "checkName", "name"]))
    |> maybe_put("available", fetch_bool(result, ["available", "success"]))
    |> maybe_put("packet_loss", fetch_float(result, ["packet_loss", "packetLoss"]))
    |> maybe_put("error", fetch_string(result, ["error"]))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp fetch_bool(map, keys) do
    case fetch_value(map, keys) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp fetch_float(map, keys) do
    case fetch_value(map, keys) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_duration_ns(nil), do: nil
  defp parse_duration_ns(value) when is_integer(value) and value >= 0, do: value
  defp parse_duration_ns(value) when is_float(value) and value >= 0, do: trunc(value)

  defp parse_duration_ns(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_duration_ns(_), do: nil
end
