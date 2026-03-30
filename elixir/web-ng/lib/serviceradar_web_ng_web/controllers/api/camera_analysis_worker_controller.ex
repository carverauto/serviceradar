defmodule ServiceRadarWebNGWeb.Api.CameraAnalysisWorkerController do
  @moduledoc """
  Authenticated management API for camera analysis workers.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Camera.AnalysisWorkerAlertRouter
  alias ServiceRadar.Policies.OutboundURLPolicy
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.CameraAnalysisWorkers
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage"),
         {:ok, workers} <-
           camera_analysis_workers().list_workers(
             scope: get_scope(conn),
             limit: params["limit"],
             enabled: normalize_optional_boolean(params["enabled"])
           ) do
      json(conn, %{data: Enum.map(workers, &worker_json/1)})
    else
      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "worker_not_found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage"),
         {:ok, worker} <- fetch_worker(id, conn) do
      json(conn, %{data: worker_json(worker)})
    else
      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "worker_not_found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage"),
         {:ok, attrs} <- normalize_create_attrs(params),
         {:ok, worker} <- camera_analysis_workers().create_worker(attrs, scope: get_scope(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: worker_json(worker)})
    else
      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, other} ->
        {:error, other}
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage"),
         {:ok, _worker} <- fetch_worker(id, conn),
         {:ok, attrs} <- normalize_update_attrs(params),
         {:ok, worker} <-
           camera_analysis_workers().update_worker(id, attrs, scope: get_scope(conn)) do
      json(conn, %{data: worker_json(worker)})
    else
      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "worker_not_found"})

      {:error, other} ->
        {:error, other}
    end
  end

  def enable(conn, %{"id" => id}) do
    toggle_enabled(conn, id, true)
  end

  def disable(conn, %{"id" => id}) do
    toggle_enabled(conn, id, false)
  end

  defp toggle_enabled(conn, id, enabled) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.edge.manage"),
         {:ok, _worker} <- fetch_worker(id, conn),
         {:ok, worker} <-
           camera_analysis_workers().set_enabled(id, enabled, scope: get_scope(conn)) do
      json(conn, %{data: worker_json(worker)})
    else
      {:error, :invalid_request, message} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "worker_not_found"})

      {:error, other} ->
        {:error, other}
    end
  end

  defp fetch_worker(id, conn) do
    with {:ok, normalized_id} <- normalize_uuid_param(id, "id"),
         {:ok, worker} <-
           camera_analysis_workers().get_worker(normalized_id, scope: get_scope(conn)) do
      case worker do
        nil -> {:error, :not_found}
        _ -> {:ok, worker}
      end
    end
  end

  defp normalize_create_attrs(params) do
    with {:ok, worker_id} <- required_string(params, "worker_id"),
         {:ok, adapter} <- required_string(params, "adapter"),
         {:ok, endpoint_url} <- required_string(params, "endpoint_url"),
         {:ok, endpoint_url} <- validate_worker_url(endpoint_url, "endpoint_url", true),
         {:ok, health_endpoint_url} <-
           validate_worker_url(Map.get(params, "health_endpoint_url"), "health_endpoint_url", false),
         {:ok, capabilities} <- normalize_string_list(Map.get(params, "capabilities")),
         {:ok, headers} <- normalize_map(Map.get(params, "headers"), "headers"),
         {:ok, metadata} <- normalize_map(Map.get(params, "metadata"), "metadata"),
         {:ok, health_timeout_ms} <-
           normalize_optional_positive_integer(
             Map.get(params, "health_timeout_ms"),
             "health_timeout_ms"
           ),
         {:ok, probe_interval_ms} <-
           normalize_optional_positive_integer(
             Map.get(params, "probe_interval_ms"),
             "probe_interval_ms"
           ) do
      {:ok,
       %{
         worker_id: worker_id,
         display_name: normalize_optional_string(Map.get(params, "display_name")),
         adapter: adapter,
         endpoint_url: endpoint_url,
         health_endpoint_url: health_endpoint_url,
         health_path: normalize_optional_string(Map.get(params, "health_path")),
         health_timeout_ms: health_timeout_ms,
         probe_interval_ms: probe_interval_ms,
         capabilities: capabilities,
         enabled: normalize_optional_boolean(Map.get(params, "enabled"), true),
         headers: headers,
         metadata: metadata
       }}
    end
  end

  defp normalize_update_attrs(params) do
    with {:ok, endpoint_url} <-
           validate_worker_url(Map.get(params, "endpoint_url"), "endpoint_url", false),
         {:ok, health_endpoint_url} <-
           validate_worker_url(Map.get(params, "health_endpoint_url"), "health_endpoint_url", false),
         attrs =
           %{}
           |> maybe_put(:display_name, normalize_optional_string(Map.get(params, "display_name")))
           |> maybe_put(:adapter, normalize_optional_string(Map.get(params, "adapter")))
           |> maybe_put(:endpoint_url, endpoint_url)
           |> maybe_put(:health_endpoint_url, health_endpoint_url)
           |> maybe_put(:health_path, normalize_optional_string(Map.get(params, "health_path")))
           |> maybe_put(:enabled, normalize_optional_boolean(Map.get(params, "enabled"))),
         {:ok, attrs} <-
           maybe_put_positive_integer(
             attrs,
             :health_timeout_ms,
             Map.get(params, "health_timeout_ms"),
             "health_timeout_ms"
           ),
         {:ok, attrs} <-
           maybe_put_positive_integer(
             attrs,
             :probe_interval_ms,
             Map.get(params, "probe_interval_ms"),
             "probe_interval_ms"
           ),
         {:ok, attrs} <-
           maybe_put_string_list(attrs, :capabilities, Map.get(params, "capabilities")),
         {:ok, attrs} <- maybe_put_map(attrs, :headers, Map.get(params, "headers"), "headers") do
      maybe_put_map(attrs, :metadata, Map.get(params, "metadata"), "metadata")
    end
  end

  defp maybe_put_positive_integer(attrs, _key, nil, _field_name), do: {:ok, attrs}

  defp maybe_put_positive_integer(attrs, key, value, field_name) do
    case normalize_optional_positive_integer(value, field_name) do
      {:ok, normalized} -> {:ok, maybe_put(attrs, key, normalized)}
      error -> error
    end
  end

  defp maybe_put_string_list(attrs, _key, nil), do: {:ok, attrs}

  defp maybe_put_string_list(attrs, key, value) do
    case normalize_string_list(value) do
      {:ok, normalized} -> {:ok, Map.put(attrs, key, normalized)}
      error -> error
    end
  end

  defp maybe_put_map(attrs, _key, nil, _field_name), do: {:ok, attrs}

  defp maybe_put_map(attrs, key, value, field_name) do
    case normalize_map(value, field_name) do
      {:ok, normalized} -> {:ok, Map.put(attrs, key, normalized)}
      error -> error
    end
  end

  defp normalize_string_list(nil), do: {:ok, []}

  defp normalize_string_list(values) when is_list(values) do
    {:ok,
     values
     |> Enum.map(&to_string/1)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))}
  end

  defp normalize_string_list(_values), do: {:error, :invalid_request, "capabilities must be a list of strings"}

  defp normalize_map(nil, _field_name), do: {:ok, %{}}
  defp normalize_map(value, _field_name) when is_map(value), do: {:ok, value}

  defp normalize_map(_value, field_name), do: {:error, :invalid_request, "#{field_name} must be an object"}

  defp required_string(params, key) do
    case normalize_optional_string(Map.get(params, key)) do
      nil -> {:error, :invalid_request, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp normalize_uuid_param(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request, "#{field_name} must be a valid UUID"}
    end
  end

  defp normalize_uuid_param(_value, field_name), do: {:error, :invalid_request, "#{field_name} is required"}

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp validate_worker_url(value, field_name, required?) do
    normalized = normalize_optional_string(value)

    cond do
      is_nil(normalized) and required? ->
        {:error, :invalid_request, "#{field_name} is required"}

      is_nil(normalized) ->
        {:ok, nil}

      true ->
        case OutboundURLPolicy.validate_https_public_url(normalized) do
          {:ok, _uri} -> {:ok, normalized}
          {:error, _reason} -> {:error, :invalid_request, "#{field_name} must be an HTTPS URL to a public host"}
        end
    end
  end

  defp normalize_optional_boolean(value, default \\ nil)
  defp normalize_optional_boolean(nil, default), do: default
  defp normalize_optional_boolean(true, _default), do: true
  defp normalize_optional_boolean(false, _default), do: false
  defp normalize_optional_boolean("true", _default), do: true
  defp normalize_optional_boolean("false", _default), do: false
  defp normalize_optional_boolean(_value, default), do: default

  defp normalize_optional_positive_integer(nil, _field_name), do: {:ok, nil}

  defp normalize_optional_positive_integer(value, field_name) when is_integer(value) do
    if value > 0 do
      {:ok, value}
    else
      {:error, :invalid_request, "#{field_name} must be a positive integer"}
    end
  end

  defp normalize_optional_positive_integer(value, field_name) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:ok, nil}
    else
      case Integer.parse(trimmed) do
        {parsed, ""} when parsed > 0 ->
          {:ok, parsed}

        _ ->
          {:error, :invalid_request, "#{field_name} must be a positive integer"}
      end
    end
  end

  defp normalize_optional_positive_integer(_value, field_name),
    do: {:error, :invalid_request, "#{field_name} must be a positive integer"}

  defp worker_json(worker) do
    Map.merge(
      %{
        id: worker.id,
        worker_id: worker.worker_id,
        display_name: worker.display_name,
        adapter: worker.adapter,
        endpoint_url: worker.endpoint_url,
        health_endpoint_url: worker.health_endpoint_url,
        health_path: worker.health_path,
        health_timeout_ms: worker.health_timeout_ms,
        probe_interval_ms: worker.probe_interval_ms,
        capabilities: worker.capabilities || [],
        enabled: worker.enabled,
        health_status: worker.health_status,
        health_reason: worker.health_reason,
        flapping: worker.flapping || false,
        flapping_transition_count: worker.flapping_transition_count || 0,
        flapping_window_size: worker.flapping_window_size || 0,
        alert_active: worker.alert_active || false,
        alert_state: worker.alert_state,
        alert_reason: worker.alert_reason,
        consecutive_failures: worker.consecutive_failures || 0,
        header_keys: worker |> Map.get(:headers, %{}) |> Map.keys() |> Enum.sort(),
        metadata: worker.metadata || %{},
        recent_probe_results: normalize_probe_results(worker.recent_probe_results),
        active_assignment_count: Map.get(worker, :active_assignment_count, 0),
        active_assignments: normalize_active_assignments(Map.get(worker, :active_assignments, [])),
        notification_audit_active: Map.get(worker, :notification_audit_active, false),
        notification_audit_alert_id: Map.get(worker, :notification_audit_alert_id),
        notification_audit_alert_status: Map.get(worker, :notification_audit_alert_status),
        notification_audit_notification_count: Map.get(worker, :notification_audit_notification_count, 0),
        notification_audit_last_notification_at:
          format_datetime(Map.get(worker, :notification_audit_last_notification_at)),
        notification_audit_suppressed_until: format_datetime(Map.get(worker, :notification_audit_suppressed_until)),
        last_health_transition_at: format_datetime(worker.last_health_transition_at),
        last_healthy_at: format_datetime(worker.last_healthy_at),
        last_failure_at: format_datetime(worker.last_failure_at),
        inserted_at: format_datetime(worker.inserted_at),
        updated_at: format_datetime(worker.updated_at)
      },
      worker
      |> AnalysisWorkerAlertRouter.routed_alert_context()
      |> Map.merge(AnalysisWorkerAlertRouter.notification_policy_context(worker))
    )
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp normalize_probe_results(results) do
    results
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn result ->
      %{
        checked_at: Map.get(result, "checked_at") || Map.get(result, :checked_at),
        status: Map.get(result, "status") || Map.get(result, :status),
        reason: Map.get(result, "reason") || Map.get(result, :reason)
      }
    end)
  end

  defp normalize_active_assignments(assignments) do
    assignments
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn assignment ->
      %{
        relay_session_id: Map.get(assignment, :relay_session_id),
        branch_id: Map.get(assignment, :branch_id),
        worker_id: Map.get(assignment, :worker_id),
        display_name: Map.get(assignment, :display_name),
        adapter: Map.get(assignment, :adapter),
        capabilities: List.wrap(Map.get(assignment, :capabilities, [])),
        selection_mode: Map.get(assignment, :selection_mode),
        requested_capability: Map.get(assignment, :requested_capability),
        registry_managed?: Map.get(assignment, :registry_managed?, false)
      }
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp camera_analysis_workers do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_analysis_workers,
      CameraAnalysisWorkers
    )
  end

  defp get_scope(conn), do: conn.assigns[:current_scope]

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) when is_binary(permission) do
    scope = conn.assigns[:current_scope]
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end
end
