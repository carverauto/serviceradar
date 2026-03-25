defmodule ServiceRadarWebNG.CameraAnalysisWorkers do
  @moduledoc """
  Web-facing operations for camera analysis workers.
  """

  alias ServiceRadar.Camera.AnalysisWorker
  alias ServiceRadar.Camera.AnalysisWorkerNotificationAudit
  alias ServiceRadarWebNG.CameraAnalysisWorkerAssignments

  require Ash.Query

  def list_workers(opts \\ []) do
    scope = Keyword.fetch!(opts, :scope)
    limit = parse_limit(Keyword.get(opts, :limit))

    query =
      AnalysisWorker
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(worker_id: :asc)
      |> maybe_filter_enabled(Keyword.get(opts, :enabled))
      |> maybe_limit(limit)

    with {:ok, workers} <- Ash.read(query, scope: scope),
         {:ok, audit_contexts} <-
           notification_audit_source().audit_contexts(workers, scope: scope) do
      {:ok, enrich_workers(workers, assignment_source().assignment_snapshot(), audit_contexts)}
    end
  end

  def get_worker(id, opts \\ []) when is_binary(id) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, worker} <- Ash.get(AnalysisWorker, id, scope: scope) do
      case worker do
        nil ->
          {:ok, nil}

        _worker ->
          with {:ok, audit_context} <-
                 notification_audit_source().audit_context(worker, scope: scope) do
            {:ok, enrich_worker(worker, assignment_source().assignment_snapshot(), audit_context)}
          end
      end
    end
  end

  def create_worker(attrs, opts \\ []) when is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    AnalysisWorker
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
    |> maybe_enrich_result()
  end

  def update_worker(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, worker} when not is_nil(worker) <- get_worker(id, scope: scope) do
      worker
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> Ash.update(scope: scope)
      |> maybe_enrich_result()
    end
  end

  def set_enabled(id, enabled, opts \\ []) when is_binary(id) and is_boolean(enabled) do
    update_worker(id, %{enabled: enabled}, opts)
  end

  defp maybe_filter_enabled(query, nil), do: query

  defp maybe_filter_enabled(query, enabled) when is_boolean(enabled), do: Ash.Query.filter(query, enabled == ^enabled)

  defp maybe_filter_enabled(query, _enabled), do: query

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: Ash.Query.limit(query, limit)

  defp maybe_enrich_result({:ok, worker}), do: {:ok, enrich_worker(worker)}
  defp maybe_enrich_result(other), do: other

  defp enrich_workers(workers, snapshot, audit_contexts) do
    Enum.map(workers, fn worker ->
      enrich_worker(worker, snapshot, Map.get(audit_contexts, worker.worker_id, %{}))
    end)
  end

  defp enrich_worker(worker) do
    enrich_worker(
      worker,
      assignment_source().assignment_snapshot(),
      empty_notification_audit_context()
    )
  end

  defp enrich_worker(worker, snapshot, audit_context) do
    assignment =
      snapshot
      |> Map.get(worker.worker_id, %{})
      |> normalize_assignment_visibility()

    worker
    |> Map.put(:active_assignment_count, assignment.active_assignment_count)
    |> Map.put(:active_assignments, assignment.active_assignments)
    |> Map.put(
      :notification_audit_active,
      Map.get(audit_context, :notification_audit_active, false)
    )
    |> Map.put(
      :notification_audit_alert_id,
      Map.get(audit_context, :notification_audit_alert_id)
    )
    |> Map.put(
      :notification_audit_alert_status,
      Map.get(audit_context, :notification_audit_alert_status)
    )
    |> Map.put(
      :notification_audit_notification_count,
      Map.get(audit_context, :notification_audit_notification_count, 0)
    )
    |> Map.put(
      :notification_audit_last_notification_at,
      Map.get(audit_context, :notification_audit_last_notification_at)
    )
    |> Map.put(
      :notification_audit_suppressed_until,
      Map.get(audit_context, :notification_audit_suppressed_until)
    )
  end

  defp normalize_assignment_visibility(assignment) do
    %{
      active_assignment_count: Map.get(assignment, :active_assignment_count, 0),
      active_assignments:
        assignment
        |> Map.get(:active_assignments, [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)
    }
  end

  defp assignment_source do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_analysis_worker_assignments,
      CameraAnalysisWorkerAssignments
    )
  end

  defp notification_audit_source do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_analysis_worker_notification_audit,
      AnalysisWorkerNotificationAudit
    )
  end

  defp empty_notification_audit_context do
    %{
      notification_audit_active: false,
      notification_audit_alert_id: nil,
      notification_audit_alert_status: nil,
      notification_audit_notification_count: 0,
      notification_audit_last_notification_at: nil,
      notification_audit_suppressed_until: nil
    }
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp parse_limit(_limit), do: nil
end
