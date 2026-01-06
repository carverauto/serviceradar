defmodule ServiceRadarWebNGWeb.Plugs.ApiAuth do
  @moduledoc """
  API authentication plug supporting API keys, bearer tokens, and Ash API tokens.

  Checks for authentication in the following order:
  1. `Authorization: Bearer <token>` header (JWT or session token)
  2. `X-API-Key: <key>` header (Ash API token or legacy static key)

  ## Ash API Tokens

  API tokens created via the ServiceRadar.Identity.ApiToken resource are
  validated by hashing the provided token and comparing against stored hashes.
  Tokens have scopes (read, write, admin) that determine permissions.

  ## Legacy Configuration

  Configure static API keys in your config (for backward compatibility):

      config :serviceradar_web_ng, :api_auth,
        api_keys: ["key1", "key2"]

  For bearer tokens, the plug validates against the user session token system.
  """

  import Plug.Conn
  require Logger

  alias Ash.PlugHelpers
  alias ServiceRadarWebNG.Accounts.Scope

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
    tenant = token_tenant(token)
    opts = tenant_opts(tenant)
    subject_opts = Keyword.merge([authorize?: false], opts)

    # Bearer tokens are Ash JWT tokens
    # Use :serviceradar_web_ng as otp_app since that's where the signing_secret is configured
    # Jwt.verify returns {:ok, claims, resource} - we need to load the user from the subject claim
    case AshAuthentication.Jwt.verify(token, :serviceradar_web_ng, opts) do
      {:ok, claims, resource} ->
        with subject when is_binary(subject) <- claims["sub"],
             {:ok, user} <- AshAuthentication.subject_to_user(subject, resource, subject_opts) do
          tenant_id = Map.get(claims, "tenant") || user.tenant_id
          scope = Scope.for_user(user, active_tenant_id: tenant_id)
          {:ok, assign_scope(conn, scope, tenant_id)}
        else
          _ -> {:error, :unauthorized}
        end

      {:error, _reason} ->
        {:error, :unauthorized}

      :error ->
        {:error, :unauthorized}
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
    tenant_id = tenant_from_header(conn)

    if is_nil(tenant_id) do
      {:error, :unauthorized}
    else
      # Hash the token to compare against stored hash
      token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      token_prefix = String.slice(token, 0, 8)

      # Query for matching token using Ash (bypass authorization for token lookup)
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

      case Ash.read(query, authorize?: false, tenant: tenant_id) do
        {:ok, [api_token]} ->
          # Record the usage
          record_token_usage(api_token, conn)

          # Create scope with the token's user
          user = api_token.user

          scope = Scope.for_user(user, active_tenant_id: api_token.tenant_id)

          conn =
            conn
            |> assign_scope(scope, api_token.tenant_id)
            |> assign(:api_token, api_token)
            |> assign(:api_token_scope, api_token.scope)

          {:ok, conn}

        {:ok, []} ->
          {:error, :not_found}

        {:error, _} ->
          {:error, :not_found}
      end
    end
  end

  defp record_token_usage(api_token, conn) do
    # Get client IP
    client_ip =
      case get_req_header(conn, "x-forwarded-for") do
        [ip | _] -> ip
        _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
      end

    # Record usage asynchronously to not block the request
    Task.start(fn ->
      api_token
      |> Ash.Changeset.for_update(:record_use, %{last_used_ip: client_ip})
      |> Ash.update(authorize?: false, tenant: api_token.tenant_id)
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

  defp assign_scope(conn, %Scope{user: user} = scope, tenant_id) do
    partition_id = get_partition_id_from_request(conn)

    actor =
      if user do
        actor = %{
          id: user.id,
          tenant_id: tenant_id,
          role: user.role,
          email: user.email
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

    conn =
      if actor do
        PlugHelpers.set_actor(conn, actor)
      else
        conn
      end

    if tenant_id do
      PlugHelpers.set_tenant(conn, tenant_id)
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

  defp token_tenant(token) do
    case AshAuthentication.Jwt.peek(token) do
      {:ok, claims} -> Map.get(claims, "tenant")
      _ -> nil
    end
  end

  defp tenant_opts(nil), do: []
  defp tenant_opts(tenant), do: [tenant: tenant]

  defp tenant_from_header(conn) do
    case get_req_header(conn, "x-tenant-id") do
      [tenant_id | _] -> cast_uuid(tenant_id)
      _ -> nil
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
