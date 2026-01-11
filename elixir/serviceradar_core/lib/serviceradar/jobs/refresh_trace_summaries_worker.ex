defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorker do
  @moduledoc """
  Oban worker that refreshes the otel_trace_summaries materialized view.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @refresh_sql "REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries"

  def refresh_sql, do: @refresh_sql

  @impl Oban.Worker
  def perform(_job) do
    # Use ServiceRadar.Repo directly for SQL adapter operations.
    case Ecto.Adapters.SQL.query(ServiceRadar.Repo, @refresh_sql, []) do
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
