defmodule ServiceRadar.FlowAttribution do
  @moduledoc """
  Persists netprobe process attributions (5-tuple -> process) pushed by agents,
  and correlates them against collected NetFlow/sFlow in `ocsf_network_activity`.

  NetFlow remains the authoritative flow source — netprobe only supplies the WHO.
  `persist/3` upserts pushed `FlowAttributionEvent` rows into the current-state
  attribution table; `correlate/0` joins recent attributions against recent NetFlow (either direction)
  and stamps matching flows with `event_type=attributed_flow` + the process context,
  which the web UI (`/observability/flows/attributed`) reads. Workload identity
  is joined from the standalone workload-identity current-state table when
  netprobe only supplies a container ID.
  """

  alias Netprobepb.FlowAttributionEvent

  require Logger

  @schema "platform"
  @table "flow_process_attribution_current"
  @legacy_table "flow_process_attributions"
  @workload_identity_table "workload_identity_current"
  @correlation_window_minutes 15
  @correlation_skew_seconds 900
  @default_retention_minutes 60
  @minimum_retention_minutes div(@correlation_skew_seconds + 59, 60)
  @history_coalesce_seconds 30

  @upsert_sql """
  INSERT INTO #{@schema}.#{@table} (
    observed_at,
    inserted_at,
    updated_at,
    partition,
    attribution_key,
    agent_id,
    proto,
    local_ip,
    local_port,
    remote_ip,
    remote_port,
    pid,
    comm,
    cmdline,
    uid,
    container_id,
    workload_identity
  )
  SELECT
    r.observed_at::timestamptz,
    now(),
    now(),
    r.partition,
    r.attribution_key,
    r.agent_id,
    r.proto,
    r.local_ip,
    r.local_port,
    r.remote_ip,
    r.remote_port,
    r.pid,
    r.comm,
    r.cmdline,
    r.uid,
    r.container_id,
    r.workload_identity
  FROM jsonb_to_recordset(($1::text)::jsonb) AS r(
    observed_at text,
    partition text,
    attribution_key text,
    agent_id text,
    proto integer,
    local_ip text,
    local_port integer,
    remote_ip text,
    remote_port integer,
    pid integer,
    comm text,
    cmdline text,
    uid integer,
    container_id text,
    workload_identity jsonb
  )
  ON CONFLICT (partition, attribution_key) DO UPDATE SET
    observed_at = GREATEST(#{@table}.observed_at, EXCLUDED.observed_at),
    updated_at = now(),
    cmdline = COALESCE(EXCLUDED.cmdline, #{@table}.cmdline),
    uid = COALESCE(EXCLUDED.uid, #{@table}.uid),
    container_id = COALESCE(EXCLUDED.container_id, #{@table}.container_id),
    workload_identity = COALESCE(EXCLUDED.workload_identity, #{@table}.workload_identity)
  """

  @legacy_insert_sql """
  WITH input_rows AS (
    SELECT
      r.observed_at::timestamptz AS observed_at,
      r.partition,
      r.attribution_key,
      r.agent_id,
      r.proto,
      r.local_ip,
      r.local_port,
      r.remote_ip,
      r.remote_port,
      r.pid,
      r.comm,
      r.cmdline,
      r.uid,
      r.container_id,
      r.workload_identity,
      floor(extract(epoch from r.observed_at::timestamptz) / #{@history_coalesce_seconds}) AS coalesce_bucket
    FROM jsonb_to_recordset(($1::text)::jsonb) AS r(
      observed_at text,
      partition text,
      attribution_key text,
      agent_id text,
      proto integer,
      local_ip text,
      local_port integer,
      remote_ip text,
      remote_port integer,
      pid integer,
      comm text,
      cmdline text,
      uid integer,
      container_id text,
      workload_identity jsonb
    )
  ),
  deduped AS (
    SELECT DISTINCT ON (partition, attribution_key, coalesce_bucket)
      observed_at,
      partition,
      agent_id,
      proto,
      local_ip,
      local_port,
      remote_ip,
      remote_port,
      pid,
      comm,
      cmdline,
      uid,
      container_id,
      workload_identity,
      coalesce_bucket
    FROM input_rows
    ORDER BY partition, attribution_key, coalesce_bucket, observed_at DESC
  )
  INSERT INTO #{@schema}.#{@legacy_table} (
    observed_at,
    partition,
    agent_id,
    proto,
    local_ip,
    local_port,
    remote_ip,
    remote_port,
    pid,
    comm,
    cmdline,
    uid,
    container_id,
    workload_identity
  )
  SELECT
    d.observed_at,
    d.partition,
    d.agent_id,
    d.proto,
    d.local_ip,
    d.local_port,
    d.remote_ip,
    d.remote_port,
    d.pid,
    d.comm,
    d.cmdline,
    d.uid,
    d.container_id,
    d.workload_identity
  FROM deduped AS d
  WHERE NOT EXISTS (
    SELECT 1
    FROM #{@schema}.#{@legacy_table} AS existing
    WHERE existing.partition = d.partition
      AND existing.agent_id IS NOT DISTINCT FROM d.agent_id
      AND existing.proto = d.proto
      AND existing.local_ip = d.local_ip
      AND existing.local_port = d.local_port
      AND existing.remote_ip = d.remote_ip
      AND existing.remote_port = d.remote_port
      AND existing.pid IS NOT DISTINCT FROM d.pid
      AND existing.uid IS NOT DISTINCT FROM d.uid
      AND existing.container_id IS NOT DISTINCT FROM d.container_id
      AND existing.comm IS NOT DISTINCT FROM d.comm
      AND existing.observed_at >= d.observed_at - interval '#{@history_coalesce_seconds} seconds'
      AND existing.observed_at < d.observed_at + interval '#{@history_coalesce_seconds} seconds'
  )
  """

  @doc "Persist a batch of pushed attribution events."
  @spec persist([FlowAttributionEvent.t()], String.t() | nil, String.t() | nil) :: :ok
  def persist(events, partition_id, agent_id) when is_list(events) do
    rows =
      events
      |> Enum.map(&row_from_event(&1, partition_id, agent_id))
      |> Enum.reject(&is_nil/1)

    if rows != [] do
      insert_legacy_rows(rows)
      insert_current_rows(rows)
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
      put_attribution_key(%{
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
        container_id: blank_to_nil(event.container_id),
        workload_identity: workload_identity_to_map(event.workload_identity)
      })
    else
      _ -> nil
    end
  end

  defp row_from_event(_event, _partition_id, _agent_id), do: nil

  defp insert_current_rows(rows) do
    rows =
      rows
      |> dedupe_current_rows()
      |> Enum.map(fn row ->
        Map.update!(row, :observed_at, &DateTime.to_iso8601/1)
      end)

    ServiceRadar.Repo.query!(@upsert_sql, [Jason.encode!(rows)])
  end

  defp insert_legacy_rows(rows) do
    rows =
      rows
      |> dedupe_history_rows()
      |> Enum.map(fn row ->
        Map.update!(row, :observed_at, &DateTime.to_iso8601/1)
      end)

    if rows != [] do
      ServiceRadar.Repo.query!(@legacy_insert_sql, [Jason.encode!(rows)])
    end
  end

  defp dedupe_current_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      key = {Map.fetch!(row, :partition), Map.fetch!(row, :attribution_key)}

      Map.update(acc, key, row, fn current ->
        if DateTime.after?(Map.fetch!(row, :observed_at), Map.fetch!(current, :observed_at)) do
          row
        else
          current
        end
      end)
    end)
    |> Map.values()
  end

  defp dedupe_history_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      bucket =
        row
        |> Map.fetch!(:observed_at)
        |> DateTime.to_unix()
        |> div(@history_coalesce_seconds)

      key = {Map.fetch!(row, :partition), Map.fetch!(row, :attribution_key), bucket}

      Map.update(acc, key, row, fn current ->
        if DateTime.after?(Map.fetch!(row, :observed_at), Map.fetch!(current, :observed_at)) do
          row
        else
          current
        end
      end)
    end)
    |> Map.values()
  end

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
    attribution_sources AS NOT MATERIALIZED (
      SELECT
        observed_at,
        partition,
        agent_id,
        proto,
        local_ip,
        local_port,
        remote_ip,
        remote_port,
        pid,
        comm,
        cmdline,
        uid,
        container_id,
        workload_identity
      FROM #{@schema}.#{@table}
      WHERE observed_at > now() - interval '#{@correlation_window_minutes * 60 + @correlation_skew_seconds} seconds'

      UNION ALL

      SELECT
        observed_at,
        partition,
        agent_id,
        proto,
        local_ip,
        local_port,
        remote_ip,
        remote_port,
        pid,
        comm,
        cmdline,
        uid,
        container_id,
        workload_identity
      FROM #{@schema}.#{@legacy_table}
      WHERE observed_at > now() - interval '#{@correlation_window_minutes * 60 + @correlation_skew_seconds} seconds'
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
        picked.container_id,
        COALESCE(picked.workload_identity, workload.identity) AS workload_identity
      FROM recent_flows AS f
      JOIN LATERAL (
        SELECT
          agent_id,
          pid,
          comm,
          cmdline,
          uid,
          container_id,
          workload_identity,
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
            a.workload_identity,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            1 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.remote_port = 0
            AND a.remote_ip IN ('0.0.0.0', '::')
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.src_endpoint_ip
            AND a.local_port = f.src_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            a.workload_identity,
            1 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.remote_port = 0
            AND a.remote_ip IN ('0.0.0.0', '::')
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND a.local_ip = f.dst_endpoint_ip
            AND a.local_port = f.dst_endpoint_port

          UNION ALL

          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            a.workload_identity,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            0 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            1 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            1 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
            a.workload_identity,
            2 AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
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
      LEFT JOIN LATERAL (
        SELECT wi.identity
        FROM #{@schema}.#{@workload_identity_table} AS wi
        WHERE wi.partition = f.partition
          AND wi.agent_id = picked.agent_id
          AND wi.container_id = picked.container_id
        ORDER BY wi.observed_at DESC
        LIMIT 1
      ) AS workload ON picked.workload_identity IS NULL
        AND picked.container_id IS NOT NULL
    ),
    stamped AS (
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
               'container_id', candidates.container_id,
               'workload_identity', candidates.workload_identity
             ))
           )
      FROM candidates
      WHERE f.tableoid = candidates.flow_tableoid
        AND f.ctid = candidates.flow_ctid
      RETURNING 1
    ),
    workload_backfills AS (
      UPDATE #{@schema}.ocsf_network_activity AS f
      SET ocsf_payload = jsonb_set(
        f.ocsf_payload,
        '{attribution,workload_identity}',
        wi.identity,
        true
      )
      FROM #{@schema}.#{@workload_identity_table} AS wi
      WHERE f.time > now() - interval '#{@correlation_window_minutes} minutes'
        AND (f.ocsf_payload ->> 'event_type') = 'attributed_flow'
        AND (f.ocsf_payload #> '{attribution,workload_identity}') IS NULL
        AND (f.ocsf_payload #>> '{attribution,container_id}') = wi.container_id
        AND (f.ocsf_payload ->> 'agent_id') = wi.agent_id
        AND f.partition = wi.partition
      RETURNING 1
    )
    SELECT
      (SELECT count(*) FROM stamped) +
      (SELECT count(*) FROM workload_backfills) AS affected_rows
    """

    case ServiceRadar.Repo.query(sql, []) do
      {:ok, %{rows: [[num_rows]]}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete attributions older than the retention window."
  @spec prune() :: {:ok, non_neg_integer()} | {:error, term()}
  def prune do
    sql = """
    WITH deleted_current AS (
      DELETE FROM #{@schema}.#{@table}
      WHERE observed_at < now() - ($1::integer * interval '1 minute')
      RETURNING 1
    ),
    deleted_legacy AS (
      DELETE FROM #{@schema}.#{@legacy_table}
      WHERE observed_at < now() - ($1::integer * interval '1 minute')
      RETURNING 1
    )
    SELECT
      (SELECT count(*) FROM deleted_current) +
      (SELECT count(*) FROM deleted_legacy) AS deleted_count
    """

    case ServiceRadar.Repo.query(sql, [retention_minutes()]) do
      {:ok, %{rows: [[num_rows]]}} -> {:ok, num_rows}
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

  defp workload_identity_to_map(nil), do: nil

  defp workload_identity_to_map(identity) do
    %{
      "pod_sandbox_id" => blank_to_nil(Map.get(identity, :pod_sandbox_id)),
      "pod_name" => blank_to_nil(Map.get(identity, :pod_name)),
      "pod_namespace" => blank_to_nil(Map.get(identity, :pod_namespace)),
      "pod_uid" => blank_to_nil(Map.get(identity, :pod_uid)),
      "container_id" => blank_to_nil(Map.get(identity, :container_id)),
      "container_name" => blank_to_nil(Map.get(identity, :container_name)),
      "image" => blank_to_nil(Map.get(identity, :image)),
      "image_ref" => blank_to_nil(Map.get(identity, :image_ref)),
      "runtime_pid" => zero_to_nil(Map.get(identity, :runtime_pid)),
      "cgroup_path" => blank_to_nil(Map.get(identity, :cgroup_path)),
      "runtime_source" => blank_to_nil(Map.get(identity, :runtime_source)),
      "confidence" => blank_to_nil(Map.get(identity, :confidence)),
      "degradation_reason" => blank_to_nil(Map.get(identity, :degradation_reason)),
      "labels" => empty_map_to_nil(Map.get(identity, :labels)),
      "annotations" => empty_map_to_nil(Map.get(identity, :annotations))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> empty_map_to_nil()
  end

  defp empty_map_to_nil(value) when value == %{}, do: nil
  defp empty_map_to_nil(value) when is_map(value), do: value
  defp empty_map_to_nil(_value), do: nil

  defp put_attribution_key(row) do
    key_parts = [
      Map.get(row, :agent_id),
      Map.fetch!(row, :proto),
      Map.fetch!(row, :local_ip),
      Map.fetch!(row, :local_port),
      Map.fetch!(row, :remote_ip),
      Map.fetch!(row, :remote_port),
      Map.get(row, :pid),
      Map.get(row, :uid),
      Map.get(row, :container_id),
      Map.get(row, :comm)
    ]

    Map.put(row, :attribution_key, attribution_key(key_parts))
  end

  defp attribution_key(parts) do
    parts
    |> Enum.map_join(<<31>>, &key_part/1)
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  defp key_part(nil), do: ""
  defp key_part(value), do: to_string(value)

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
