defmodule ServiceRadar.Observability.ServiceStateRegistry.HistoryRepair do
  @moduledoc false

  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
  alias ServiceRadar.Observability.ServiceStateRegistry.Queries
  alias ServiceRadar.Observability.ServiceStateRegistry.SideEffects
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusIngestor
  alias ServiceRadar.Repo

  require Logger

  @doc false
  @spec repair(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def repair(opts \\ []) do
    interval = opts |> Keyword.get(:interval, "30 days") |> to_string()
    limit = Keyword.get(opts, :limit, 5_000)

    case Repo.query(Queries.latest_plugin_status(), [interval, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn row -> upsert_history_status(status_from_history_row(row)) end)

        case PluginState.deactivate_inactive_count() do
          {:ok, inactive_count} -> {:ok, length(rows) + inactive_count}
          {:error, _reason} = error -> error
        end

      {:error, reason} = error ->
        Logger.warning("Plugin service state history repair failed: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Plugin service state history repair failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp upsert_history_status(status) do
    case Repo.transaction(fn ->
           with :ok <- PluginState.acquire_lock(status),
                {:ok, notifications, side_effects} <-
                  StatusIngestor.upsert_with_notifications(status, preserve_gateway?: true) do
             {notifications, side_effects}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {notifications, side_effects}} ->
        _ = Ash.Notifier.notify(notifications)

        case SideEffects.dispatch(side_effects) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Plugin service state history repair side-effects failed: #{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning("Plugin service state history row repair failed: #{inspect(reason)}")
        :ok

      other ->
        Logger.warning("Unexpected plugin service state history repair result: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Plugin service state history row repair failed: #{Exception.message(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning("Plugin service state history row repair failed: #{inspect({kind, reason})}")
      :ok
  end

  defp status_from_history_row([
         agent_id,
         gateway_id,
         partition,
         service_type,
         service_name,
         available,
         message,
         details,
         timestamp
       ]) do
    %{
      agent_id: agent_id,
      gateway_id: gateway_id,
      partition: partition,
      service_type: service_type,
      service_name: service_name,
      available: available,
      message: details || message,
      timestamp: timestamp
    }
  end
end
