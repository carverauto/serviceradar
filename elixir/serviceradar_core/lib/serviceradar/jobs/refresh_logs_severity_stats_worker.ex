defmodule ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker do
  @moduledoc """
  Oban worker that refreshes the logs_severity_stats_5m continuous aggregate.

  The TimescaleDB policy owns the window from three hours through thirty
  minutes ago. This worker explicitly refreshes the newest thirty minutes and
  performs one asynchronous 24-hour bootstrap after the versioned safety-net
  migration creates or upgrades the aggregate. The bootstrap completion marker
  keeps the recurring two-minute job inexpensive after that first fill.
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
  CALL refresh_continuous_aggregate('logs_severity_stats_5m', NOW() - INTERVAL '24 hours', NOW());
  """

  @exists_sql "SELECT to_regclass('platform.logs_severity_stats_5m')"
  @bootstrap_watermark_key "logs_severity_stats_5m_v2_bootstrap"
  @bootstrap_complete_sql """
  SELECT EXISTS(
    SELECT 1
    FROM observability_watermarks
    WHERE key = $1
  )
  """
  @mark_bootstrap_complete_sql """
  INSERT INTO observability_watermarks (key, watermark, updated_at)
  VALUES ($1, NOW(), NOW())
  ON CONFLICT (key) DO UPDATE SET
    watermark = EXCLUDED.watermark,
    updated_at = NOW()
  """

  @default_refresh_timeout_ms 30_000
  @default_bootstrap_timeout_ms 10 * 60_000

  def exists_sql, do: @exists_sql
  def refresh_sql, do: @refresh_sql
  def bootstrap_sql, do: @bootstrap_sql
  def bootstrap_watermark_key, do: @bootstrap_watermark_key

  def refresh_timeout_ms,
    do: config_positive_integer(:refresh_timeout_ms, @default_refresh_timeout_ms)

  def bootstrap_timeout_ms,
    do: config_positive_integer(:bootstrap_timeout_ms, @default_bootstrap_timeout_ms)

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, true} <- cagg_exists?(),
         :ok <- maybe_bootstrap(),
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

  defp maybe_bootstrap do
    case bootstrap_complete?() do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        run_bootstrap()

      {:error, error} ->
        {:error, error}
    end
  end

  defp bootstrap_complete? do
    case SQL.query(
           ServiceRadar.Repo,
           @bootstrap_complete_sql,
           [@bootstrap_watermark_key],
           timeout: refresh_timeout_ms()
         ) do
      {:ok, %{rows: [[value]]}} -> {:ok, value == true}
      {:error, error} -> {:error, error}
    end
  end

  defp run_bootstrap do
    with {:ok, _result} <-
           SQL.query(ServiceRadar.Repo, @bootstrap_sql, [], timeout: bootstrap_timeout_ms()),
         {:ok, _result} <-
           SQL.query(
             ServiceRadar.Repo,
             @mark_bootstrap_complete_sql,
             [@bootstrap_watermark_key],
             timeout: refresh_timeout_ms()
           ) do
      Logger.info("Bootstrapped 24 hours of logs_severity_stats_5m")
      :ok
    end
  end

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
