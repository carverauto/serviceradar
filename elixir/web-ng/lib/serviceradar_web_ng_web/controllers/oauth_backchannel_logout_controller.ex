defmodule ServiceRadarWebNGWeb.OAuthBackchannelLogoutController do
  @moduledoc """
  OIDC back-channel logout for MCP grants.

  POST /oauth/backchannel-logout with `logout_token`. Matching MCP grants
  (same IdP `iss` + `sid`) are revoked immediately.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Mcp.OAuth.Server
  alias ServiceRadarWebNGWeb.Auth.OIDCClient
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.FeatureFlags

  def create(conn, params) do
    if FeatureFlags.mcp_enabled?() do
      case RateLimiter.check_and_record(:oauth_authorization_code, ClientIP.get(conn)) do
        {:error, retry_after} ->
          conn
          |> put_resp_header("retry-after", to_string(retry_after))
          |> put_status(:too_many_requests)
          |> json(%{error: "slow_down"})

        :ok ->
          handle_logout(conn, params["logout_token"])
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "not_found"})
    end
  end

  defp handle_logout(conn, token) when is_binary(token) and token != "" do
    case verify_logout_token(token) do
      {:ok, %{"iss" => iss, "sid" => sid}} when is_binary(iss) and is_binary(sid) and sid != "" ->
        Server.revoke_by_idp_sid(iss, sid)
        send_resp(conn, 200, "")

      {:ok, _} ->
        send_resp(conn, 200, "")

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", error_description: "Invalid logout_token"})
    end
  end

  defp handle_logout(conn, _) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", error_description: "Missing logout_token"})
  end

  defp verify_logout_token(token) do
    case Application.get_env(:serviceradar_web_ng, :mcp_logout_token_verifier) do
      fun when is_function(fun, 1) -> fun.(token)
      _ -> OIDCClient.verify_logout_token(token)
    end
  end
end
