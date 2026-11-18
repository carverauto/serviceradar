defmodule ServiceRadarWebNGWeb.Api.CameraSemanticSearchController do
  @moduledoc """
  Authenticated natural-language semantic clip search across authorized recorded
  cameras (`GET /api/cameras/search`, `Stage 4.1`, `design.md` `5.3`).
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNGWeb.CameraSemanticSearch

  def index(conn, params) do
    conn = private_headers(conn)

    extra_opts =
      Map.get_lazy(conn.private, :camera_semantic_search_opts, fn ->
        Application.get_env(:serviceradar_web_ng, :camera_semantic_search_opts, [])
      end)

    case CameraSemanticSearch.execute(conn.assigns[:current_scope], params, extra_opts) do
      {:ok, data} ->
        json(conn, %{data: data})

      {:error, reason} ->
        search_error(conn, reason)
    end
  end

  defp private_headers(conn) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp search_error(conn, :search_embedder_unavailable) do
    conn
    |> put_resp_header("retry-after", "5")
    |> put_status(:service_unavailable)
    |> json(%{error: "search_embedder_unavailable"})
  end

  defp search_error(conn, :unauthorized) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
  end

  defp search_error(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden"})
  end

  defp search_error(conn, reason)
       when reason in [
              :invalid_request,
              :invalid_query,
              :invalid_camera_source_id,
              :invalid_time_window,
              :window_too_large,
              :invalid_object_class,
              :invalid_color,
              :invalid_limit
            ] do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request"})
  end

  defp search_error(conn, _other) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "semantic_search_unavailable"})
  end
end
