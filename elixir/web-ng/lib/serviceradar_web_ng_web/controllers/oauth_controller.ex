defmodule ServiceRadarWebNGWeb.OAuthController do
  @moduledoc """
  OAuth2 Token endpoint controller.

  Implements the OAuth2 Client Credentials grant flow for API access.

  ## Token Endpoint

  POST /oauth/token

  Accepts the following grant types:
  - `client_credentials` - Exchange client_id and client_secret for an access token
  - `authorization_code` - MCP PKCE code exchange (`serviceradar-mcp`)
  - `refresh_token` - Rotate an MCP refresh token while the IdP session is live
  - `password` - Resource-owner password (not used for MCP)

  ## Request Format

  Content-Type: application/x-www-form-urlencoded

  ```
  grant_type=client_credentials
  &client_id=<uuid>
  &client_secret=<secret>
  &scope=read write (optional)
  ```

  Or using Basic Auth:

  ```
  Authorization: Basic <base64(client_id:client_secret)>
  grant_type=client_credentials
  &scope=read write (optional)
  ```

  ## Response Format

  Success (200):
  ```json
  {
    "access_token": "<jwt>",
    "token_type": "Bearer",
    "expires_in": 3600,
    "scope": "read write"
  }
  ```

  Error (400/401):
  ```json
  {
    "error": "invalid_client",
    "error_description": "Invalid client credentials"
  }
  ```
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.Constants
  alias ServiceRadar.Identity.OAuthClient
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Security.Lockouts
  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Mcp.OAuth
  alias ServiceRadarWebNG.Mcp.OAuth.Server
  alias ServiceRadarWebNGWeb.ClientIP
  alias ServiceRadarWebNGWeb.FeatureFlags

  require Logger

  # Default token TTL: 1 hour
  @default_ttl_seconds 3600
  # Per-grant rate limits live in
  # `config :serviceradar_core, ServiceRadar.Security.RateLimiter`
  # as the `:oauth_password_grant` and `:oauth_client_credentials`
  # buckets. The OAuth `/token` endpoint is multiplexed by
  # `grant_type`, so the rate-limit check stays inline here rather
  # than at the pipeline level.

  @doc """
  OAuth2 token endpoint.

  Handles the token exchange for supported grant types.
  """
  def token(conn, params) do
    case params["grant_type"] do
      "client_credentials" ->
        handle_client_credentials(conn, params)

      "password" ->
        handle_password(conn, params)

      "authorization_code" ->
        handle_mcp_grant(conn, params, &handle_authorization_code/2)

      "refresh_token" ->
        handle_mcp_grant(conn, params, &handle_refresh_token/2)

      nil ->
        error_response(conn, 400, "invalid_request", "Missing grant_type parameter")

      grant_type ->
        error_response(
          conn,
          400,
          "unsupported_grant_type",
          "Grant type '#{grant_type}' is not supported"
        )
    end
  end

  defp handle_mcp_grant(conn, params, fun) do
    if FeatureFlags.mcp_enabled?() do
      fun.(conn, params)
    else
      error_response(
        conn,
        400,
        "unsupported_grant_type",
        "Grant type '#{params["grant_type"]}' is not supported"
      )
    end
  end

  defp handle_authorization_code(conn, params) do
    with :ok <- rate_limit(conn, :oauth_authorization_code),
         {:ok, tokens} <- Server.exchange_code(params) do
      token_json(conn, tokens)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        rate_limited_response(conn, retry_after)

      {:error, reason} ->
        oauth_grant_error(conn, reason)
    end
  end

  defp handle_refresh_token(conn, params) do
    with :ok <- rate_limit(conn, :oauth_authorization_code),
         {:ok, tokens} <- Server.refresh(params) do
      token_json(conn, tokens)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        rate_limited_response(conn, retry_after)

      {:error, reason} ->
        oauth_grant_error(conn, reason)
    end
  end

  defp rate_limit(conn, bucket) do
    case RateLimiter.check_and_record(bucket, get_client_ip(conn)) do
      {:error, retry_after} -> {:error, retry_after}
      :ok -> :ok
    end
  end

  defp token_json(conn, tokens) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> json(tokens)
  end

  defp oauth_grant_error(conn, :invalid_client) do
    error_response(conn, 401, "invalid_client", "Invalid client")
  end

  defp oauth_grant_error(conn, :invalid_grant) do
    error_response(conn, 400, "invalid_grant", "Invalid or expired authorization grant")
  end

  defp oauth_grant_error(conn, :unauthorized_client) do
    error_response(conn, 400, "unauthorized_client", "This client is not allowed to use this grant")
  end

  defp oauth_grant_error(conn, _) do
    error_response(conn, 400, "invalid_request", "Invalid token request")
  end

  defp handle_password(conn, params) do
    username = params["username"]
    password = params["password"]

    cond do
      is_nil(username) or is_nil(password) ->
        error_response(conn, 400, "invalid_request", "Missing username or password")

      Lockouts.active_lockout(username) ->
        Logger.warning("OAuth password grant against locked account: #{username}")
        error_response(conn, 423, "account_locked", "Account temporarily locked")

      true ->
        do_handle_password(conn, params, username, password)
    end
  end

  defp do_handle_password(conn, params, username, password) do
    client_ip = get_client_ip(conn)

    case RateLimiter.check_and_record(:oauth_password_grant, client_ip) do
      {:error, retry_after} ->
        rate_limited_response(conn, retry_after)

      :ok ->
        actor = SystemActor.system(:oauth_token)
        scopes = parse_scopes(params["scope"] || "read write")
        scopes_atoms = Enum.map(scopes, &scope_to_atom/1)
        extra_claims = %{"scope" => Enum.join(scopes, " ")}

        with {:ok, user} <-
               User.authenticate(username, password, actor: actor),
             {:ok, token, _full_claims} <-
               Guardian.create_api_token(user,
                 scopes: scopes_atoms,
                 claims: extra_claims,
                 ttl: {@default_ttl_seconds, :second}
               ) do
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("pragma", "no-cache")
          |> send_resp(
            200,
            Jason.encode!(%{
              access_token: token,
              token_type: "Bearer",
              expires_in: @default_ttl_seconds,
              scope: Enum.join(scopes, " ")
            })
          )
        else
          {:error, reason} when reason in [:invalid_credentials, :authentication_failed] ->
            Lockouts.record_failed_login(username, %{
              ip: client_ip,
              route: conn.request_path,
              method: "oauth_password_grant"
            })

            error_response(conn, 401, "invalid_grant", "Invalid username or password")

          {:error, %Ash.Error.Invalid{}} ->
            Lockouts.record_failed_login(username, %{
              ip: client_ip,
              route: conn.request_path,
              method: "oauth_password_grant"
            })

            error_response(conn, 401, "invalid_grant", "Invalid username or password")

          {:error, reason} ->
            Logger.error("Failed to create password grant token: #{inspect(reason)}")
            error_response(conn, 500, "server_error", "Failed to generate access token")
        end
    end
  end

  defp handle_client_credentials(conn, params) do
    client_ip = get_client_ip(conn)

    case RateLimiter.check_and_record(:oauth_client_credentials, client_ip) do
      {:error, retry_after} ->
        rate_limited_response(conn, retry_after)

      :ok ->
        # Extract credentials from Basic Auth header or request body
        case extract_credentials(conn, params) do
          {:ok, client_id, client_secret} ->
            authenticate_client(conn, client_id, client_secret, params)

          {:error, reason} ->
            error_response(conn, 401, "invalid_client", reason)
        end
    end
  end

  defp extract_credentials(conn, params) do
    # First try Basic Auth header
    case get_basic_auth(conn) do
      {:ok, client_id, client_secret} ->
        {:ok, client_id, client_secret}

      :not_found ->
        # Fall back to request body
        client_id = params["client_id"]
        client_secret = params["client_secret"]

        if client_id && client_secret do
          {:ok, client_id, client_secret}
        else
          {:error, "Missing client credentials"}
        end
    end
  end

  defp get_basic_auth(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [client_id, client_secret] <- String.split(decoded, ":", parts: 2) do
      {:ok, client_id, client_secret}
    else
      _ -> :not_found
    end
  end

  defp authenticate_client(conn, client_id, client_secret, params) do
    actor = SystemActor.system(:oauth_token)

    # Validate the client_id is a valid UUID
    case Ecto.UUID.cast(client_id) do
      {:ok, uuid} ->
        # Authenticate using the OAuthClient resource.
        # Pass the system actor so the read is authorized (the `:authenticate`
        # bypass runs with a nil actor otherwise); previously `actor` was only
        # used below for record_use, so valid credentials were rejected.
        case OAuthClient.authenticate(uuid, client_secret, actor: actor) do
          {:ok, client} ->
            # Validate and filter requested scopes
            requested_scopes = parse_scopes(params["scope"])
            granted_scopes = validate_scopes(requested_scopes, client.scopes)

            if not OAuth.client_credentials_enabled?() and Enum.member?(granted_scopes, "mcp") do
              error_response(
                conn,
                400,
                "unauthorized_client",
                "MCP client credentials are disabled"
              )
            else
              ip = get_client_ip(conn)
              OAuthClient.record_use(client, %{last_used_ip: ip}, actor: actor)
              issue_token(conn, client, granted_scopes)
            end

          {:error, _} ->
            Logger.warning("OAuth client authentication failed for client_id: #{client_id}")
            error_response(conn, 401, "invalid_client", "Invalid client credentials")
        end

      :error ->
        error_response(conn, 401, "invalid_client", "Invalid client_id format")
    end
  end

  defp parse_scopes(nil), do: []
  defp parse_scopes(scope) when is_binary(scope), do: String.split(scope, ~r/[\s,]+/, trim: true)

  defp validate_scopes([], client_scopes), do: client_scopes

  defp validate_scopes(requested, client_scopes) do
    # Only grant scopes that the client has
    Enum.filter(requested, &(&1 in client_scopes))
  end

  defp scope_to_atom(scope), do: ServiceRadarWebNG.Api.OauthScopes.to_atom(scope)

  defp issue_token(conn, client, scopes) do
    # Load the user for the token
    actor = SystemActor.system(:oauth_token)

    case User.get_by_id(client.user_id, actor: actor) do
      {:ok, user} ->
        scopes = permitted_scopes(user, scopes)

        if scopes == [] do
          error_response(
            conn,
            403,
            "unauthorized_client",
            "No permitted scopes for this account"
          )
        else
          issue_token_for_user(conn, client, user, scopes)
        end

      {:error, _} ->
        Logger.error("OAuth client #{client.id} has invalid user_id #{client.user_id}")
        error_response(conn, 500, "server_error", "Client configuration error")
    end
  end

  defp issue_token_for_user(conn, client, user, scopes) do
    extra_claims = %{
      "client_id" => to_string(client.id),
      "scope" => Enum.join(scopes, " ")
    }

    case Guardian.create_api_token(user,
           scopes: Enum.map(scopes, &scope_to_atom/1),
           claims: extra_claims,
           ttl: {@default_ttl_seconds, :second}
         ) do
      {:ok, token, _full_claims} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")
        |> send_resp(
          200,
          Jason.encode!(%{
            access_token: token,
            token_type: "Bearer",
            expires_in: @default_ttl_seconds,
            scope: Enum.join(scopes, " ")
          })
        )

      {:error, reason} ->
        Logger.error("Failed to create access token: #{inspect(reason)}")
        error_response(conn, 500, "server_error", "Failed to generate access token")
    end
  end

  defp permitted_scopes(user, scopes) do
    if RBAC.has_permission?(user, Constants.mcp_manage_permission()) do
      scopes
    else
      List.delete(scopes, "mcp")
    end
  end

  defp get_client_ip(conn) do
    ClientIP.get(conn)
  end

  defp error_response(conn, status, error, description) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(
      status,
      Jason.encode!(%{
        error: error,
        error_description: description
      })
    )
  end

  defp rate_limited_response(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> error_response(
      429,
      "slow_down",
      "Too many authentication attempts. Please try again later."
    )
  end
end
