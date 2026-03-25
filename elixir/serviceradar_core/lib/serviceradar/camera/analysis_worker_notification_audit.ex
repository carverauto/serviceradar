defmodule ServiceRadar.Camera.AnalysisWorkerNotificationAudit do
  @moduledoc """
  Resolves bounded notification audit state for routed camera analysis worker
  alerts from the standard alert lifecycle.
  """

  alias ServiceRadar.Camera.AnalysisWorkerAlertRouter
  alias ServiceRadar.Monitoring.Alert

  require Ash.Query

  @spec audit_contexts([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def audit_contexts(workers, opts \\ []) when is_list(workers) do
    routed_contexts =
      workers
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn worker, acc ->
        case map_value(worker, :worker_id) do
          worker_id when is_binary(worker_id) and worker_id != "" ->
            Map.put(acc, worker_id, AnalysisWorkerAlertRouter.routed_alert_context(worker))

          _other ->
            acc
        end
      end)

    routed_keys =
      routed_contexts
      |> Map.values()
      |> Enum.filter(&Map.get(&1, :routed_alert_active, false))
      |> Enum.map(&Map.get(&1, :routed_alert_key))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with {:ok, alerts_by_key} <- fetch_alerts_by_key(routed_keys, opts) do
      {:ok,
       Map.new(routed_contexts, fn {worker_id, routed_context} ->
         audit_context =
           build_audit_context(Map.get(alerts_by_key, routed_context.routed_alert_key))

         {worker_id, audit_context}
       end)}
    end
  end

  @spec audit_context(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def audit_context(worker, opts \\ []) when is_map(worker) do
    with {:ok, contexts} <- audit_contexts([worker], opts) do
      {:ok, Map.get(contexts, map_value(worker, :worker_id), empty_context())}
    end
  end

  defp fetch_alerts_by_key([], _opts), do: {:ok, %{}}

  defp fetch_alerts_by_key(keys, opts) do
    list_alerts = Keyword.get(opts, :list_alerts, &list_active_alerts/2)
    scope = Keyword.get(opts, :scope)

    with {:ok, alerts} <- list_alerts.(keys, scope) do
      {:ok,
       Map.new(alerts, fn alert ->
         {map_value(alert, :source_id), alert}
       end)}
    end
  end

  defp list_active_alerts(keys, scope) when is_list(keys) do
    query =
      Alert
      |> Ash.Query.for_read(:active, %{}, scope: scope)
      |> Ash.Query.filter(source_type == :event and source_id in ^keys)

    Ash.read(query, scope: scope, domain: ServiceRadar.Monitoring)
  end

  defp build_audit_context(nil), do: empty_context()

  defp build_audit_context(alert) do
    %{
      notification_audit_active: true,
      notification_audit_alert_id: map_value(alert, :id),
      notification_audit_alert_status: normalize_atom(map_value(alert, :status)),
      notification_audit_notification_count: map_value(alert, :notification_count, 0),
      notification_audit_last_notification_at: map_value(alert, :last_notification_at),
      notification_audit_suppressed_until: map_value(alert, :suppressed_until)
    }
  end

  defp empty_context do
    %{
      notification_audit_active: false,
      notification_audit_alert_id: nil,
      notification_audit_alert_status: nil,
      notification_audit_notification_count: 0,
      notification_audit_last_notification_at: nil,
      notification_audit_suppressed_until: nil
    }
  end

  defp normalize_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_atom(value), do: value

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
