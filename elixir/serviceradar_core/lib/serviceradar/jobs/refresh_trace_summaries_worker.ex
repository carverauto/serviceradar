defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorker do
  @moduledoc """
  Oban worker that refreshes the otel_trace_summaries materialized view.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas

  @refresh_sql "REFRESH MATERIALIZED VIEW CONCURRENTLY"

  def refresh_sql, do: @refresh_sql

  @impl Oban.Worker
  def perform(_job) do
    schemas = TenantSchemas.list_schemas()

    if schemas == [] do
      Logger.debug("No tenant schemas found; skipping otel_trace_summaries refresh")
      :ok
    else
      Enum.each(schemas, &refresh_schema/1)
      :ok
    end
  rescue
    error ->
      Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}")
      {:error, error}
  end

  defp refresh_schema(schema) do
    sql = "#{@refresh_sql} #{schema}.otel_trace_summaries"

    # Use ServiceRadar.Repo directly for SQL adapter operations.
    case Ecto.Adapters.SQL.query(ServiceRadar.Repo, sql, []) do
      {:ok, _result} ->
        Logger.info("Refreshed otel_trace_summaries materialized view", schema: schema)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("otel_trace_summaries view missing; skipping refresh", schema: schema)

      {:error, error} ->
        Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}",
          schema: schema
        )
    end
  end
end
