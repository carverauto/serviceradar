defmodule ServiceRadar.Observability.ThreatIntelRetrohuntWorker do
  @moduledoc """
  Operator-triggered retroactive hunts for imported OTX indicators.

  The first supported path matches active OTX CIDR indicators against retained
  canonical NetFlow source and destination IPs. Domain/DNS matching remains a
  later slice once the canonical DNS aggregate source is selected.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [
      period: 900,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing]
    ]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_source "alienvault_otx"
  @default_window_seconds 7_776_000
  @default_max_indicators 5_000

  @doc """
  Enqueue a manual OTX retrohunt.
  """
  @spec enqueue_manual(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_manual(opts \\ []) do
    if ObanSupport.available?() do
      args =
        %{
          "source" => Keyword.get(opts, :source, @default_source),
          "triggered_by" => Keyword.get(opts, :triggered_by, "manual")
        }
        |> maybe_put("window_seconds", Keyword.get(opts, :window_seconds))
        |> maybe_put("max_indicators", Keyword.get(opts, :max_indicators))

      args
      |> new(schedule_in: Keyword.get(opts, :schedule_in, 1))
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    started_at = System.monotonic_time()
    actor = SystemActor.system(:threat_intel_retrohunt_worker)
    settings = load_settings(actor)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    source = normalize_source(Map.get(args, "source"))

    window_seconds =
      normalize_positive_int(Map.get(args, "window_seconds"), settings_window(settings))

    max_indicators =
      normalize_positive_int(Map.get(args, "max_indicators"), settings_limit(settings))

    window_start = DateTime.add(now, -window_seconds, :second)
    triggered_by = normalize_trigger(Map.get(args, "triggered_by"))

    with {:ok, run_id} <- create_run(source, triggered_by, window_start, now),
         {:ok, result} <- run_netflow_match(run_id, source, window_start, now, max_indicators),
         unsupported_count = latest_unsupported_count(source),
         :ok <- finish_run(run_id, "ok", result, unsupported_count, nil) do
      emit_event(:stop, started_at, source, result, unsupported_count)

      Logger.info("OTX retrohunt completed",
        source: source,
        indicators_evaluated: result.indicators_evaluated,
        findings_count: result.findings_count,
        unsupported_count: unsupported_count
      )

      :ok
    else
      {:error, %{run_id: run_id, reason: reason}} ->
        finish_run(run_id, "error", empty_result(), 0, format_reason(reason))
        emit_event(:exception, started_at, source, empty_result(), 0)
        Logger.warning("OTX retrohunt failed", reason: format_reason(reason))
        {:error, reason}

      {:error, reason} ->
        emit_event(:exception, started_at, source, empty_result(), 0)
        Logger.warning("OTX retrohunt failed", reason: format_reason(reason))
        {:error, reason}
    end
  end

  defp load_settings(actor) do
    case NetflowSettings.get_settings(actor: actor) do
      {:ok, %NetflowSettings{} = settings} -> settings
      _ -> %NetflowSettings{}
    end
  rescue
    error ->
      Logger.debug("OTX retrohunt settings unavailable", reason: inspect(error))
      %NetflowSettings{}
  end

  defp create_run(source, triggered_by, window_start, window_end) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    sql = """
    INSERT INTO platform.otx_retrohunt_runs (
      source,
      triggered_by,
      status,
      window_start,
      window_end,
      started_at,
      metadata,
      inserted_at,
      updated_at
    )
    VALUES ($1, $2, 'running', $3, $4, $5, '{}'::jsonb, $5, $5)
    RETURNING id::text
    """

    case SQL.query(Repo, sql, [source, triggered_by, window_start, window_end, now]) do
      {:ok, %Postgrex.Result{rows: [[id]]}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_netflow_match(run_id, source, window_start, window_end, max_indicators) do
    sql = """
    WITH indicator_cutoff AS (
      SELECT last_seen_at
      FROM platform.threat_intel_indicators
      WHERE source = $3
        AND indicator_type IN ('cidr', 'ipv4', 'ipv6')
        AND (expires_at IS NULL OR expires_at > now())
      ORDER BY last_seen_at DESC
      OFFSET GREATEST($4::int - 1, 0)
      LIMIT 1
    ),
    selected_indicator_count AS (
      SELECT COUNT(*)::int AS count
      FROM platform.threat_intel_indicators ti
      WHERE ti.source = $3
        AND ti.indicator_type IN ('cidr', 'ipv4', 'ipv6')
        AND (ti.expires_at IS NULL OR ti.expires_at > now())
        AND ti.last_seen_at >= COALESCE(
          (SELECT last_seen_at FROM indicator_cutoff),
          '-infinity'::timestamptz
        )
    ),
    observed_source_ips AS (
      SELECT
        NULLIF(m.src_endpoint_ip, '')::inet AS observed_ip,
        'source'::text AS direction,
        MIN(m.time) AS first_seen_at,
        MAX(m.time) AS last_seen_at,
        COUNT(*)::int AS evidence_count,
        COALESCE(SUM(m.bytes_total), 0)::bigint AS bytes_total,
        COALESCE(SUM(m.packets_total), 0)::bigint AS packets_total
      FROM platform.ocsf_network_activity m
      WHERE m.time >= $1
        AND m.time <= $2
        AND NULLIF(m.src_endpoint_ip, '') IS NOT NULL
      GROUP BY NULLIF(m.src_endpoint_ip, '')::inet
    ),
    observed_destination_ips AS (
      SELECT
        NULLIF(m.dst_endpoint_ip, '')::inet AS observed_ip,
        'destination'::text AS direction,
        MIN(m.time) AS first_seen_at,
        MAX(m.time) AS last_seen_at,
        COUNT(*)::int AS evidence_count,
        COALESCE(SUM(m.bytes_total), 0)::bigint AS bytes_total,
        COALESCE(SUM(m.packets_total), 0)::bigint AS packets_total
      FROM platform.ocsf_network_activity m
      WHERE m.time >= $1
        AND m.time <= $2
        AND NULLIF(m.dst_endpoint_ip, '') IS NOT NULL
      GROUP BY NULLIF(m.dst_endpoint_ip, '')::inet
    ),
    observed_ips AS (
      SELECT * FROM observed_source_ips
      UNION ALL
      SELECT * FROM observed_destination_ips
    ),
    matches AS (
      SELECT
        i.id AS indicator_id,
        i.indicator,
        i.indicator_type,
        i.source,
        i.label,
        i.severity,
        i.confidence,
        observed.observed_ip,
        observed.direction,
        observed.first_seen_at,
        observed.last_seen_at,
        observed.evidence_count,
        observed.bytes_total,
        observed.packets_total
      FROM observed_ips observed
      JOIN LATERAL (
        SELECT
          ti.id,
          ti.indicator,
          ti.indicator_type,
          ti.source,
          ti.label,
          ti.severity,
          ti.confidence
        FROM platform.threat_intel_indicators ti
        WHERE ti.source = $3
          AND ti.indicator_type IN ('cidr', 'ipv4', 'ipv6')
          AND (ti.expires_at IS NULL OR ti.expires_at > now())
          AND ti.last_seen_at >= COALESCE(
            (SELECT last_seen_at FROM indicator_cutoff),
            '-infinity'::timestamptz
          )
          AND ti.indicator >>= observed.observed_ip
      ) i ON true
    ),
    upserted AS (
      INSERT INTO platform.otx_retrohunt_findings (
        run_id,
        indicator_id,
        source,
        indicator,
        indicator_type,
        label,
        severity,
        confidence,
        observed_ip,
        direction,
        first_seen_at,
        last_seen_at,
        evidence_count,
        bytes_total,
        packets_total,
        metadata,
        inserted_at,
        updated_at
      )
      SELECT
        ($5::text)::uuid,
        indicator_id,
        source,
        indicator,
        indicator_type,
        label,
        severity,
        confidence,
        observed_ip,
        direction,
        first_seen_at,
        last_seen_at,
        evidence_count,
        bytes_total,
        packets_total,
        jsonb_build_object(
          'window_start', $1::text,
          'window_end', $2::text,
          'matcher', 'ocsf_network_activity'
        ),
        now(),
        now()
      FROM matches
      ON CONFLICT (source, indicator, observed_ip, direction, first_seen_at, last_seen_at)
      DO UPDATE SET
        run_id = EXCLUDED.run_id,
        evidence_count = EXCLUDED.evidence_count,
        bytes_total = EXCLUDED.bytes_total,
        packets_total = EXCLUDED.packets_total,
        metadata = EXCLUDED.metadata,
        updated_at = now()
      RETURNING id
    )
    SELECT
      (SELECT count FROM selected_indicator_count) AS indicators_evaluated,
      (SELECT COUNT(*)::int FROM upserted) AS findings_count
    """

    case SQL.query(
           Repo,
           sql,
           [window_start, window_end, source, max_indicators, run_id],
           timeout: 120_000
         ) do
      {:ok, %Postgrex.Result{rows: [[indicators_evaluated, findings_count]]}} ->
        {:ok, %{indicators_evaluated: indicators_evaluated, findings_count: findings_count}}

      {:error, reason} ->
        {:error, %{run_id: run_id, reason: reason}}
    end
  end

  defp latest_unsupported_count(source) do
    sql = """
    SELECT COALESCE(SUM(value::int), 0)::int
    FROM (
      SELECT metadata
      FROM platform.threat_intel_sync_statuses
      WHERE source = $1
      ORDER BY last_attempt_at DESC
      LIMIT 1
    ) status,
    jsonb_each_text(COALESCE(status.metadata->'skipped_by_type', '{}'::jsonb))
    """

    case SQL.query(Repo, sql, [source]) do
      {:ok, %Postgrex.Result{rows: [[count]]}} -> count || 0
      _ -> 0
    end
  end

  defp finish_run(run_id, status, result, unsupported_count, error) do
    sql = """
    UPDATE platform.otx_retrohunt_runs
    SET
      status = $2,
      finished_at = $3,
      indicators_evaluated = $4,
      findings_count = $5,
      unsupported_count = $6,
      error = $7,
      updated_at = $3
    WHERE id = ($1::text)::uuid
    """

    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    case SQL.query(Repo, sql, [
           run_id,
           status,
           now,
           result.indicators_evaluated,
           result.findings_count,
           unsupported_count,
           error
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_event(kind, started_at, source, result, unsupported_count) do
    :telemetry.execute(
      [:serviceradar, :threat_intel, :retrohunt, kind],
      %{duration: System.monotonic_time() - started_at},
      %{
        source: source,
        indicators_evaluated: result.indicators_evaluated,
        findings_count: result.findings_count,
        unsupported_count: unsupported_count
      }
    )
  end

  defp empty_result, do: %{indicators_evaluated: 0, findings_count: 0}

  defp settings_window(%NetflowSettings{otx_retrohunt_window_seconds: seconds}) do
    normalize_positive_int(seconds, @default_window_seconds)
  end

  defp settings_window(_settings), do: @default_window_seconds

  defp settings_limit(%NetflowSettings{otx_max_indicators: limit}) do
    normalize_positive_int(limit, @default_max_indicators)
  end

  defp settings_limit(_settings), do: @default_max_indicators

  defp normalize_source(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @default_source
      source -> source
    end
  end

  defp normalize_source(_value), do: @default_source

  defp normalize_trigger(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "manual"
      trigger -> trigger
    end
  end

  defp normalize_trigger(_value), do: "manual"

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_int(_value, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
