defmodule ServiceRadarWebNGWeb.TopologyTileController do
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias ServiceRadar.NetworkDiscovery.World
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNGWeb.FeatureFlags

  plug(:authorize)

  def manifest(conn, _params) do
    case WorldCache.manifest() do
      {:ok, manifest} ->
        conn
        |> generation_headers(manifest)
        |> json(
          Map.take(manifest, [
            :layout_version,
            :generation,
            :extent,
            :algorithm_version,
            :zmax,
            :node_count,
            :relation_count,
            :observed_generation,
            :catching_up
          ])
        )

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, key} <- TileKey.parse(params),
         {:ok, tile} <- WorldCache.fetch(key) do
      etag = ~s("#{key.layout_version}:#{tile.revision}")
      transform = TileKey.transform(key)

      conn =
        conn
        |> generation_headers(%{layout_version: key.layout_version, generation: tile.generation})
        |> put_resp_header("cache-control", "private, no-cache")
        |> put_resp_header("etag", etag)
        |> put_resp_header("x-sr-god-view-schema", "3")
        |> put_resp_header("x-sr-topology-origin-x", Integer.to_string(transform.origin_x))
        |> put_resp_header("x-sr-topology-origin-y", Integer.to_string(transform.origin_y))
        |> put_resp_header("x-sr-topology-scale", Float.to_string(transform.scale))

      if matches_etag?(conn, etag) do
        send_resp(conn, :not_modified, "")
      else
        conn
        |> put_resp_content_type("application/vnd.apache.arrow.stream")
        |> send_resp(:ok, tile.payload)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def search(conn, %{"device_id" => id}) when is_binary(id) and byte_size(id) > 0 do
    with {:ok, %{world: world, manifest: manifest}} <- WorldCache.world(),
         {:ok, position} <- TopologyAtlas.search(world, id),
         {:ok, %{} = _authorized_position} <- World.lookup_device(conn.assigns.current_scope, manifest.layout_version, id) do
      conn
      |> generation_headers(manifest)
      |> json(%{
        layout_version: manifest.layout_version,
        generation: manifest.generation,
        device_id: position.device_id,
        x: position.x,
        y: position.y,
        zoom: position.min_zoom
      })
    else
      {:ok, nil} -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  def search(conn, _params), do: error(conn, :invalid_search)

  def relayout(conn, _params) do
    with {:ok, scope} <- authorize_relayout(conn.assigns.current_scope),
         {:ok, operation} <- World.request_relayout(scope) do
      conn |> put_status(:accepted) |> json(operation)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp authorize_relayout(scope) do
    case RBAC.authorize_current(scope, ["settings.networks.manage"]) do
      {:ok, current_scope} -> {:ok, current_scope}
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  defp authorize(conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with true <- FeatureFlags.god_view_enabled?(),
         %Scope{user: user} = scope when not is_nil(user) <- conn.assigns[:current_scope],
         {:ok, current_scope} <- RBAC.authorize_current(scope, ["analytics.view", "devices.view"]) do
      assign(conn, :current_scope, current_scope)
    else
      false -> conn |> error(:god_view_disabled) |> halt()
      {:error, _reason} -> conn |> error(:forbidden) |> halt()
      _ -> conn |> error(:unauthorized) |> halt()
    end
  end

  defp generation_headers(conn, manifest) do
    conn
    |> put_resp_header("x-sr-topology-layout-version", manifest.layout_version)
    |> put_resp_header("x-sr-topology-generation", Integer.to_string(manifest.generation))
  end

  defp matches_etag?(conn, expected) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn value -> String.trim(value) in ["*", expected, "W/" <> expected] end)
  end

  defp error(conn, reason) do
    {status, code} =
      case reason do
        :unauthorized -> {401, "unauthorized"}
        :forbidden -> {403, "forbidden"}
        :god_view_disabled -> {404, "god_view_disabled"}
        :invalid_tile -> {400, "invalid_tile"}
        :invalid_search -> {400, "invalid_search"}
        :not_found -> {404, "device_not_found"}
        :layout_changed -> {409, "layout_changed"}
        :busy -> {503, "tile_busy"}
        :not_ready -> {503, "world_not_ready"}
        :source_changed -> {503, "source_changed"}
        _ -> {503, "world_unavailable"}
      end

    conn = if status == 503, do: put_resp_header(conn, "retry-after", "1"), else: conn
    conn |> put_resp_header("cache-control", "no-store") |> put_status(status) |> json(%{error: code})
  end
end
