defmodule ServiceRadarWebNGWeb.DashboardPackageAssetController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Plugins.Storage

  def show(conn, %{"id" => id}) do
    scope = conn.assigns[:current_scope]

    with {:ok, %DashboardPackage{} = package} <- Dashboards.get_package(id, scope: scope),
         :ok <- ensure_renderer_available(package),
         {:ok, blob} <- Storage.fetch_blob(package.wasm_object_key) do
      send_renderer_blob(conn, blob, package)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("dashboard renderer not found")
    end
  end

  defp ensure_renderer_available(%DashboardPackage{
         status: :enabled,
         verification_status: "verified",
         wasm_object_key: key
       })
       when is_binary(key) and key != "" do
    :ok
  end

  defp ensure_renderer_available(_package), do: {:error, :not_available}

  defp send_renderer_blob(conn, {:binary, payload}, %DashboardPackage{} = package) do
    conn
    |> put_resp_content_type(renderer_content_type(package))
    |> put_cache_headers(package.content_hash)
    |> send_resp(200, payload)
  end

  defp send_renderer_blob(conn, {:file, path}, %DashboardPackage{} = package) do
    conn
    |> put_resp_content_type(renderer_content_type(package))
    |> put_cache_headers(package.content_hash)
    |> send_file(200, path)
  end

  defp renderer_content_type(%DashboardPackage{renderer: %{"kind" => "browser_module"}}),
    do: "text/javascript"

  defp renderer_content_type(_package), do: "application/wasm"

  defp put_cache_headers(conn, content_hash) when is_binary(content_hash) and content_hash != "" do
    conn
    |> put_resp_header("etag", ~s("#{content_hash}"))
    |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
  end

  defp put_cache_headers(conn, _content_hash) do
    put_resp_header(conn, "cache-control", "private, max-age=300")
  end
end
