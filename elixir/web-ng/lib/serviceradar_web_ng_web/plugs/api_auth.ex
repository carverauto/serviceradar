defmodule ServiceRadarWebNGWeb.Plugs.ApiAuth do
  @moduledoc """
  API authentication plug supporting API keys, bearer tokens, and Guardian JWT tokens.

  This is a single-deployment UI. Schema context is implicit from the database
  connection's search_path, so this plug only validates authentication and does not
  perform additional routing.

  Checks for authentication in the following order:
  1. `Authorization: Bearer <token>` header (Guardian JWT session token or OAuth2 access token)
  2. `X-API-Key: <key>` header (Ash API token or legacy static key)

  ## OAuth2 Client Credentials

  Access tokens obtained via the OAuth2 client credentials flow (`/oauth/token`)
  are validated as Guardian JWT tokens. These tokens include:
  - `typ: "api"` - Identifies this as an API token
  - `client_id` - The OAuth client UUID
  - `scope` - Space-separated granted scopes

  When an OAuth client credential token is used, the following assigns are set:
  - `:oauth_client_id` - The client UUID
  - `:oauth_token_scope` - The granted scopes as a space-separated string

  ## Ash API Tokens

  API tokens created via the ServiceRadar.Identity.ApiToken resource are
  validated by hashing the provided token and comparing against stored hashes.
  Tokens have scopes (read, write, admin) that determine permissions.

  ## Legacy Configuration

  Configure static API keys in your config (for backward compatibility):

      config :serviceradar_web_ng, :api_auth,
        api_keys: ["key1", "key2"]

  For bearer tokens, the plug validates against Guardian JWT tokens.
  """

  import Plug.Conn
  require Logger

  alias Ash.PlugHelpers
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNGWeb.ClientIP

  def init(opts), do: opts

  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, conn} ->
        conn

      {:error, :unauthorized} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: "unauthorized", message: "Invalid or missing authentication"})
        )
        |> halt()
    end
  end

  defp authenticate(conn) do
    cond do
      # Check Bearer token first
      bearer_token = get_bearer_token(conn) ->
        validate_bearer_token(conn, bearer_token)

      # Check API key (Ash API tokens or legacy static keys)
      api_key = get_api_key(conn) ->
        validate_api_key(conn, api_key)

      # No auth provided
      true ->
        {:error, :unauthorized}
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp get_api_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key] -> String.trim(key)
      _ -> nil
    end
  end

  defp validate_bearer_token(conn, token) do
    # Validate Guardian JWT (user session tokens or API tokens)
    validate_guardian_jwt(conn, token)
  end

  defp validate_guardian_jwt(conn, token) do
    # Only accept bearer tokens intended for API authentication.
    # This prevents password reset tokens (typ=reset) and refresh tokens (typ=refresh)
    # from being used to call admin APIs.
    case verify_api_bearer_token(token) do
      {:ok, user, claims} ->
        scope = Scope.for_user(user)
        conn = assign_scope(conn, scope, user)

        # Check if this is an OAuth client credential token (typ=api with client_id)
        conn =
          if claims["typ"] == "api" && claims["client_id"] do
            conn
            |> assign(:oauth_client_id, claims["client_id"])
            # OAuth uses a space-separated scope string in responses; internally we
            # use the Guardian "scopes" claim (list), so normalize.
            |> assign(:oauth_token_scope, oauth_scope_string(claims))
          else
            conn
          end

        {:ok, conn}

      {:error, reason} ->
        Logger.debug("JWT validation failed: #{inspect(reason)}")
        {:error, :unauthorized}
    end
  end

  defp verify_api_bearer_token(token) do
    # Try access token first, then API token.
    with {:error, _} <- Guardian.verify_token(token, token_type: "access") do
      Guardian.verify_token(token, token_type: "api")
    end
  end

  defp oauth_scope_string(claims) do
    cond do
      is_binary(claims["scope"]) ->
        claims["scope"]

      is_list(claims["scopes"]) ->
        claims["scopes"] |> Enum.join(" ")

      true ->
        ""
    end
  end

  defp validate_api_key(conn, key) do
    # First try Ash API token validation
    case validate_ash_api_token(conn, key) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, :not_found} ->
        # Fall back to legacy static API keys
        validate_legacy_api_key(conn, key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_ash_api_token(conn, token) do
    # Hash the token to compare against stored hash
    token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    token_prefix = String.slice(token, 0, 8)

    case find_api_token(token_hash, token_prefix) do
      {:ok, api_token} ->
        # Record the usage
        record_token_usage(api_token, conn)

        # Create scope with the token's user
        user = api_token.user
        scope = Scope.for_user(user)

        conn =
          conn
          |> assign_scope(scope, user)
          |> assign(:api_token, api_token)
          |> assign(:api_token_scope, api_token.scope)

        {:ok, conn}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp record_token_usage(api_token, conn) do
    client_ip = ClientIP.get(conn)
    actor = SystemActor.system(:api_auth)

    # Record usage asynchronously to not block the request
    Task.start(fn ->
      api_token
      |> Ash.Changeset.for_update(:record_use, %{last_used_ip: client_ip})
      |> Ash.update(actor: actor, authorize?: false)
    end)
  end

  defp validate_legacy_api_key(conn, key) do
    valid_keys = get_api_keys()

    if key in valid_keys do
      # API key auth - create a system scope
      scope = %Scope{user: nil}

      conn =
        conn
        |> assign(:current_scope, scope)
        |> assign(:api_key_auth, true)

      {:ok, conn}
    else
      {:error, :unauthorized}
    end
  end

  defp get_api_keys do
    Application.get_env(:serviceradar_web_ng, :api_auth, [])
    |> Keyword.get(:api_keys, [])
  end

  defp find_api_token(token_hash, token_prefix) do
    require Ash.Query

    query =
      ServiceRadar.Identity.ApiToken
      |> Ash.Query.filter(
        token_prefix == ^token_prefix and
          token_hash == ^token_hash and
          enabled == true and
          is_nil(revoked_at) and
          (is_nil(expires_at) or expires_at > ^DateTime.utc_now())
      )
      |> Ash.Query.load(:user)

    # This read is part of authentication. Use an explicit internal actor so ApiToken
    # policies don't cause us to silently fall back to legacy static keys.
    actor = SystemActor.system(:api_auth)

    case Ash.read(query, actor: actor, authorize?: false) do
      {:ok, [api_token | _]} ->
        {:ok, api_token}

      {:ok, []} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp assign_scope(conn, %Scope{user: user} = scope, _user_data) do
    partition_id = get_partition_id_from_request(conn)

    actor =
      if user do
        permissions = RBAC.permissions_for_user(user)

        actor = %{
          id: user.id,
          role: user.role,
          email: user.email,
          role_profile_id: user.role_profile_id,
          permissions: permissions
        }

        if partition_id do
          Map.put(actor, :partition_id, partition_id)
        else
          actor
        end
      end

    conn =
      conn
      |> assign(:current_scope, scope)
      |> assign(:ash_actor, actor)
      |> assign(:current_partition_id, partition_id)

    if actor do
      PlugHelpers.set_actor(conn, actor)
    else
      conn
    end
  end

  defp get_partition_id_from_request(conn) do
    case get_req_header(conn, "x-partition-id") do
      [partition_id | _] when byte_size(partition_id) > 0 ->
        cast_uuid(partition_id)

      _ ->
        nil
    end
  end

  defp cast_uuid(nil), do: nil

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
