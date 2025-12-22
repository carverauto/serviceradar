defmodule ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadarWebNG.Repo

  require Logger

  @refresh_sql "REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries"

  def refresh_sql, do: @refresh_sql

  @impl Oban.Worker
  def perform(_job) do
    case Ecto.Adapters.SQL.query(Repo, @refresh_sql, []) do
      {:ok, _result} ->
        Logger.info("Refreshed otel_trace_summaries materialized view")
        :ok

      {:error, error} ->
        Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}")
        {:error, error}
    end
  rescue
    error ->
      Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}")
      {:error, error}
  end
end
