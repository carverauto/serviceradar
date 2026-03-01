defmodule ServiceRadar.Observability.MtrMetricsIngestor do
  @moduledoc """
  Ingests MTR (My Traceroute) check results into mtr_traces and mtr_hops tables.

  Expected payload format from agent:

      %{"results" => [
        %{
          "check_id" => "...",
          "check_name" => "...",
          "target" => "8.8.8.8",
          "device_id" => "...",
          "available" => true,
          "trace" => %{
            "target" => "8.8.8.8",
            "target_ip" => "8.8.8.8",
            "target_reached" => true,
            "total_hops" => 10,
            "protocol" => "icmp",
            "ip_version" => 4,
            "packet_size" => 64,
            "hops" => [%{...}],
            "timestamp" => 1234567890
          },
          "timestamp" => 1234567890,
          "error" => nil
        }
      ]}
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.{MtrGraph, MtrHop, MtrTrace}

  @spec ingest(map() | list(), map()) :: :ok | {:error, term()}
  def ingest(payload, status) when is_map(payload) or is_list(payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    agent_id = status[:agent_id] || "unknown"
    gateway_id = status[:gateway_id]
    partition = status[:partition]

    results = normalize_results(payload)

    if Enum.empty?(results) do
      :ok
    else
      case insert_results(results, agent_id, gateway_id, partition, now) do
        :ok ->
          MtrGraph.project_traces(results, status)
          :ok

        error ->
          error
      end
    end
  rescue
    e ->
      Logger.error("MTR metrics ingest failed: #{inspect(e)}")
      {:error, e}
  end

  def ingest(_payload, _status), do: {:error, :invalid_payload}

  defp normalize_results(%{"results" => results}) when is_list(results), do: results
  defp normalize_results(%{"result" => result}) when is_map(result), do: [result]
  defp normalize_results(results) when is_list(results), do: results
  defp normalize_results(result) when is_map(result), do: [result]
  defp normalize_results(_), do: []

  defp insert_results(results, agent_id, gateway_id, partition, now) do
    actor = SystemActor.system(:mtr_metrics_ingestor)

    Ash.transaction(
      [MtrTrace, MtrHop],
      fn ->
        Enum.reduce_while(results, :ok, fn result, _acc ->
          reduce_insert_result(result, agent_id, gateway_id, partition, now, actor)
        end)
      end,
      actor: actor
    )
    |> case do
      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:error, reason, _stacktrace} ->
        {:error, reason}
    end
  end

  defp reduce_insert_result(result, agent_id, gateway_id, partition, now, actor) do
    case insert_single_result(result, agent_id, gateway_id, partition, now, actor) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp insert_single_result(result, agent_id, gateway_id, partition, now, actor)
       when is_map(result) do
    trace = map_get_any(result, ["trace", :trace], %{})

    target_value =
      first_present(
        [
          map_get_any(trace, ["target_ip", :target_ip], nil),
          map_get_any(trace, ["target", :target], nil),
          map_get_any(result, ["target", :target], nil)
        ],
        ""
      )

    if is_binary(target_value) and String.trim(target_value) != "" do
      trace_id = Ecto.UUID.generate()
      trace_time = trace_time(result, trace, now)

      with {:ok, _trace} <-
             result
             |> build_trace_row(trace, trace_id, trace_time, agent_id, gateway_id, partition)
             |> insert_trace(actor),
           :ok <-
             insert_trace_hops(
               map_get_any(trace, ["hops", :hops], []),
               trace_id,
               trace_time,
               actor
             ) do
        :ok
      end
    else
      {:error, :missing_target_ip}
    end
  end

  defp insert_single_result(_result, _agent_id, _gateway_id, _partition, _now, _actor), do: :ok

  defp insert_trace(row, actor) do
    MtrTrace
    |> Ash.Changeset.for_create(:create, row)
    |> Ash.create(actor: actor)
  end

  defp insert_hops(hops, trace_id, trace_time, actor) do
    Enum.reduce_while(hops, :ok, fn hop, _acc ->
      case insert_hop(hop, trace_id, trace_time, actor) do
        {:ok, _hop} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp trace_time(result, trace, now) do
    parse_trace_time(
      map_get_any(trace, ["timestamp", :timestamp], nil) ||
        map_get_any(result, ["timestamp", :timestamp], nil)
    ) || now
  end

  defp build_trace_row(result, trace, trace_id, trace_time, agent_id, gateway_id, partition) do
    %{
      id: trace_id,
      time: trace_time,
      agent_id: agent_id,
      gateway_id: gateway_id,
      check_id: result["check_id"],
      check_name: result["check_name"],
      device_id: result["device_id"],
      target: first_present([result["target"], trace["target"]], ""),
      target_ip: first_present([trace["target_ip"], result["target"]], ""),
      target_reached: first_non_nil([result["available"], trace["target_reached"]], false),
      total_hops: trace["total_hops"] || 0,
      protocol: trace["protocol"] || "icmp",
      ip_version: trace["ip_version"] || 4,
      packet_size: trace["packet_size"],
      partition: partition,
      error: result["error"]
    }
  end

  defp insert_trace_hops([], _trace_id, _trace_time, _actor), do: :ok

  defp insert_trace_hops(hops, trace_id, trace_time, actor) when is_list(hops),
    do: insert_hops(hops, trace_id, trace_time, actor)

  defp insert_trace_hops(hops, trace_id, trace_time, actor) do
    hops
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> insert_hops(trace_id, trace_time, actor)
  end

  defp first_present(values, default) when is_list(values) do
    Enum.find_value(values, default, fn
      nil -> nil
      false -> nil
      value -> value
    end)
  end

  defp first_non_nil(values, default) when is_list(values) do
    case Enum.find(values, :not_found, fn value -> value != nil end) do
      :not_found -> default
      value -> value
    end
  end

  defp insert_hop(hop, trace_id, trace_time, actor) when is_map(hop) do
    ecmp_addrs = hop["ecmp_addrs"] || []
    asn_info = hop["asn"] || %{}
    mpls_labels = hop["mpls_labels"]

    mpls_payload =
      if is_list(mpls_labels) and mpls_labels != [] do
        %{"labels" => mpls_labels}
      else
        nil
      end

    attrs = %{
      id: Ecto.UUID.generate(),
      time: trace_time,
      trace_id: trace_id,
      hop_number: hop["hop_number"] || 0,
      addr: hop["addr"],
      hostname: hop["hostname"],
      ecmp_addrs: ecmp_addrs,
      asn: parse_asn(asn_info["asn"]),
      asn_org: asn_info["org"],
      mpls_labels: mpls_payload,
      sent: hop["sent"] || 0,
      received: hop["received"] || 0,
      loss_pct: hop["loss_pct"] || 0.0,
      last_us: hop["last_us"],
      avg_us: hop["avg_us"],
      min_us: hop["min_us"],
      max_us: hop["max_us"],
      stddev_us: hop["stddev_us"],
      jitter_us: hop["jitter_us"],
      jitter_worst_us: hop["jitter_worst_us"],
      jitter_interarrival_us: hop["jitter_interarrival_us"]
    }

    MtrHop
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp insert_hop(_hop, _trace_id, _trace_time, _actor), do: {:ok, nil}

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  defp parse_trace_time(nil), do: nil

  defp parse_trace_time(ts) when is_integer(ts) and ts > 1_000_000_000_000_000 do
    # Nanoseconds
    case DateTime.from_unix(ts, :nanosecond) do
      {:ok, dt} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_trace_time(ts) when is_integer(ts) and ts > 1_000_000_000_000 do
    # Microseconds
    case DateTime.from_unix(ts, :microsecond) do
      {:ok, dt} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_trace_time(ts) when is_integer(ts) and ts > 0 do
    # Seconds
    case DateTime.from_unix(ts) do
      {:ok, dt} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_trace_time(_), do: nil

  defp parse_asn(nil), do: nil
  defp parse_asn(0), do: nil
  defp parse_asn(asn) when is_integer(asn), do: asn

  defp parse_asn(asn) when is_binary(asn) do
    case Integer.parse(asn) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_asn(_), do: nil
end
