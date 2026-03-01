defmodule ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker do
  @moduledoc """
  Oban worker that refreshes the logs_severity_stats_5m continuous aggregate.

  The TimescaleDB policy refreshes with end_offset of 1 hour, which means
  the most recent hour is only served via real-time aggregation (slower).
  This worker explicitly refreshes the last 30 minutes so materialized data
  stays current.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @refresh_sql """
  CALL refresh_continuous_aggregate('logs_severity_stats_5m', NOW() - INTERVAL '30 minutes', NOW());
  """

  def refresh_sql, do: @refresh_sql

  @impl Oban.Worker
  def perform(_job) do
    case Ecto.Adapters.SQL.query(ServiceRadar.Repo, @refresh_sql, [], timeout: 30_000) do
      {:ok, _result} ->
        Logger.info("Refreshed logs_severity_stats_5m continuous aggregate")
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("logs_severity_stats_5m CAGG missing; skipping refresh")
        :ok

      {:error, error} ->
        Logger.error(
          "Failed to refresh logs_severity_stats_5m: #{Exception.message(error)}"
        )

        {:error, error}
    end
  rescue
    error ->
      Logger.error(
        "Failed to refresh logs_severity_stats_5m: #{Exception.message(error)}"
      )

      {:error, error}
  end
end
