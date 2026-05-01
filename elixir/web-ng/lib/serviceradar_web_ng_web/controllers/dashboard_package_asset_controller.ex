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
      send_wasm_blob(conn, blob, package.content_hash)
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

  defp send_wasm_blob(conn, {:binary, payload}, content_hash) do
    conn
    |> put_resp_content_type("application/wasm")
    |> put_cache_headers(content_hash)
    |> send_resp(200, payload)
  end

  defp send_wasm_blob(conn, {:file, path}, content_hash) do
    conn
    |> put_resp_content_type("application/wasm")
    |> put_cache_headers(content_hash)
    |> send_file(200, path)
  end

  defp put_cache_headers(conn, content_hash) when is_binary(content_hash) and content_hash != "" do
    conn
    |> put_resp_header("etag", ~s("#{content_hash}"))
    |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
  end

  defp put_cache_headers(conn, _content_hash) do
    put_resp_header(conn, "cache-control", "private, max-age=300")
  end
end
