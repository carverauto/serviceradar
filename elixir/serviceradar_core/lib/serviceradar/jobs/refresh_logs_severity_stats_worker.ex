defmodule ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker do
  @moduledoc """
  Oban worker that refreshes the logs_severity_stats_5m continuous aggregate.

  The TimescaleDB policy refreshes with end_offset of 1 hour, which means
  the most recent hour is only served via real-time aggregation (slower).
  This worker explicitly refreshes the last 30 minutes so materialized data
  stays current.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Ecto.Adapters.SQL

  require Logger

  @refresh_sql """
  CALL refresh_continuous_aggregate('logs_severity_stats_5m', NOW() - INTERVAL '30 minutes', NOW());
  """

  @exists_sql "SELECT to_regclass('platform.logs_severity_stats_5m')"

  def exists_sql, do: @exists_sql
  def refresh_sql, do: @refresh_sql

  @impl Oban.Worker
  def perform(_job) do
    with {:ok, true} <- cagg_exists?(),
         {:ok, _result} <-
           SQL.query(ServiceRadar.Repo, @refresh_sql, [], timeout: 30_000) do
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
    case SQL.query(ServiceRadar.Repo, @exists_sql, [], timeout: 30_000) do
      {:ok, %{rows: [[nil]]}} ->
        {:ok, false}

      {:ok, %{rows: [[_]]}} ->
        {:ok, true}

      {:error, error} ->
        {:error, error}
    end
  end
end
