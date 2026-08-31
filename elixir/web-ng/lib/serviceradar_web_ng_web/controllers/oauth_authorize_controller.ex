defmodule ServiceRadarWebNGWeb.OAuthAuthorizeController do
  @moduledoc """
  GET /oauth/authorize — MCP authorization-code + PKCE entry point.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Mcp.OAuth
  alias ServiceRadarWebNG.Mcp.OAuth.IdP
  alias ServiceRadarWebNG.Mcp.OAuth.RedirectURI
  alias ServiceRadarWebNG.Mcp.OAuth.Server
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.FeatureFlags

  def new(conn, params) do
    if FeatureFlags.mcp_enabled?() do
      case RateLimiter.check_and_record(:oauth_authorize, ClientIP.get(conn)) do
        {:error, retry_after} ->
          conn
          |> put_resp_header("retry-after", to_string(retry_after))
          |> put_status(:too_many_requests)
          |> json(%{error: "slow_down", error_description: "Too many authorize requests"})

        :ok ->
          authorize(conn, params)
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "not_found"})
    end
  end

  defp authorize(conn, params) do
    case validate_request(params) do
      {:ok, request} ->
        conn = put_session(conn, "mcp_oauth_request", request)
        user = conn.assigns[:current_scope] && conn.assigns.current_scope.user

        cond do
          is_nil(user) ->
            conn
            |> put_session(:user_return_to, "/oauth/consent")
            |> redirect(to: ~p"/users/log-in")

          not RBAC.can?(conn.assigns.current_scope, Constants.mcp_manage_permission()) ->
            redirect(
              conn,
              external:
                error_redirect(
                  request["redirect_uri"],
                  request["state"],
                  "access_denied",
                  "MCP access is not permitted for this account"
                )
            )

          Server.active_grant?(user, request["client_id"]) ->
            skip_consent(conn, user, request)

          true ->
            redirect(conn, to: ~p"/oauth/consent")
        end

      {:error, :redirect, uri, error, description} ->
        redirect(conn, external: error_redirect(uri, params["state"], error, description))

      {:error, _reason, description} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", error_description: description})
    end
  end

  defp skip_consent(conn, user, request) do
    case Server.complete_authorization(user, request, IdP.from_conn(conn)) do
      {:ok, _grant, url} ->
        redirect(conn, external: url)

      _ ->
        redirect(conn, to: ~p"/oauth/consent")
    end
  end

  defp validate_request(params) do
    client_id = params["client_id"]
    redirect_uri = params["redirect_uri"]
    challenge = params["code_challenge"]
    method = params["code_challenge_method"]
    response_type = params["response_type"]

    cond do
      client_id != OAuth.public_client_id() ->
        {:error, :invalid_client, "Unsupported client_id"}

      response_type != "code" ->
        {:error, :unsupported_response_type, "Only response_type=code is supported"}

      not RedirectURI.loopback?(redirect_uri) ->
        {:error, :invalid_request, "redirect_uri must be an RFC 8252 loopback URI"}

      method != "S256" or not is_binary(challenge) or challenge == "" ->
        redirect_error(redirect_uri, "invalid_request", "PKCE S256 code_challenge is required")

      true ->
        case OAuth.normalize_scope(params["scope"]) do
          {:ok, scope} ->
            if OAuth.scope_includes_mcp?(scope) do
              {:ok,
               %{
                 "client_id" => client_id,
                 "redirect_uri" => redirect_uri,
                 "state" => params["state"],
                 "code_challenge" => challenge,
                 "scope" => scope
               }}
            else
              redirect_error(redirect_uri, "invalid_scope", "scope must include mcp")
            end

          {:error, :invalid_scope} ->
            redirect_error(redirect_uri, "invalid_scope", "Requested scope is not allowed")
        end
    end
  end

  defp redirect_error(uri, error, description) when is_binary(uri) do
    {:error, :redirect, uri, error, description}
  end

  defp error_redirect(uri, state, error, description) do
    parsed = URI.parse(uri)

    query =
      (parsed.query || "")
      |> URI.decode_query()
      |> Map.merge(%{
        "error" => error,
        "error_description" => description
      })
      |> maybe_put_state(state)
      |> URI.encode_query()

    URI.to_string(%{parsed | query: query})
  end

  defp maybe_put_state(map, state) when is_binary(state) and state != "", do: Map.put(map, "state", state)

  defp maybe_put_state(map, _), do: map
end
