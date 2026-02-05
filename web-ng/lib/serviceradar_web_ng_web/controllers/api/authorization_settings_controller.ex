defmodule ServiceRadarWebNG.Api.AuthorizationSettingsController do
  @moduledoc """
  JSON API controller for authorization settings management.

  Provides endpoints for reading and updating default role and role mappings.
  """

  use ServiceRadarWebNGWeb, :controller
  use Permit.Phoenix.Controller,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Identity.AuthorizationSettings

  require Ash.Query

  alias ServiceRadar.Identity.AuthorizationSettings

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  GET /api/admin/authorization-settings

  Returns the singleton authorization settings (creates defaults if missing).
  """
  def show(conn, _params) do
    scope = conn.assigns.current_scope

    case get_or_create_settings(scope) do
      {:ok, settings} -> json(conn, settings_to_json(settings))
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  PUT /api/admin/authorization-settings

  Updates default role and role mappings.
  """
  def update(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, settings} <- get_or_create_settings(scope),
         {:ok, attrs} <- normalize_attrs(params) do
      settings
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> Ash.update(scope: scope)
      |> case do
        {:ok, updated} -> json(conn, settings_to_json(updated))
        {:error, error} -> {:error, error}
      end
    else
      {:error, :invalid_role} ->
        return_error(conn, :bad_request, "default_role must be one of: viewer, operator, admin")

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_or_create_settings(scope) do
    case AuthorizationSettings
         |> Ash.Query.for_read(:get_singleton, %{}, scope: scope)
         |> Ash.read_one(scope: scope) do
      {:ok, nil} ->
        AuthorizationSettings
        |> Ash.Changeset.for_create(:create, %{}, scope: scope)
        |> Ash.create(scope: scope)

      {:ok, settings} ->
        {:ok, settings}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_attrs(params) do
    with {:ok, default_role} <- normalize_role(params["default_role"]) do
      attrs = %{}

      attrs =
        if is_nil(default_role) do
          attrs
        else
          Map.put(attrs, :default_role, default_role)
        end

      attrs =
        if is_nil(params["role_mappings"]) do
          attrs
        else
          Map.put(attrs, :role_mappings, params["role_mappings"])
        end

      {:ok, attrs}
    end
  end

  defp normalize_role(nil), do: {:ok, nil}
  defp normalize_role(""), do: {:ok, nil}
  defp normalize_role("viewer"), do: {:ok, :viewer}
  defp normalize_role("operator"), do: {:ok, :operator}
  defp normalize_role("admin"), do: {:ok, :admin}
  defp normalize_role(_), do: {:error, :invalid_role}

  @impl true
  def skip_preload do
    [:show, :update]
  end

  @impl true
  def fetch_subject(%{assigns: %{current_scope: %{user: user}}}) when not is_nil(user), do: user
  def fetch_subject(_conn), do: :anonymous

  @impl true
  def handle_unauthorized(_action, conn) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ServiceRadarWebNGWeb.ErrorJSON)
    |> render(:"403")
    |> halt()
  end

  defp settings_to_json(settings) do
    %{
      default_role: settings.default_role,
      role_mappings: settings.role_mappings
    }
  end

  defp return_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
