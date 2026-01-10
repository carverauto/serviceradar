defmodule ServiceRadar.Observability.StatefulAlertCleanupWorker do
  @moduledoc """
  Cleans up stale stateful alert rule snapshots.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Observability.StatefulAlertRuleState

  import Ash.Expr

  require Ash.Query
  require Logger

  @stale_after_days 30

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_days * 86_400, :second)

    TenantSchemas.list_schemas()
    |> Enum.each(fn schema ->
      cleanup_schema(schema, cutoff)
    end)

    :ok
  end

  defp cleanup_schema(schema, cutoff) do
    query =
      StatefulAlertRuleState
      |> Ash.Query.filter(expr(is_nil(last_seen_at) or last_seen_at < ^cutoff))

    case Ash.read(query, tenant: schema, authorize?: false) do
      {:ok, %Ash.Page.Keyset{results: results}} ->
        destroy_states(results, schema)

      {:ok, results} when is_list(results) ->
        destroy_states(results, schema)

      {:error, reason} ->
        Logger.warning("Failed to load stale rule state", schema: schema, reason: inspect(reason))
    end
  end

  defp destroy_states(states, schema) do
    Enum.each(states, fn state ->
      case Ash.destroy(state, tenant: schema, authorize?: false) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning("Failed to delete stale rule state", schema: schema, reason: inspect(reason))
      end
    end)
  end
end
