defmodule ServiceRadar.Observability.ThreatIntelRetrohuntWorker do
  @moduledoc """
  Operator-triggered retroactive hunts for imported OTX indicators.

  The first supported path matches active OTX CIDR indicators against retained
  canonical NetFlow source and destination IPs. Domain/DNS matching remains a
  later slice once the canonical DNS aggregate source is selected.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 900,
      fields: [:worker, :args],
      states: :incomplete
    ]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_source "alienvault_otx"
  @default_window_seconds 7_776_000
  @default_batch_size 500
  @max_batch_size 5_000
  @default_max_batches_per_job 10
  @max_batches_per_job 100

  @doc """
  Enqueue a manual OTX retrohunt.
  """
  @spec enqueue_manual(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_manual(opts \\ []) do
    if ObanSupport.available?() do
      args =
        maybe_put(
          %{
            "source" => Keyword.get(opts, :source, @default_source),
            "triggered_by" => Keyword.get(opts, :triggered_by, "manual")
          },
          "window_seconds",
          Keyword.get(opts, :window_seconds)
        )

      args
      |> new(schedule_in: Keyword.get(opts, :schedule_in, 1))
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args = args || %{}
    started_at = System.monotonic_time()
    actor = SystemActor.system(:threat_intel_retrohunt_worker)
    settings = load_settings(actor)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    source = normalize_source(Map.get(args, "source"))

    window_seconds =
      normalize_positive_int(Map.get(args, "window_seconds"), settings_window(settings))

    window_start = DateTime.add(now, -window_seconds, :second)
    triggered_by = normalize_trigger(Map.get(args, "triggered_by"))

    with {:ok, state} <-
           load_or_create_state(args, source, triggered_by, window_start, now),
         {:ok, outcome, state} <-
           run_batches(state, batch_size(), max_batches_per_job()) do
      case outcome do
        :complete ->
          result = result_from_state(state)
          unsupported_count = latest_unsupported_count(source)

          with :ok <- finish_run(state.run_id, "ok", result, unsupported_count, nil) do
            emit_event(:stop, started_at, source, result, unsupported_count)

            Logger.info("OTX retrohunt completed",
              source: source,
              indicators_evaluated: result.indicators_evaluated,
              findings_count: result.findings_count,
              unsupported_count: unsupported_count,
              batches_completed: state.batches_completed
            )

            :ok
          end

        :continued ->
          Logger.info("OTX retrohunt continuation queued",
            source: source,
            indicators_evaluated: state.indicators_evaluated,
            findings_count: state.findings_count,
            batches_completed: state.batches_completed,
            cursor: state.cursor
          )

          :ok
      end
    else
      {:error, %{run_id: run_id, reason: reason}} ->
        fail_run(run_id, format_reason(reason))
        emit_event(:exception, started_at, source, empty_result(), 0)
        Logger.warning("OTX retrohunt failed", reason: format_reason(reason))
        {:error, reason}

      {:error, reason} ->
        emit_event(:exception, started_at, source, empty_result(), 0)
        Logger.warning("OTX retrohunt failed", reason: format_reason(reason))
        {:error, reason}
    end
  end

  defp load_or_create_state(args, source, triggered_by, window_start, window_end) do
    case Map.get(args, "run_id") do
      run_id when is_binary(run_id) and run_id != "" ->
        with {:ok, persisted_window_start} <- parse_datetime(Map.get(args, "window_start")),
             {:ok, persisted_window_end} <- parse_datetime(Map.get(args, "window_end")) do
          {:ok,
           %{
             run_id: run_id,
             source: source,
             triggered_by: triggered_by,
             window_start: persisted_window_start,
             window_end: persisted_window_end,
             cursor: normalize_cursor(Map.get(args, "cursor")),
             indicators_evaluated:
               normalize_non_negative_int(Map.get(args, "indicators_evaluated")),
             findings_count: normalize_non_negative_int(Map.get(args, "findings_count")),
             batches_completed: normalize_non_negative_int(Map.get(args, "batches_completed"))
           }}
        else
          {:error, reason} -> {:error, %{run_id: run_id, reason: reason}}
        end

      _ ->
        case create_run(source, triggered_by, window_start, window_end) do
          {:ok, run_id} ->
            {:ok,
             %{
               run_id: run_id,
               source: source,
               triggered_by: triggered_by,
               window_start: window_start,
               window_end: window_end,
               cursor: nil,
               indicators_evaluated: 0,
               findings_count: 0,
               batches_completed: 0
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp run_batches(state, batch_size, remaining_batches) when remaining_batches > 0 do
    with {:ok, batch} <- run_netflow_match_batch(state, batch_size),
         next_state = advance_state(state, batch),
         :ok <- persist_run_progress(next_state, batch, batch_size) do
      emit_batch_event(next_state, batch, batch_size)

      cond do
        batch.complete? ->
          {:ok, :complete, next_state}

        remaining_batches > 1 ->
          run_batches(next_state, batch_size, remaining_batches - 1)

        true ->
          case enqueue_continuation(next_state) do
            :ok -> {:ok, :continued, next_state}
            {:error, reason} -> {:error, %{run_id: state.run_id, reason: reason}}
          end
      end
    end
  end

  defp advance_state(state, batch) do
    %{
      state
      | cursor: batch.next_cursor || state.cursor,
        indicators_evaluated: state.indicators_evaluated + batch.indicators_evaluated,
        findings_count: state.findings_count + batch.findings_count,
        batches_completed: state.batches_completed + 1
    }
  end

  defp result_from_state(state) do
    %{
      indicators_evaluated: state.indicators_evaluated,
      findings_count: state.findings_count
    }
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

  defp run_netflow_match_batch(state, batch_size) do
    sql = """
    WITH indicator_candidates AS (
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
        AND ($4::text IS NULL OR ti.id > ($4::text)::uuid)
      ORDER BY ti.id ASC
      LIMIT ($5::int + 1)
    ),
    selected_indicators AS (
      SELECT *
      FROM indicator_candidates
      ORDER BY id ASC
      LIMIT $5
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
      JOIN selected_indicators i ON i.indicator >>= observed.observed_ip
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
        ($6::text)::uuid,
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
      (SELECT COUNT(*)::int FROM selected_indicators) AS indicators_evaluated,
      (SELECT COUNT(*)::int FROM upserted) AS findings_count,
      (
        SELECT id::text
        FROM selected_indicators
        ORDER BY id DESC
        LIMIT 1
      ) AS next_cursor,
      EXISTS(SELECT 1 FROM indicator_candidates OFFSET $5 LIMIT 1) AS has_more
    """

    case SQL.query(
           Repo,
           sql,
           [
             state.window_start,
             state.window_end,
             state.source,
             state.cursor,
             batch_size,
             state.run_id
           ],
           timeout: 120_000
         ) do
      {:ok,
       %Postgrex.Result{
         rows: [[indicators_evaluated, findings_count, next_cursor, has_more]]
       }} ->
        {:ok,
         %{
           indicators_evaluated: indicators_evaluated,
           findings_count: findings_count,
           next_cursor: next_cursor,
           complete?: not has_more
         }}

      {:error, reason} ->
        {:error, %{run_id: state.run_id, reason: reason}}
    end
  end

  defp persist_run_progress(state, batch, batch_size) do
    sql = """
    UPDATE platform.otx_retrohunt_runs
    SET
      indicators_evaluated = $2,
      findings_count = $3,
      metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'indicator_cursor', $4::text,
        'batch_size', $5::int,
        'batches_completed', $6::int,
        'last_batch_indicators', $7::int,
        'last_batch_findings', $8::int,
        'cursor_complete', $9::boolean
      ),
      updated_at = now()
    WHERE id = ($1::text)::uuid
    """

    case SQL.query(Repo, sql, [
           state.run_id,
           state.indicators_evaluated,
           state.findings_count,
           state.cursor,
           batch_size,
           state.batches_completed,
           batch.indicators_evaluated,
           batch.findings_count,
           batch.complete?
         ]) do
      {:ok, %Postgrex.Result{num_rows: 1}} ->
        :ok

      {:ok, %Postgrex.Result{num_rows: 0}} ->
        {:error, %{run_id: state.run_id, reason: :run_not_found}}

      {:error, reason} ->
        {:error, %{run_id: state.run_id, reason: reason}}
    end
  end

  defp enqueue_continuation(state) do
    args = %{
      "run_id" => state.run_id,
      "source" => state.source,
      "triggered_by" => state.triggered_by,
      "window_start" => DateTime.to_iso8601(state.window_start),
      "window_end" => DateTime.to_iso8601(state.window_end),
      "cursor" => state.cursor,
      "indicators_evaluated" => state.indicators_evaluated,
      "findings_count" => state.findings_count,
      "batches_completed" => state.batches_completed
    }

    args
    |> new(schedule_in: 1)
    |> ObanSupport.safe_insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:continuation_enqueue_failed, reason}}
    end
  end

  defp emit_batch_event(state, batch, batch_size) do
    :telemetry.execute(
      [:serviceradar, :threat_intel, :retrohunt, :batch],
      %{
        indicators_evaluated: batch.indicators_evaluated,
        findings_count: batch.findings_count
      },
      %{
        source: state.source,
        batch_size: batch_size,
        batch_number: state.batches_completed,
        cursor: state.cursor,
        complete: batch.complete?
      }
    )
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

  defp fail_run(run_id, error) do
    sql = """
    UPDATE platform.otx_retrohunt_runs
    SET
      status = 'error',
      finished_at = $2,
      error = $3,
      updated_at = $2
    WHERE id = ($1::text)::uuid
    """

    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    case SQL.query(Repo, sql, [run_id, now, error]) do
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

  defp batch_size do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:batch_size, @default_batch_size)
    |> normalize_positive_int(@default_batch_size)
    |> min(@max_batch_size)
  end

  defp max_batches_per_job do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_batches_per_job, @default_max_batches_per_job)
    |> normalize_positive_int(@default_max_batches_per_job)
    |> min(@max_batches_per_job)
  end

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

  defp normalize_non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp normalize_non_negative_int(_value), do: 0

  defp normalize_cursor(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      cursor -> cursor
    end
  end

  defp normalize_cursor(_value), do: nil

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_continuation_window}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_continuation_window}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
