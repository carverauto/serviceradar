defmodule ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker do
  @moduledoc """
  Oban worker that refreshes the logs_severity_stats_5m continuous aggregate.

  The TimescaleDB policy owns the window from three hours through thirty
  minutes ago. This worker refreshes the newest thirty minutes on every run
  and also refills the card's 24-hour window when:

    * the versioned bootstrap watermark is missing (first fill after a
      classifier or CAGG upgrade)
    * the rollup's earliest 24-hour bucket lags the earliest raw log by more
      than the coverage grace
    * a 24-hour refill has not run for the preventive interval (interior holes
      older than the 3-hour policy window otherwise stay forever)

  The 24-hour CALL is expensive, so coverage refills are rate-limited.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Ecto.Adapters.SQL

  require Logger

  @refresh_sql """
  CALL refresh_continuous_aggregate('logs_severity_stats_5m', NOW() - INTERVAL '30 minutes', NOW());
  """

  @bootstrap_sql """
  CALL refresh_continuous_aggregate('logs_severity_stats_5m', NOW() - INTERVAL '24 hours', NOW(), force => true);
  """

  @exists_sql "SELECT to_regclass('platform.logs_severity_stats_5m')"
  @bootstrap_watermark_key "logs_severity_stats_5m_v3_critical_as_error"
  @coverage_watermark_key "logs_severity_stats_5m_coverage"
  @bootstrap_complete_sql """
  SELECT EXISTS(
    SELECT 1
    FROM observability_watermarks
    WHERE key = $1
  )
  """
  @mark_watermark_sql """
  INSERT INTO observability_watermarks (key, watermark, updated_at)
  VALUES ($1, NOW(), NOW())
  ON CONFLICT (key) DO UPDATE SET
    watermark = EXCLUDED.watermark,
    updated_at = NOW()
  """
  @coverage_snapshot_sql """
  SELECT
    (
      SELECT min(timestamp)
      FROM logs
      WHERE timestamp >= now() - INTERVAL '24 hours'
    ) AS raw_min,
    (
      SELECT min(bucket)
      FROM logs_severity_stats_5m
      WHERE bucket >= now() - INTERVAL '24 hours'
    ) AS rollup_min,
    (
      SELECT watermark
      FROM observability_watermarks
      WHERE key = $1
    ) AS last_refresh
  """

  @default_refresh_timeout_ms 30_000
  @default_bootstrap_timeout_ms 10 * 60_000
  @default_coverage_grace_seconds 5 * 60
  @default_min_24h_interval_seconds 60 * 60
  @default_preventive_24h_interval_seconds 6 * 60 * 60

  def exists_sql, do: @exists_sql
  def refresh_sql, do: @refresh_sql
  def bootstrap_sql, do: @bootstrap_sql
  def coverage_snapshot_sql, do: @coverage_snapshot_sql
  def bootstrap_watermark_key, do: @bootstrap_watermark_key
  def coverage_watermark_key, do: @coverage_watermark_key

  def refresh_timeout_ms,
    do: config_positive_integer(:refresh_timeout_ms, @default_refresh_timeout_ms)

  def bootstrap_timeout_ms,
    do: config_positive_integer(:bootstrap_timeout_ms, @default_bootstrap_timeout_ms)

  def coverage_grace_seconds,
    do: config_positive_integer(:coverage_grace_seconds, @default_coverage_grace_seconds)

  def min_24h_interval_seconds,
    do: config_positive_integer(:min_24h_interval_seconds, @default_min_24h_interval_seconds)

  def preventive_24h_interval_seconds,
    do:
      config_positive_integer(
        :preventive_24h_interval_seconds,
        @default_preventive_24h_interval_seconds
      )

  @doc """
  Decide whether the 24-hour CAGG window needs another fill.

  `last_refresh_at` is the coverage watermark. A missing bootstrap watermark
  is handled separately so classifier upgrades always refill once.
  """
  @spec needs_24h_refresh?(keyword()) :: boolean()
  def needs_24h_refresh?(opts) do
    last_refresh_at = Keyword.get(opts, :last_refresh_at)
    raw_min = Keyword.get(opts, :raw_min)
    rollup_min = Keyword.get(opts, :rollup_min)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    grace = Keyword.get(opts, :coverage_grace_seconds, coverage_grace_seconds())
    min_interval = Keyword.get(opts, :min_interval_seconds, min_24h_interval_seconds())

    preventive_interval =
      Keyword.get(opts, :preventive_interval_seconds, preventive_24h_interval_seconds())

    coverage_gap_seconds = coverage_gap_seconds(rollup_min, raw_min)

    cond do
      is_nil(raw_min) ->
        false

      recent?(last_refresh_at, now, min_interval) ->
        false

      is_nil(rollup_min) ->
        true

      is_integer(coverage_gap_seconds) and coverage_gap_seconds > grace ->
        true

      not recent?(last_refresh_at, now, preventive_interval) ->
        true

      true ->
        false
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, true} <- cagg_exists?(),
         :ok <- maybe_refresh_24h(),
         {:ok, _result} <-
           SQL.query(ServiceRadar.Repo, @refresh_sql, [], timeout: refresh_timeout_ms()) do
      Logger.info("Refreshed logs_severity_stats_5m continuous aggregate")
      :ok
    else
      {:ok, false} ->
        Logger.debug("logs_severity_stats_5m CAGG missing; skipping refresh")
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("logs_severity_stats_5m CAGG missing; skipping refresh")
        :ok

      {:error, error} ->
        Logger.error("Failed to refresh logs_severity_stats_5m: #{Exception.message(error)}")

        {:error, error}
    end
  rescue
    error ->
      Logger.error("Failed to refresh logs_severity_stats_5m: #{Exception.message(error)}")

      {:error, error}
  end

  defp cagg_exists? do
    case SQL.query(ServiceRadar.Repo, @exists_sql, [], timeout: refresh_timeout_ms()) do
      {:ok, %{rows: [[nil]]}} ->
        {:ok, false}

      {:ok, %{rows: [[_]]}} ->
        {:ok, true}

      {:error, error} ->
        {:error, error}
    end
  end

  defp maybe_refresh_24h do
    with {:ok, bootstrapped?} <- watermark_present?(@bootstrap_watermark_key),
         {:ok, snapshot} <- coverage_snapshot() do
      cond do
        not bootstrapped? ->
          run_24h_refresh("Bootstrapped 24 hours of logs_severity_stats_5m")

        needs_24h_refresh?(snapshot) ->
          run_24h_refresh("Refilled 24 hours of logs_severity_stats_5m")

        true ->
          :ok
      end
    end
  end

  defp watermark_present?(key) do
    case SQL.query(
           ServiceRadar.Repo,
           @bootstrap_complete_sql,
           [key],
           timeout: refresh_timeout_ms()
         ) do
      {:ok, %{rows: [[value]]}} -> {:ok, value == true}
      {:error, error} -> {:error, error}
    end
  end

  defp coverage_snapshot do
    case SQL.query(
           ServiceRadar.Repo,
           @coverage_snapshot_sql,
           [@coverage_watermark_key],
           timeout: refresh_timeout_ms()
         ) do
      {:ok, %{rows: [[raw_min, rollup_min, last_refresh]]}} ->
        {:ok,
         [
           raw_min: normalize_datetime(raw_min),
           rollup_min: normalize_datetime(rollup_min),
           last_refresh_at: normalize_datetime(last_refresh)
         ]}

      {:error, error} ->
        {:error, error}
    end
  end

  defp run_24h_refresh(message) do
    with {:ok, _result} <-
           SQL.query(ServiceRadar.Repo, @bootstrap_sql, [], timeout: bootstrap_timeout_ms()),
         :ok <- mark_watermark(@bootstrap_watermark_key),
         :ok <- mark_watermark(@coverage_watermark_key) do
      Logger.info(message)
      :ok
    end
  end

  defp mark_watermark(key) do
    case SQL.query(
           ServiceRadar.Repo,
           @mark_watermark_sql,
           [key],
           timeout: refresh_timeout_ms()
         ) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp coverage_gap_seconds(%DateTime{} = rollup_min, %DateTime{} = raw_min) do
    max(DateTime.diff(rollup_min, raw_min, :second), 0)
  end

  defp coverage_gap_seconds(_, _), do: nil

  defp recent?(%DateTime{} = last_refresh_at, %DateTime{} = now, interval_seconds)
       when is_integer(interval_seconds) and interval_seconds > 0 do
    DateTime.diff(now, last_refresh_at, :second) < interval_seconds
  end

  defp recent?(_, _, _), do: false

  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp normalize_datetime(_), do: nil

  defp config_positive_integer(key, default) do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
