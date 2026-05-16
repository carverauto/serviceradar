defmodule ServiceRadarWebNGWeb.Api.RemoteAccessDesktopTargetController do
  @moduledoc """
  Authenticated API for authorized desktop remote-access targets.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.RemoteAccessDesktopTargets
  alias ServiceRadarWebNGWeb.FeatureFlags

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @remote_desktop_permission "devices.remote_access.rdp.open"

  def index(conn, _params) do
    with :ok <- require_remote_desktop_enabled(),
         :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @remote_desktop_permission),
         {:ok, targets} <- RemoteAccessDesktopTargets.list_authorized(get_scope(conn)) do
      json(conn, %{data: targets})
    else
      {:error, :remote_access_desktop_rdp_disabled} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "RDP remote access is not enabled"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "RDP remote access permission is required"})

      {:error, other} ->
        {:error, other}
    end
  end

  defp require_remote_desktop_enabled do
    if FeatureFlags.remote_access_desktop_rdp_enabled?() do
      :ok
    else
      {:error, :remote_access_desktop_rdp_disabled}
    end
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
