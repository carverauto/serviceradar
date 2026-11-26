defmodule ServiceRadarWebNGWeb.Api.HorizonProxyController do
  @moduledoc """
  Authenticated, RBAC-gated control-plane proxy for Horizon API endpoints.

  Allows `/dashboards/horizon` operators to query and manage Horizon resources
  (BGP watchlists, snapshots, ISP accountability reports, branch agent
  enrollment tokens) using their ServiceRadar session or JWT without exposing
  Horizon API keys to the browser.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.HorizonProxy
  alias ServiceRadarWebNG.RBAC

  plug(:put_json_format)

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  def proxy(conn, %{"version" => version, "path" => path_segments}) do
    accept = extract_accept_header(conn)

    with :ok <- require_authenticated(conn),
         {:ok, route} <-
           HorizonProxy.resolve_route(conn.method, version, path_segments, conn.request_path),
         :ok <- require_permission(conn, route.required_permission),
         {:ok, query_string} <- HorizonProxy.validate_query_string(conn.query_string),
         {:ok, upstream} <- HorizonProxy.resolve_upstream(),
         {:ok, body} <- encode_request_body(conn, route.method) do
      case HorizonProxy.forward(route, upstream, query_string: query_string, body: body, accept: accept) do
        {:ok, %{status: 204}} ->
          send_resp(conn, 204, "")

        {:ok, %{status: status, content_type: content_type, body: resp_body}} ->
          conn
          |> put_resp_header("content-type", content_type)
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(status, resp_body)

        {:error, :upstream_timeout} ->
          conn
          |> put_status(:gateway_timeout)
          |> json(%{error: "horizon_upstream_timeout"})

        {:error, :upstream_unavailable} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "horizon_upstream_unavailable"})
      end
    else
      {:error, :not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "horizon_not_configured"})

      {:error, :invalid_upstream_url} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "horizon_upstream_invalid"})

      {:error, :invalid_query} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_query"})

      {:error, :invalid_body} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_body"})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_json_format(conn, _opts), do: put_format(conn, "json")

  defp extract_accept_header(conn) do
    case get_req_header(conn, "accept") do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  defp encode_request_body(conn, method) when method in [:post, :patch] do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:ok, "{}"}

      params when is_map(params) ->
        case Jason.encode(params) do
          {:ok, encoded} -> {:ok, encoded}
          {:error, _} -> {:error, :invalid_body}
        end

      _ ->
        {:error, :invalid_body}
    end
  end

  defp encode_request_body(_conn, _method), do: {:ok, nil}

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end
end
