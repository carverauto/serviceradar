defmodule ServiceRadarWebNGWeb.Api.EdgeSiteController do
  @moduledoc """
  JSON API for edge sites (customer locations running a NATS leaf server).

  Every action requires the `settings.edge.manage` RBAC permission, like
  `CollectorController`. Creating a site enqueues leaf provisioning
  (`ProvisionLeafWorker`); the bundle endpoint answers 409 `leaf_not_ready`
  until that has issued the leaf certificates.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Edge.EdgeSiteBundles
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  @permission "settings.edge.manage"

  @doc "GET /api/admin/edge-sites"
  def index(conn, _params) do
    with :ok <- authorize(conn) do
      query =
        EdgeSite
        |> Ash.Query.for_read(:read)
        |> Ash.Query.load(:nats_leaf_server)
        |> Ash.Query.sort(inserted_at: :desc)

      with {:ok, sites} <- Ash.read(query, actor: actor(conn)) do
        json(conn, %{data: Enum.map(sites, &site_to_json/1)})
      end
    end
  end

  @doc "POST /api/admin/edge-sites with `{name, slug?}`"
  def create(conn, params) do
    with :ok <- authorize(conn),
         {:ok, name} <- required_name(params) do
      attrs = maybe_put(%{name: name}, :slug, params["slug"])

      with {:ok, site} <-
             EdgeSite
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(actor: actor(conn)),
           {:ok, site} <- load_site(site.id, conn) do
        conn
        |> put_status(:created)
        |> json(%{data: site_to_json(site)})
      end
    else
      {:error, :name_required} ->
        conn |> put_status(:bad_request) |> json(%{error: "name is required"})

      other ->
        other
    end
  end

  @doc "GET /api/admin/edge-sites/:id"
  def show(conn, %{"id" => id}) do
    with :ok <- authorize(conn),
         {:ok, site} <- load_site(id, conn) do
      json(conn, %{data: site_to_json(site)})
    end
  end

  @doc "DELETE /api/admin/edge-sites/:id"
  def delete(conn, %{"id" => id}) do
    with :ok <- authorize(conn),
         {:ok, site} <- load_site(id, conn),
         :ok <- Ash.destroy(site, actor: actor(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  POST /api/admin/edge-sites/:id/bundle

  Returns the leaf bundle as `application/gzip`, or 409 `leaf_not_ready`.
  """
  def bundle(conn, %{"id" => id}) do
    with :ok <- authorize(conn),
         {:ok, site} <- load_site(id, conn) do
      case EdgeSiteBundles.build(site, site.nats_leaf_server) do
        {:ok, tarball, filename} ->
          conn
          |> put_resp_content_type("application/gzip")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
          |> send_resp(200, tarball)

        {:error, :leaf_not_ready} ->
          conn |> put_status(:conflict) |> json(%{error: "leaf_not_ready"})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp load_site(id, conn) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         {:ok, %EdgeSite{} = site} <-
           EdgeSite
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.load(:nats_leaf_server)
           |> Ash.read_one(actor: actor(conn)) do
      {:ok, site}
    else
      :error -> {:error, :not_found}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def site_to_json(site) do
    %{
      id: site.id,
      name: site.name,
      slug: site.slug,
      status: site.status,
      nats_leaf_url: site.nats_leaf_url,
      leaf_server: leaf_server_to_json(site.nats_leaf_server),
      inserted_at: site.inserted_at
    }
  end

  defp leaf_server_to_json(%{status: status, upstream_url: upstream_url}),
    do: %{status: status, upstream_url: upstream_url}

  defp leaf_server_to_json(_), do: nil

  defp required_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :name_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp required_name(_), do: {:error, :name_required}

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp authorize(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} = scope when not is_nil(user) ->
        if RBAC.can?(scope, @permission), do: :ok, else: {:error, :forbidden}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp actor(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> conn.assigns[:ash_actor] || user
      _ -> nil
    end
  end
end
