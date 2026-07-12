defmodule ServiceRadar.Observability.ServiceStateRegistry.HistoryRepair do
  @moduledoc false

  alias ServiceRadar.Observability.ServiceStateRegistry.HistoryQueries
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract
  alias ServiceRadar.Observability.ServiceStateRegistry.Queries
  alias ServiceRadar.Observability.ServiceStateRegistry.SideEffects
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusIngestor
  alias ServiceRadar.Repo

  require Logger

  @plugin_result_output "serviceradar.plugin_result.v1"
  @streaming_plugin_output "serviceradar.camera_stream.v1"
  @streaming_plugin_capability "camera_media_stream"

  @doc false
  @spec repair(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def repair(opts \\ []) do
    interval = opts |> Keyword.get(:interval, "30 days") |> to_string()
    batch_size = opts |> Keyword.get(:batch_size, 250) |> max(1)
    total_limit = normalize_total_limit(Keyword.get(opts, :limit, :infinity))

    case repair_batches(interval, batch_size, total_limit, initial_cursor()) do
      {:ok, repaired_count} ->
        case PluginState.deactivate_inactive_count() do
          {:ok, inactive_count} ->
            {:ok, repaired_count + inactive_count}

          {:error, reason} ->
            Logger.warning("Plugin service state cleanup failed: #{inspect(reason)}")
            {:error, reason}

          other ->
            error = {:unexpected_plugin_state_cleanup_result, other}
            Logger.warning("Plugin service state cleanup failed: #{inspect(error)}")
            {:error, error}
        end

      {:error, reason} ->
        Logger.warning("Plugin service state history repair failed: #{inspect(reason)}")
        {:error, reason}

      other ->
        error = {:unexpected_plugin_history_repair_result, other}
        Logger.warning("Plugin service state history repair failed: #{inspect(error)}")
        {:error, error}
    end
  rescue
    error ->
      Logger.warning("Plugin service state history repair failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp repair_batches(interval, batch_size, total_limit, cursor, count \\ 0)

  defp repair_batches(_interval, _batch_size, total_limit, _cursor, count)
       when is_integer(total_limit) and count >= total_limit do
    {:ok, count}
  end

  defp repair_batches(interval, batch_size, total_limit, cursor, count) do
    page_size = page_size(batch_size, total_limit, count)

    params =
      [interval, page_size | Tuple.to_list(cursor)] ++ eligible_assignment_params()

    case Repo.query(HistoryQueries.latest_plugin_status(), params) do
      {:ok, %{rows: []}} ->
        {:ok, count}

      {:ok, %{rows: rows}} ->
        with {:ok, repaired_count} <- replace_history_rows(rows, interval) do
          repair_batches(
            interval,
            batch_size,
            total_limit,
            cursor_from_row(List.last(rows)),
            count + repaired_count
          )
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_plugin_history_query_result, other}}
    end
  end

  defp replace_history_rows(rows, interval) do
    Enum.reduce_while(rows, {:ok, 0}, fn row, acc -> replace_history_row(row, interval, acc) end)
  end

  defp replace_history_row(row, interval, {:ok, count}) do
    identity = identity_from_history_row(row)

    case Repo.transaction(fn -> replace_history_row_locked(identity, interval) end) do
      {:ok, {:ok, row_notifications, row_side_effects}} ->
        _ = Ash.Notifier.notify(row_notifications)
        dispatch_side_effects(row_side_effects)
        {:cont, {:ok, count + 1}}

      {:error, reason} ->
        {:halt, {:error, reason}}

      other ->
        {:halt, {:error, {:unexpected_plugin_history_replace_result, other}}}
    end
  end

  defp replace_history_row_locked(identity, interval) do
    with :ok <- PluginState.acquire_lock(identity),
         {:ok, fresh_status} <- fresh_history_state(identity, interval),
         {:ok, current} <- current_logical_state(identity) do
      if fresh_status && replace_candidate?(fresh_status, current) do
        case StatusIngestor.replace_with_notifications(fresh_status, preserve_gateway?: true) do
          {:ok, _notifications, _side_effects} = result -> result
          {:error, reason} -> Repo.rollback(reason)
          other -> Repo.rollback({:unexpected_plugin_history_replace_result, other})
        end
      else
        {:ok, [], []}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
      other -> Repo.rollback({:unexpected_plugin_history_repair_step, other})
    end
  end

  defp fresh_history_state(status, interval) do
    params =
      [interval, status.agent_id, status.partition, status.service_type, status.service_name] ++
        eligible_assignment_params()

    case Repo.query(HistoryQueries.latest_plugin_status_for_identity(), params) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [row]}} -> {:ok, status_from_history_row(row)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_plugin_history_winner_result, other}}
    end
  end

  defp current_logical_state(status) do
    params = [status.agent_id, status.partition, status.service_type, status.service_name]

    case Repo.query(Queries.plugin_state_winner_for_identity(), params) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [row]}} -> {:ok, state_snapshot(row)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_plugin_state_winner_result, other}}
    end
  end

  defp replace_candidate?(_candidate, nil), do: true

  defp replace_candidate?(candidate, current) do
    PluginStateContract.compare_snapshots(candidate, current) != :lt or
      PluginStateContract.same_logical_observation?(candidate, current)
  end

  defp state_snapshot([gateway_id, available, message, details, timestamp]) do
    %{
      gateway_id: gateway_id,
      available: available,
      message: message,
      details: details,
      timestamp: timestamp
    }
  end

  defp dispatch_side_effects(side_effects) do
    case SideEffects.dispatch(side_effects) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Plugin service state history repair side-effects failed: #{inspect(reason)}"
        )

        :ok
    end
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
      message: message,
      details: details,
      timestamp: timestamp
    }
  end

  defp identity_from_history_row([agent_id, partition, service_type, service_name]) do
    %{
      agent_id: agent_id,
      partition: partition,
      service_type: service_type,
      service_name: service_name
    }
  end

  defp initial_cursor, do: {"", "", "", ""}

  defp normalize_total_limit(:infinity), do: :infinity
  defp normalize_total_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_total_limit(_limit), do: :infinity

  defp page_size(batch_size, :infinity, _count), do: batch_size
  defp page_size(batch_size, total_limit, count), do: min(batch_size, total_limit - count)

  defp eligible_assignment_params do
    [@plugin_result_output, @streaming_plugin_output, @streaming_plugin_capability]
  end

  defp cursor_from_row([agent_id, partition, service_type, service_name]) do
    {agent_id, partition, service_type, service_name}
  end
end
