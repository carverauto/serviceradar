defmodule ServiceRadarWebNGWeb.OAuthController do
  @moduledoc """
  OAuth2 Token endpoint controller.

  Implements the OAuth2 Client Credentials grant flow for API access.

  ## Token Endpoint

  POST /oauth/token

  Accepts the following grant types:
  - `client_credentials` - Exchange client_id and client_secret for an access token

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

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.OAuthClient
  alias ServiceRadarWebNG.Auth.Guardian

  # Default token TTL: 1 hour
  @default_ttl_seconds 3600

  @doc """
  OAuth2 token endpoint.

  Handles the token exchange for supported grant types.
  """
  def token(conn, params) do
    case params["grant_type"] do
      "client_credentials" ->
        handle_client_credentials(conn, params)

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

  defp handle_client_credentials(conn, params) do
    # Extract credentials from Basic Auth header or request body
    case extract_credentials(conn, params) do
      {:ok, client_id, client_secret} ->
        authenticate_client(conn, client_id, client_secret, params)

      {:error, reason} ->
        error_response(conn, 401, "invalid_client", reason)
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
        # Authenticate using the OAuthClient resource
        case OAuthClient.authenticate(uuid, client_secret) do
          {:ok, client} ->
            # Validate and filter requested scopes
            requested_scopes = parse_scopes(params["scope"])
            granted_scopes = validate_scopes(requested_scopes, client.scopes)

            # Record usage
            ip = get_client_ip(conn)
            OAuthClient.record_use(client, %{last_used_ip: ip}, actor: actor)

            # Generate access token
            issue_token(conn, client, granted_scopes)

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

  defp issue_token(conn, client, scopes) do
    # Load the user for the token
    actor = SystemActor.system(:oauth_token)

    case ServiceRadar.Identity.User.get_by_id(client.user_id, actor: actor) do
      {:ok, user} ->
        # Create claims for the token
        claims = %{
          "typ" => "api",
          "sub" => to_string(user.id),
          "client_id" => to_string(client.id),
          "scope" => Enum.join(scopes, " ")
        }

        case Guardian.create_access_token(user,
               claims: claims,
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

      {:error, _} ->
        Logger.error("OAuth client #{client.id} has invalid user_id #{client.user_id}")
        error_response(conn, 500, "server_error", "Client configuration error")
    end
  end

  defp get_client_ip(conn) do
    # Check X-Forwarded-For header first (for proxied requests)
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        # Fall back to remote_ip
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
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
end
