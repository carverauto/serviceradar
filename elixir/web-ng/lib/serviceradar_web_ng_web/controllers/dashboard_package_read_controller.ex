defmodule ServiceRadarWebNGWeb.DashboardPackageReadController do
  @moduledoc """
  Read-only API for installed dashboard packages.

  Endpoints

      GET /api/v1/dashboard-packages          # list all installed packages
      GET /api/v1/dashboard-packages/:id      # one package by manifest id or internal id

  Gated by `:api_key_auth` (JWT bearer auth) and the `dashboards.packages.view_all`
  RBAC permission. Unlike the publish endpoints, this does NOT require the
  `dashboard.publish` OAuth scope — reading what is installed is not a
  publishing right, and a publish-scoped token is not required.

  The response excludes `signature`, `settings_schema`, and `wasm_object_key`.
  A version-visibility endpoint must not become a way to read signing material
  or storage layout.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC

  require Logger

  @view_all_permission "dashboards.packages.view_all"

  @doc """
  GET /api/v1/dashboard-packages — list all installed packages with their instances.
  """
  def index(conn, _params) do
    case enforce_permission(conn) do
      :ok ->
        scope = conn.assigns[:current_scope]
        packages = Dashboards.list_packages_with_instances(scope: scope)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{packages: Enum.map(packages, &serialize_package/1)})

      {:error, :forbidden} ->
        forbidden(conn)
    end
  end

  @doc """
  GET /api/v1/dashboard-packages/:id — one package by manifest id or internal UUID.
  """
  def show(conn, %{"id" => id}) do
    case enforce_permission(conn) do
      :ok ->
        scope = conn.assigns[:current_scope]

        case Dashboards.get_package_by_manifest_id_or_id(id, scope: scope) do
          {:ok, package} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> json(%{package: serialize_package(package)})

          {:error, :not_found} ->
            not_found(conn, id)

          {:error, reason} ->
            Logger.warning("dashboard_package_read show failed", id: id, reason: inspect(reason))
            internal_error(conn)
        end

      {:error, :forbidden} ->
        forbidden(conn)
    end
  end

  defp enforce_permission(conn) do
    scope = conn.assigns[:current_scope]

    if scope && RBAC.can?(scope, @view_all_permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp serialize_package(package) do
    %{
      id: package.id,
      dashboard_id: package.dashboard_id,
      name: package.name,
      version: package.version,
      description: package.description,
      vendor: package.vendor,
      content_hash: package.content_hash,
      capabilities: package.capabilities,
      status: package.status,
      source_type: package.source_type,
      inserted_at: package.inserted_at,
      updated_at: package.updated_at,
      instances: Enum.map(package.instances || [], &serialize_instance/1)
    }
  end

  defp serialize_instance(instance) do
    %{
      id: instance.id,
      route_slug: instance.route_slug,
      enabled: instance.enabled,
      name: instance.name
    }
  end

  defp forbidden(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:forbidden)
    |> json(%{error: "forbidden", permission: @view_all_permission})
  end

  defp not_found(conn, id) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:not_found)
    |> json(%{error: "not_installed", id: id})
  end

  defp internal_error(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:internal_server_error)
    |> json(%{error: "internal_error"})
  end
end
