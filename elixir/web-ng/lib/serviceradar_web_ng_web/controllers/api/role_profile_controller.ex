defmodule ServiceRadarWebNGWeb.Api.RoleProfileController do
  @moduledoc """
  JSON API controller for RBAC role profiles.
  """

  use ServiceRadarWebNGWeb, :controller

  use Permit.Phoenix.Controller,
    authorization_module: ServiceRadarWebNGWeb.Authorization,
    resource_module: ServiceRadar.Identity.RoleProfile

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile

  require Ash.Query

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @impl true
  # Permit.Phoenix.Controller defaults to preloading records for actions like
  # :index/:show using Ecto-based loaders. These endpoints use Ash reads/writes
  # instead, so we opt out of Permit preloading to avoid RecordNotFoundError
  # 404s when the loader cannot resolve Ash resources.
  def skip_preload do
    [:index, :show, :create, :update, :delete, :catalog]
  end

  @impl true
  def fetch_subject(%{assigns: %{current_scope: %{user: user}}}) when not is_nil(user), do: user
  def fetch_subject(_conn), do: :anonymous

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    query = Ash.Query.sort(RoleProfile, system: :desc, name: :asc)

    case Ash.read(query, scope: scope) do
      {:ok, profiles} -> json(conn, Enum.map(profiles, &role_profile_to_json/1))
      {:error, error} -> {:error, error}
    end
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Ash.get(RoleProfile, id, scope: scope) do
      {:ok, profile} -> json(conn, role_profile_to_json(profile))
      {:error, error} -> {:error, error}
    end
  end

  def create(conn, params) do
    scope = conn.assigns.current_scope

    attrs = %{
      name: params["name"],
      description: params["description"],
      permissions: normalize_permissions(params["permissions"])
    }

    case RoleProfile
         |> Ash.Changeset.for_create(:create, attrs, scope: scope)
         |> Ash.create(scope: scope) do
      {:ok, profile} ->
        conn
        |> put_status(:created)
        |> json(role_profile_to_json(profile))

      {:error, error} ->
        {:error, error}
    end
  end

  def update(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, profile} <- Ash.get(RoleProfile, id, scope: scope) do
      attrs = %{
        name: Map.get(params, "name"),
        description: Map.get(params, "description"),
        permissions: normalize_permissions(Map.get(params, "permissions"))
      }

      attrs = attrs |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

      case profile
           |> Ash.Changeset.for_update(:update, attrs, scope: scope)
           |> Ash.update(scope: scope) do
        {:ok, updated} -> json(conn, role_profile_to_json(updated))
        {:error, error} -> {:error, error}
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, profile} <- Ash.get(RoleProfile, id, scope: scope) do
      case Ash.destroy(profile, scope: scope) do
        :ok -> json(conn, %{status: "deleted"})
        {:ok, _} -> json(conn, %{status: "deleted"})
        {:error, error} -> {:error, error}
      end
    end
  end

  def catalog(conn, _params) do
    json(conn, RBAC.catalog())
  end

  def handle_unauthorized(_action, conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden", message: "Not authorized"})
    |> halt()
  end

  defp normalize_permissions(nil), do: nil
  defp normalize_permissions(""), do: []

  defp normalize_permissions(permissions) when is_list(permissions), do: permissions

  defp normalize_permissions(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> []
    end
  end

  defp normalize_permissions(_), do: []

  defp role_profile_to_json(profile) do
    %{
      id: profile.id,
      system_name: profile.system_name,
      name: profile.name,
      description: profile.description,
      permissions: profile.permissions,
      system: profile.system
    }
  end
end
