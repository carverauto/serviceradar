defmodule ServiceRadar.FlowAttribution do
  @moduledoc """
  Persists netprobe process attributions (5-tuple -> process) pushed by agents,
  and correlates them against collected NetFlow/sFlow in `ocsf_network_activity`.

  NetFlow remains the authoritative flow source — netprobe only supplies the WHO.
  `persist/3` writes each pushed `FlowAttributionEvent` to `flow_process_attributions`;
  `correlate/0` joins recent attributions against recent NetFlow (either direction)
  and stamps matching flows with `event_type=attributed_flow` + the process context,
  which the web UI (`/observability/flows/attributed`) reads.
  """

  alias Netprobepb.FlowAttributionEvent

  require Logger

  @schema "platform"
  @table "flow_process_attributions"
  @correlation_window_minutes 15
  @correlation_skew_seconds 900
  @default_retention_minutes 60
  @minimum_retention_minutes div(@correlation_skew_seconds + 59, 60)

  @doc "Persist a batch of pushed attribution events."
  @spec persist([FlowAttributionEvent.t()], String.t() | nil, String.t() | nil) :: :ok
  def persist(events, partition_id, agent_id) when is_list(events) do
    rows =
      events
      |> Enum.map(&row_from_event(&1, partition_id, agent_id))
      |> Enum.reject(&is_nil/1)

    if rows != [] do
      ServiceRadar.Repo.insert_all(@table, rows, prefix: @schema)
    end

    :ok
  rescue
    error ->
      Logger.warning("FlowAttribution.persist failed: #{inspect(error)}")
      :ok
  end

  def persist(_events, _partition_id, _agent_id), do: :ok

  defp row_from_event(%FlowAttributionEvent{} = event, partition_id, agent_id) do
    with proto when is_integer(proto) <- transport_to_proto(event.transport_protocol),
         true <- is_binary(event.local_ip) and event.local_ip != "",
         true <- is_binary(event.remote_ip) and event.remote_ip != "" do
      %{
        observed_at: observed_at(event),
        partition: partition_id || "default",
        agent_id: agent_id,
        proto: proto,
        local_ip: event.local_ip,
        local_port: event.local_port || 0,
        remote_ip: event.remote_ip,
        remote_port: event.remote_port || 0,
        pid: zero_to_nil(event.pid),
        comm: blank_to_nil(event.comm),
        cmdline: cmdline_to_string(event.redacted_cmdline),
        uid: zero_to_nil(event.uid),
        container_id: blank_to_nil(event.container_id)
      }
    else
      _ -> nil
    end
  end

  defp row_from_event(_event, _partition_id, _agent_id), do: nil

  @doc """
  Correlate recent attributions with recent NetFlow and stamp matches as
  `attributed_flow`. Direction-agnostic (matches src->dst or dst->src). Idempotent.
  """
  @spec correlate() :: {:ok, non_neg_integer()} | {:error, term()}
  def correlate do
    sql = """
    WITH recent_flows AS (
      SELECT
        f.tableoid,
        f.ctid,
        f.time,
        f.partition,
        f.protocol_num,
        f.src_endpoint_ip,
        f.src_endpoint_port,
        f.dst_endpoint_ip,
        f.dst_endpoint_port
      FROM #{@schema}.ocsf_network_activity AS f
      WHERE f.time > now() - interval '#{@correlation_window_minutes} minutes'
        AND (f.ocsf_payload ->> 'event_type') IS DISTINCT FROM 'attributed_flow'
    ),
    candidates AS (
      SELECT
        f.tableoid AS flow_tableoid,
        f.ctid AS flow_ctid,
        picked.agent_id,
        picked.pid,
        picked.comm,
        picked.cmdline,
        picked.uid,
        picked.container_id
      FROM recent_flows AS f
      JOIN LATERAL (
        SELECT
          agent_id,
          pid,
          comm,
          cmdline,
          uid,
          container_id,
          match_rank,
          time_delta_seconds,
          observed_at
        FROM (
          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.src_endpoint_ip
            AND a.remote_ip = f.dst_endpoint_ip
            AND a.local_port = f.src_endpoint_port
            AND a.remote_port = f.dst_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.dst_endpoint_ip
            AND a.remote_ip = f.src_endpoint_ip
            AND a.local_port = f.dst_endpoint_port
            AND a.remote_port = f.src_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto IN (1, 58)
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.src_endpoint_ip
            AND a.remote_ip = f.dst_endpoint_ip

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto IN (1, 58)
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.dst_endpoint_ip
            AND a.remote_ip = f.src_endpoint_ip

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            1 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          WHERE f.protocol_num = 17
            AND a.partition = f.partition
            AND a.proto = 17
            AND a.remote_port > 0
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.src_endpoint_ip
            AND a.remote_ip = f.dst_endpoint_ip
            AND a.remote_port = f.dst_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            1 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          WHERE f.protocol_num = 17
            AND a.partition = f.partition
            AND a.proto = 17
            AND a.remote_port > 0
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.dst_endpoint_ip
            AND a.remote_ip = f.src_endpoint_ip
            AND a.remote_port = f.src_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          JOIN #{@schema}.ocsf_agents AS ag
            ON ag.uid = a.agent_id
           AND ag.ip IS NOT NULL
           AND ag.ip <> ''
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.local_ip <> ag.ip
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND ag.ip = f.src_endpoint_ip
            AND a.remote_ip = f.dst_endpoint_ip
            AND a.remote_port = f.dst_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          JOIN #{@schema}.ocsf_agents AS ag
            ON ag.uid = a.agent_id
           AND ag.ip IS NOT NULL
           AND ag.ip <> ''
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.local_ip <> ag.ip
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND ag.ip = f.dst_endpoint_ip
            AND a.remote_ip = f.src_endpoint_ip
            AND a.remote_port = f.src_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          JOIN #{@schema}.ocsf_agents AS ag
            ON ag.uid = a.agent_id
           AND ag.ip IS NOT NULL
           AND ag.ip <> ''
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto IN (1, 58)
            AND a.local_ip <> ag.ip
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND ag.ip = f.src_endpoint_ip
            AND a.remote_ip = f.dst_endpoint_ip

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM #{@schema}.#{@table} AS a
          JOIN #{@schema}.ocsf_agents AS ag
            ON ag.uid = a.agent_id
           AND ag.ip IS NOT NULL
           AND ag.ip <> ''
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto IN (1, 58)
            AND a.local_ip <> ag.ip
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND ag.ip = f.dst_endpoint_ip
            AND a.remote_ip = f.src_endpoint_ip
        ) AS ranked
        ORDER BY match_rank, time_delta_seconds, observed_at DESC
        LIMIT 1
      ) AS picked ON true
    )
    UPDATE #{@schema}.ocsf_network_activity AS f
    SET ocsf_payload = f.ocsf_payload
      || jsonb_build_object(
           'event_type', 'attributed_flow',
           'agent_id', candidates.agent_id,
           'attribution', jsonb_strip_nulls(jsonb_build_object(
             'pid', candidates.pid,
             'comm', candidates.comm,
             'redacted_cmdline', candidates.cmdline,
             'uid', candidates.uid,
             'container_id', candidates.container_id
           ))
         )
    FROM candidates
    WHERE f.tableoid = candidates.flow_tableoid
      AND f.ctid = candidates.flow_ctid
    """

    case ServiceRadar.Repo.query(sql, []) do
      {:ok, %{num_rows: num_rows}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete attributions older than the retention window."
  @spec prune() :: {:ok, non_neg_integer()} | {:error, term()}
  def prune do
    sql = """
    DELETE FROM #{@schema}.#{@table}
    WHERE observed_at < now() - ($1::integer * interval '1 minute')
    """

    case ServiceRadar.Repo.query(sql, [retention_minutes()]) do
      {:ok, %{num_rows: num_rows}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns raw attribution staging retention in minutes.

  The value is clamped to the correlation skew so a deployment cannot discard
  observations before delayed NetFlow/IPFIX rows have a chance to match.
  """
  @spec retention_minutes() :: pos_integer()
  def retention_minutes do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retention_minutes, @default_retention_minutes)
    |> normalize_retention_minutes()
  end

  defp normalize_retention_minutes(value) when is_integer(value) do
    max(value, @minimum_retention_minutes)
  end

  defp normalize_retention_minutes(_value), do: @default_retention_minutes

  defp observed_at(%FlowAttributionEvent{observed_at_unix_nano: ns})
       when is_integer(ns) and ns > 0 do
    DateTime.from_unix!(ns, :nanosecond)
  rescue
    _ -> DateTime.utc_now()
  end

  defp observed_at(_event), do: DateTime.utc_now()

  defp zero_to_nil(n) when is_integer(n) and n > 0, do: n
  defp zero_to_nil(_), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp cmdline_to_string(list) when is_list(list), do: list |> Enum.join(" ") |> blank_to_nil()
  defp cmdline_to_string(value) when is_binary(value), do: blank_to_nil(value)
  defp cmdline_to_string(_), do: nil

  # IANA protocol numbers (mirrors AttributedFlowJoiner.transport_to_proto).
  defp transport_to_proto(transport) when is_binary(transport) do
    case String.downcase(transport) do
      "tcp" -> 6
      "udp" -> 17
      "icmp" -> 1
      "icmp6" -> 58
      "icmpv6" -> 58
      "ipv6-icmp" -> 58
      _ -> nil
    end
  end

  defp transport_to_proto(transport) when is_integer(transport), do: transport
  defp transport_to_proto(_), do: nil
end
