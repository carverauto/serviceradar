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

  alias ServiceRadar.Observability.MtrGraph
  alias ServiceRadar.Repo

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
    Repo.transaction(fn ->
      Enum.each(results, fn result ->
        insert_single_result(result, agent_id, gateway_id, partition, now)
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_single_result(result, agent_id, gateway_id, partition, now) when is_map(result) do
    trace = result["trace"] || %{}
    trace_id = Ecto.UUID.bingenerate()
    trace_time = parse_trace_time(trace["timestamp"] || result["timestamp"]) || now

    trace_row = %{
      id: trace_id,
      time: trace_time,
      agent_id: agent_id,
      gateway_id: gateway_id,
      check_id: result["check_id"],
      check_name: result["check_name"],
      device_id: result["device_id"],
      target: result["target"] || trace["target"] || "",
      target_ip: trace["target_ip"] || result["target"] || "",
      target_reached: result["available"] || trace["target_reached"] || false,
      total_hops: trace["total_hops"] || 0,
      protocol: trace["protocol"] || "icmp",
      ip_version: trace["ip_version"] || 4,
      packet_size: trace["packet_size"],
      partition: partition,
      error: result["error"]
    }

    insert_trace(trace_row)

    hops = trace["hops"] || []

    unless Enum.empty?(hops) do
      insert_hops(hops, trace_id, trace_time)
    end
  end

  defp insert_single_result(_result, _agent_id, _gateway_id, _partition, _now), do: :ok

  defp insert_trace(row) do
    Repo.query!(
      """
      INSERT INTO mtr_traces (
        id, time, agent_id, gateway_id, check_id, check_name, device_id,
        target, target_ip, target_reached, total_hops, protocol,
        ip_version, packet_size, partition, error
      ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16
      )
      """,
      [
        row.id,
        row.time,
        row.agent_id,
        row.gateway_id,
        row.check_id,
        row.check_name,
        row.device_id,
        row.target,
        row.target_ip,
        row.target_reached,
        row.total_hops,
        row.protocol,
        row.ip_version,
        row.packet_size,
        row.partition,
        row.error
      ]
    )
  end

  defp insert_hops(hops, trace_id, trace_time) do
    Enum.each(hops, fn hop ->
      insert_hop(hop, trace_id, trace_time)
    end)
  end

  defp insert_hop(hop, trace_id, trace_time) when is_map(hop) do
    ecmp_addrs = hop["ecmp_addrs"] || []
    asn_info = hop["asn"] || %{}
    mpls_labels = hop["mpls_labels"]

    mpls_json =
      if is_list(mpls_labels) and mpls_labels != [] do
        Jason.encode!(mpls_labels)
      end

    Repo.query!(
      """
      INSERT INTO mtr_hops (
        id, time, trace_id, hop_number, addr, hostname, ecmp_addrs,
        asn, asn_org, mpls_labels, sent, received, loss_pct,
        last_us, avg_us, min_us, max_us, stddev_us,
        jitter_us, jitter_worst_us, jitter_interarrival_us
      ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, $11, $12, $13,
        $14, $15, $16, $17, $18, $19, $20, $21
      )
      """,
      [
        Ecto.UUID.bingenerate(),
        trace_time,
        trace_id,
        hop["hop_number"] || 0,
        hop["addr"],
        hop["hostname"],
        ecmp_addrs,
        parse_asn(asn_info["asn"]),
        asn_info["org"],
        mpls_json,
        hop["sent"] || 0,
        hop["received"] || 0,
        hop["loss_pct"] || 0.0,
        hop["last_us"],
        hop["avg_us"],
        hop["min_us"],
        hop["max_us"],
        hop["stddev_us"],
        hop["jitter_us"],
        hop["jitter_worst_us"],
        hop["jitter_interarrival_us"]
      ]
    )
  end

  defp insert_hop(_hop, _trace_id, _trace_time), do: :ok

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
