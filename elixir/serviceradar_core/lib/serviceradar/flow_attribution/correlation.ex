defmodule ServiceRadar.FlowAttribution.Correlation do
  @moduledoc false

  alias ServiceRadar.FlowAttribution.WorkloadBackfill

  @schema "platform"
  @table "flow_process_attribution_current"
  @workload_identity_table "workload_identity_current"
  @public_endpoints_table "public_endpoints_current"
  @correlation_window_minutes 15
  @correlation_skew_seconds 900

  # Cross-node singleton guard: only the holder of this Postgres advisory lock
  # runs a correlation pass, so concurrent passes on multiple `core` replicas
  # cannot block each other on transaction/tuple locks over the same recent
  # `ocsf_network_activity` rows. Distinct from the coordinator lock (42_600_101).
  @correlator_lock_key 42_600_201

  # Upper bound on flows considered per pass so a single statement cannot grow
  # unbounded with flow volume and exceed the statement timeout (which left the
  # whole window un-attributed). Newest-first so live attribution stays current;
  # remaining backlog is drained over subsequent passes.
  @batch_limit 5_000

  # Statement/transaction timeout for a correlation pass (ms).
  @correlation_timeout_ms 120_000

  @spec correlate() :: {:ok, non_neg_integer()} | {:error, term()}
  def correlate do
    with {:ok, _current_backfills} <- WorkloadBackfill.backfill_current_workload_identity() do
      run_guarded(correlation_sql())
    end
  end

  @doc false
  @spec correlation_sql() :: String.t()
  def correlation_sql do
    # Normalize IPv4-mapped IPv6 (::ffff:a.b.c.d) and lowercase for VIP/backend joins.
    ip_norm_a = "lower(regexp_replace(coalesce(a.local_ip, ''), '^::ffff:', '', 'i'))"
    ip_norm_remote = "lower(regexp_replace(coalesce(a.remote_ip, ''), '^::ffff:', '', 'i'))"
    ip_norm_src = "lower(regexp_replace(coalesce(f.src_endpoint_ip, ''), '^::ffff:', '', 'i'))"
    ip_norm_dst = "lower(regexp_replace(coalesce(f.dst_endpoint_ip, ''), '^::ffff:', '', 'i'))"
    ip_norm_picked = "lower(regexp_replace(coalesce(picked.local_ip, ''), '^::ffff:', '', 'i'))"

    """
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
      ORDER BY f.time DESC
      LIMIT #{@batch_limit}
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
    ),
    public_endpoint_backends AS NOT MATERIALIZED (
      SELECT
        lower(regexp_replace(coalesce(pe.ip, ''), '^::ffff:', '', 'i')) AS vip_ip_norm,
        pe.port AS vip_port,
        CASE upper(coalesce(pe.protocol, 'TCP'))
          WHEN 'TCP' THEN 6
          WHEN 'UDP' THEN 17
          WHEN 'SCTP' THEN 132
          ELSE NULL
        END AS proto_num,
        lower(regexp_replace(coalesce(t->>'ip', ''), '^::ffff:', '', 'i')) AS backend_ip_norm,
        NULLIF(t->>'port', '')::integer AS backend_port,
        CASE lower(coalesce(pe.exposure_class, ''))
          WHEN 'gateway' THEN 0
          WHEN 'loadbalancer' THEN 1
          WHEN 'externalip' THEN 1
          ELSE 2
        END AS exposure_rank,
        jsonb_strip_nulls(jsonb_build_object(
          'cluster_id', pe.cluster_id,
          'exposure_class', pe.exposure_class,
          'namespace', NULLIF(pe.namespace, ''),
          'service_name', NULLIF(pe.service_name, ''),
          'gateway_name', NULLIF(pe.gateway_name, ''),
          'gateway_class', pe.gateway_class,
          'listener_name', NULLIF(pe.listener_name, ''),
          'route_kind', NULLIF(pe.route_kind, ''),
          'route_name', NULLIF(pe.route_name, ''),
          'metallb_pool', pe.metallb_pool,
          'vip_ip', pe.ip,
          'vip_port', pe.port,
          'vip_protocol', pe.protocol,
          'backend_ip', t->>'ip',
          'backend_port', NULLIF(t->>'port', '')::integer,
          'pod_name', t->>'pod_name',
          'pod_namespace', t->>'pod_namespace',
          'node_name', t->>'node_name',
          'endpoint_key', pe.endpoint_key
        )) AS owner
      FROM #{@schema}.#{@public_endpoints_table} AS pe
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(pe.endpoint_targets) = 'array' THEN pe.endpoint_targets
          ELSE '[]'::jsonb
        END
      ) AS t
      WHERE pe.deleted_at IS NULL
        AND pe.ip IS NOT NULL
        AND pe.ip <> ''
        AND coalesce(t->>'ip', '') <> ''
        AND coalesce(t->>'port', '') ~ '^[0-9]+$'
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
        NULLIF(
          COALESCE(workload.identity, '{}'::jsonb) || COALESCE(picked.workload_identity, '{}'::jsonb),
          '{}'::jsonb
        ) AS workload_identity,
        COALESCE(pe_backend.owner, pe_vip.owner) AS public_endpoint
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
          local_ip,
          local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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
            a.local_ip,
            a.local_port,
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

          UNION ALL

          -- Public VIP as destination → process on post-DNAT backend pod socket.
          -- Public matches follow all local strategies (ranks 0..2); the raw
          -- exposure rank keeps Gateway ahead of LoadBalancer/ExternalIP and
          -- both ahead of other public endpoint classes.
          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            a.workload_identity,
            a.local_ip,
            a.local_port,
            3 + pe.exposure_rank AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
          JOIN public_endpoint_backends AS pe
            ON pe.proto_num = a.proto
           AND pe.backend_port = a.local_port
           AND pe.backend_ip_norm = #{ip_norm_a}
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND pe.vip_ip_norm = #{ip_norm_dst}
            AND pe.vip_port = f.dst_endpoint_port
            AND (
              (a.remote_port = 0 AND a.remote_ip IN ('0.0.0.0', '::'))
              OR (
                #{ip_norm_remote} = #{ip_norm_src}
                AND (a.remote_port = f.src_endpoint_port OR a.remote_port = 0)
              )
            )

          UNION ALL

          -- Public VIP as source (reply path) → process on post-DNAT backend.
          SELECT
            a.agent_id,
            a.pid,
            a.comm,
            a.cmdline,
            a.uid,
            a.container_id,
            a.workload_identity,
            a.local_ip,
            a.local_port,
            3 + pe.exposure_rank AS match_rank,
            abs(extract(epoch from (f.time - a.observed_at))) AS time_delta_seconds,
            a.observed_at
          FROM attribution_sources AS a
          JOIN public_endpoint_backends AS pe
            ON pe.proto_num = a.proto
           AND pe.backend_port = a.local_port
           AND pe.backend_ip_norm = #{ip_norm_a}
          WHERE a.partition = f.partition
            AND a.proto = f.protocol_num
            AND a.proto NOT IN (1, 58)
            AND a.observed_at BETWEEN f.time - interval '#{@correlation_skew_seconds} seconds'
                                  AND f.time + interval '#{@correlation_skew_seconds} seconds'
            AND pe.vip_ip_norm = #{ip_norm_src}
            AND pe.vip_port = f.src_endpoint_port
            AND (
              (a.remote_port = 0 AND a.remote_ip IN ('0.0.0.0', '::'))
              OR (
                #{ip_norm_remote} = #{ip_norm_dst}
                AND (a.remote_port = f.dst_endpoint_port OR a.remote_port = 0)
              )
            )
        ) AS ranked
        ORDER BY
          match_rank,
          -- Prefer container-scoped socket owners over host-only dual emits
          -- (e.g. beam/anubis with container_id over k3s-agent without).
          (container_id IS NULL) ASC,
          time_delta_seconds,
          observed_at DESC
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
      ) AS workload ON picked.container_id IS NOT NULL
      LEFT JOIN LATERAL (
        -- Prefer owner whose backend matches the attributed process socket.
        SELECT pe.owner
        FROM public_endpoint_backends AS pe
        WHERE pe.proto_num = f.protocol_num
          AND pe.backend_ip_norm = #{ip_norm_picked}
          AND pe.backend_port = picked.local_port
          AND (
            (pe.vip_ip_norm = #{ip_norm_dst} AND pe.vip_port = f.dst_endpoint_port)
            OR (pe.vip_ip_norm = #{ip_norm_src} AND pe.vip_port = f.src_endpoint_port)
          )
        ORDER BY pe.exposure_rank
        LIMIT 1
      ) AS pe_backend ON true
      LEFT JOIN LATERAL (
        -- Fallback: any live owner for the public VIP:port on the flow.
        SELECT pe.owner
        FROM public_endpoint_backends AS pe
        WHERE pe.proto_num = f.protocol_num
          AND (
            (pe.vip_ip_norm = #{ip_norm_dst} AND pe.vip_port = f.dst_endpoint_port)
            OR (pe.vip_ip_norm = #{ip_norm_src} AND pe.vip_port = f.src_endpoint_port)
          )
        ORDER BY pe.exposure_rank
        LIMIT 1
      ) AS pe_vip ON pe_backend.owner IS NULL
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
               'workload_identity', candidates.workload_identity,
               'public_endpoint', candidates.public_endpoint
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
        NULLIF(
          COALESCE(wi.identity, '{}'::jsonb) ||
            COALESCE(f.ocsf_payload #> '{attribution,workload_identity}', '{}'::jsonb),
          '{}'::jsonb
        ),
        true
      )
      FROM #{@schema}.#{@workload_identity_table} AS wi
      WHERE f.time > now() - interval '#{@correlation_window_minutes} minutes'
        AND (f.ocsf_payload ->> 'event_type') = 'attributed_flow'
        AND (f.ocsf_payload #>> '{attribution,container_id}') = wi.container_id
        AND (f.ocsf_payload ->> 'agent_id') = wi.agent_id
        AND f.partition = wi.partition
        AND (
          (f.ocsf_payload #> '{attribution,workload_identity}') IS NULL
          OR NOT ((f.ocsf_payload #> '{attribution,workload_identity}') ? 'context_name')
        )
        AND COALESCE(f.ocsf_payload #> '{attribution,workload_identity}', '{}'::jsonb) <>
          (
            COALESCE(wi.identity, '{}'::jsonb) ||
              COALESCE(f.ocsf_payload #> '{attribution,workload_identity}', '{}'::jsonb)
          )
      RETURNING 1
    ),
    public_endpoint_backfills AS (
      -- Stamp VIP ownership onto already-attributed flows that lack it
      -- (e.g. matched before inventory existed, or via a non-VIP path).
      UPDATE #{@schema}.ocsf_network_activity AS f
      SET ocsf_payload = jsonb_set(
        f.ocsf_payload,
        '{attribution,public_endpoint}',
        pe.owner,
        true
      )
      FROM (
        SELECT DISTINCT ON (vip_ip_norm, vip_port, proto_num)
          vip_ip_norm,
          vip_port,
          proto_num,
          owner
        FROM public_endpoint_backends
        ORDER BY vip_ip_norm, vip_port, proto_num, exposure_rank
      ) AS pe
      WHERE f.time > now() - interval '#{@correlation_window_minutes} minutes'
        AND (f.ocsf_payload ->> 'event_type') = 'attributed_flow'
        AND (f.ocsf_payload #> '{attribution,public_endpoint}') IS NULL
        AND pe.proto_num = f.protocol_num
        AND (
          (
            pe.vip_ip_norm = lower(regexp_replace(coalesce(f.dst_endpoint_ip, ''), '^::ffff:', '', 'i'))
            AND pe.vip_port = f.dst_endpoint_port
          )
          OR (
            pe.vip_ip_norm = lower(regexp_replace(coalesce(f.src_endpoint_ip, ''), '^::ffff:', '', 'i'))
            AND pe.vip_port = f.src_endpoint_port
          )
        )
      RETURNING 1
    )
    SELECT
      (SELECT count(*) FROM stamped) +
      (SELECT count(*) FROM workload_backfills) +
      (SELECT count(*) FROM public_endpoint_backfills) AS affected_rows
    """
  end

  # Runs the correlation statement under a Postgres transaction-scoped advisory
  # lock so only one `core` node executes a pass at a time. The lock is released
  # automatically at transaction end (commit/rollback/disconnect), so a crashed
  # node never strands the lock. If another node already holds it, this pass is a
  # no-op (returns 0) rather than blocking.
  defp run_guarded(sql) do
    ServiceRadar.Repo.transaction(
      fn ->
        case ServiceRadar.Repo.query("SELECT pg_try_advisory_xact_lock($1)", [
               @correlator_lock_key
             ]) do
          {:ok, %{rows: [[true]]}} ->
            case ServiceRadar.Repo.query(sql, [], timeout: @correlation_timeout_ms) do
              {:ok, %{rows: [[num_rows]]}} -> num_rows
              {:error, reason} -> ServiceRadar.Repo.rollback(reason)
            end

          {:ok, %{rows: [[false]]}} ->
            0

          {:error, reason} ->
            ServiceRadar.Repo.rollback(reason)
        end
      end,
      timeout: @correlation_timeout_ms
    )
  end
end
