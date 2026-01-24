defmodule ServiceRadarWebNG.Api.PluginAssignmentController do
  @moduledoc """
  JSON API controller for plugin assignments to agents.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Plugins

  action_fallback ServiceRadarWebNG.Api.FallbackController

  def index(conn, params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)
      assignments = Plugins.list_assignments(params, scope: scope)
      json(conn, Enum.map(assignments, &assignment_to_json/1))
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      attrs = %{
        agent_uid: params["agent_uid"],
        plugin_package_id: params["plugin_package_id"],
        enabled: params["enabled"],
        interval_seconds: params["interval_seconds"],
        timeout_seconds: params["timeout_seconds"],
        params: params["params"],
        permissions_override: params["permissions_override"],
        resources_override: params["resources_override"]
      }

      case Plugins.create_assignment(attrs, scope: scope) do
        {:ok, assignment} ->
          conn
          |> put_status(:created)
          |> json(assignment_to_json(assignment))

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      attrs = %{
        enabled: params["enabled"],
        interval_seconds: params["interval_seconds"],
        timeout_seconds: params["timeout_seconds"],
        params: params["params"],
        permissions_override: params["permissions_override"],
        resources_override: params["resources_override"]
      }

      case Plugins.update_assignment(id, attrs, scope: scope) do
        {:ok, assignment} -> json(conn, assignment_to_json(assignment))
        {:error, error} -> {:error, error}
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn) do
      scope = get_scope(conn)

      case Plugins.delete_assignment(id, scope: scope) do
        {:ok, _assignment} -> send_resp(conn, :no_content, "")
        {:error, error} -> {:error, error}
      end
    end
  end

  defp assignment_to_json(assignment) do
    %{
      id: assignment.id,
      agent_uid: assignment.agent_uid,
      plugin_package_id: assignment.plugin_package_id,
      enabled: assignment.enabled,
      interval_seconds: assignment.interval_seconds,
      timeout_seconds: assignment.timeout_seconds,
      params: assignment.params,
      permissions_override: assignment.permissions_override,
      resources_override: assignment.resources_override,
      inserted_at: format_datetime(assignment.inserted_at),
      updated_at: format_datetime(assignment.updated_at)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp get_scope(conn) do
    conn.assigns[:current_scope]
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{} -> :ok
      _ -> {:error, :unauthorized}
    end
  end
end
