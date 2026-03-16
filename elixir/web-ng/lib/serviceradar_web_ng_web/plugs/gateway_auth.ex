defmodule ServiceRadarWebNGWeb.Plugs.GatewayAuth do
  @moduledoc """
  Plug for validating JWTs from API gateways (Kong, Ambassador, etc.).

  This plug intercepts requests when the auth mode is `passive_proxy` and
  validates the JWT passed by the gateway. It supports:

  - Configurable JWT header (default: Authorization)
  - JWKS-based signature verification
  - Static public key verification
  - Issuer and audience claim validation
  - JIT user provisioning

  ## Configuration

  Gateway JWT settings are stored in AuthSettings:
  - `jwt_header_name` - Header containing the JWT (default: "Authorization")
  - `jwt_public_key_pem` - Static public key in PEM format
  - `jwt_jwks_url` - JWKS URL for key fetching
  - `jwt_issuer` - Expected issuer claim
  - `jwt_audience` - Expected audience claim

  ## Usage

  Add to your pipeline when gateway auth is enabled:

      pipeline :gateway_auth do
        plug ServiceRadarWebNGWeb.Plugs.GatewayAuth
      end

  The plug will automatically skip validation when not in passive_proxy mode.
  """

  @behaviour Plug

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNG.Auth.Hooks
  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy

  require Logger

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case ConfigCache.get_settings() do
      {:ok, %{is_enabled: true, mode: :passive_proxy} = settings} ->
        validate_gateway_jwt(conn, settings)

      _ ->
        # Not in passive_proxy mode, skip gateway auth
        conn
    end
  end

  defp validate_gateway_jwt(conn, settings) do
    header_name = settings.jwt_header_name || "Authorization"

    case get_jwt_from_header(conn, header_name) do
      {:ok, token} ->
        case verify_and_decode_jwt(token, settings) do
          {:ok, claims} ->
            handle_authenticated_request(conn, claims, settings)

          {:error, reason} ->
            Logger.warning("Gateway JWT validation failed: #{inspect(reason)}")
            send_unauthorized(conn, "Invalid gateway token")
        end

      {:error, :no_token} ->
        # Don't enforce here. The UI's normal auth guardrails (require_authenticated_user)
        # will redirect to the login page. This plug's main job is to *establish*
        # a user context when a gateway injects an identity token.
        conn
    end
  end

  defp get_jwt_from_header(conn, header_name) do
    header_name_lower = String.downcase(header_name)

    case get_req_header(conn, header_name_lower) do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      ["bearer " <> token] -> {:ok, String.trim(token)}
      [token] when header_name_lower != "authorization" -> {:ok, String.trim(token)}
      _ -> {:error, :no_token}
    end
  end

  defp verify_and_decode_jwt(token, settings) do
    with {:ok, claims} <- decode_jwt(token),
         :ok <- verify_signature(token, settings),
         :ok <- verify_claims(claims, settings) do
      {:ok, claims}
    end
  end

  defp decode_jwt(token) do
    case String.split(token, ".") do
      [_header_b64, payload_b64, _signature] ->
        with {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, payload} <- Jason.decode(payload_json) do
          {:ok, payload}
        else
          _ -> {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp verify_signature(token, settings) do
    cond do
      # JWKS-based verification
      settings.jwt_jwks_url && settings.jwt_jwks_url != "" ->
        verify_with_jwks(token, settings.jwt_jwks_url)

      # Static public key verification
      settings.jwt_public_key_pem && settings.jwt_public_key_pem != "" ->
        verify_with_public_key(token, settings.jwt_public_key_pem)

      # No verification configured - trust the gateway
      true ->
        Logger.debug("Gateway JWT signature verification not configured, trusting gateway")
        :ok
    end
  end

  defp verify_with_jwks(token, jwks_url) do
    with {:ok, jwks} <- get_jwks(jwks_url),
         {:ok, jwk} <- find_matching_key(token, jwks) do
      verify_token_signature(token, jwk)
    end
  end

  defp get_jwks(jwks_url) do
    cache_key = "gateway_jwks:#{jwks_url}"

    case ConfigCache.get_cached(cache_key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        case fetch_jwks(jwks_url) do
          {:ok, keys} ->
            ConfigCache.put_cached(cache_key, keys, ttl: to_timeout(hour: 1))
            {:ok, keys}

          {:error, _} ->
            {:error, :jwks_unavailable}
        end
    end
  end

  defp find_matching_key(token, jwks) do
    with [header_b64 | _rest] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, header} <- Jason.decode(header_json) do
      kid = header["kid"]

      case Enum.find(jwks, fn k -> k["kid"] == kid end) do
        nil -> {:error, :key_not_found}
        key -> {:ok, key}
      end
    else
      _ -> {:error, :invalid_token_format}
    end
  end

  defp verify_token_signature(token, jwk_map) do
    # Convert JWK map to JOSE JWK struct
    jwk = JOSE.JWK.from_map(jwk_map)

    # Verify the token signature
    case JOSE.JWT.verify_strict(jwk, allowed_algorithms(), token) do
      {true, _jwt, _jws} ->
        :ok

      {false, _jwt, _jws} ->
        Logger.warning("Gateway JWT signature verification failed")
        {:error, :invalid_signature}
    end
  rescue
    e ->
      Logger.error("Gateway JWT verification error: #{Exception.message(e)}")
      {:error, :verification_error}
  end

  defp verify_with_public_key(token, pem) do
    # Parse PEM to JOSE JWK
    jwk = JOSE.JWK.from_pem(pem)

    case JOSE.JWT.verify_strict(jwk, allowed_algorithms(), token) do
      {true, _jwt, _jws} ->
        :ok

      {false, _jwt, _jws} ->
        Logger.warning("Gateway JWT signature verification failed with public key")
        {:error, :invalid_signature}
    end
  rescue
    e ->
      Logger.error("Gateway JWT verification error: #{Exception.message(e)}")
      {:error, :verification_error}
  end

  # Allowed JWT signing algorithms for gateway tokens
  defp allowed_algorithms do
    ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512"]
  end

  defp fetch_jwks(url) do
    with {:ok, _uri} <- OutboundURLPolicy.validate(url),
         {:ok, response} <- Req.get(url, OutboundURLPolicy.req_opts()) do
      case response do
        %{status: 200, body: %{"keys" => keys}} ->
          {:ok, keys}

        %{status: status} ->
          Logger.error("JWKS fetch failed: status=#{status}")
          {:error, :jwks_fetch_failed}
      end
    else
      {:error, :disallowed_scheme} ->
        {:error, :jwks_fetch_failed}

      {:error, :disallowed_host} ->
        {:error, :jwks_fetch_failed}

      {:error, :invalid_url} ->
        {:error, :jwks_fetch_failed}

      {:error, reason} ->
        Logger.error("JWKS fetch error: #{inspect(reason)}")
        {:error, :jwks_fetch_failed}
    end
  end

  defp verify_claims(claims, settings) do
    cond do
      # Check issuer
      settings.jwt_issuer && settings.jwt_issuer != "" &&
          claims["iss"] != settings.jwt_issuer ->
        {:error, :invalid_issuer}

      # Check audience
      settings.jwt_audience && settings.jwt_audience != "" &&
          not audience_matches?(claims["aud"], settings.jwt_audience) ->
        {:error, :invalid_audience}

      # Check expiration
      claims["exp"] && claims["exp"] < System.system_time(:second) ->
        {:error, :token_expired}

      true ->
        :ok
    end
  end

  defp audience_matches?(nil, _expected), do: false
  defp audience_matches?(aud, expected) when is_binary(aud), do: aud == expected
  defp audience_matches?(aud, expected) when is_list(aud), do: expected in aud

  defp handle_authenticated_request(conn, claims, settings) do
    # Extract user info from claims
    user_info = extract_user_info(claims, settings)

    case find_or_create_user(user_info) do
      {:ok, user} ->
        # Record authentication
        actor = SystemActor.system(:gateway_auth)
        User.record_authentication(user, actor: actor)

        # Trigger auth hooks
        Hooks.on_user_authenticated(user, claims)

        # Set up the connection with user context
        scope = Scope.for_user(user)

        actor_map = %{
          id: user.id,
          role: user.role,
          email: user.email
        }

        conn
        |> assign(:current_scope, scope)
        |> assign(:current_user, user)
        |> assign(:ash_actor, actor_map)
        |> Ash.PlugHelpers.set_actor(actor_map)

      {:error, reason} ->
        Logger.error("Failed to provision gateway user: #{inspect(reason)}")
        send_unauthorized(conn, "User provisioning failed")
    end
  end

  defp extract_user_info(claims, settings) do
    mappings = settings.claim_mappings || %{"email" => "email", "name" => "name", "sub" => "sub"}

    %{
      email: get_claim(claims, mappings["email"] || "email"),
      name: get_claim(claims, mappings["name"] || "name"),
      external_id: get_claim(claims, mappings["sub"] || "sub")
    }
  end

  defp get_claim(claims, path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(claims, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key)
        _ -> nil
      end
    end)
  end

  defp find_or_create_user(%{email: email, name: name, external_id: external_id}) do
    actor = SystemActor.system(:gateway_auth)

    # First, try to find by external_id
    case find_user_by_external_id(external_id, actor) do
      {:ok, user} ->
        {:ok, user}

      {:error, :not_found} ->
        # Try to find by email
        case User.get_by_email(email, actor: actor) do
          {:ok, user} ->
            # Link existing user to gateway
            link_user_to_gateway(user, external_id, actor)

          {:error, _} ->
            # Create new user (JIT provisioning)
            create_gateway_user(email, name, external_id, actor)
        end
    end
  end

  defp find_user_by_external_id(nil, _actor), do: {:error, :not_found}

  defp find_user_by_external_id(external_id, actor) do
    require Ash.Query

    query =
      User
      |> Ash.Query.filter(external_id == ^external_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, actor: actor) do
      {:ok, [user]} -> {:ok, user}
      {:ok, []} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp link_user_to_gateway(user, external_id, actor) do
    changeset =
      user
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:external_id, external_id)

    case Ash.update(changeset, actor: actor) do
      {:ok, updated} ->
        Logger.info("Linked existing user #{user.id} to gateway external_id #{external_id}")
        {:ok, updated}

      {:error, _} ->
        {:ok, user}
    end
  end

  defp create_gateway_user(email, name, external_id, actor) do
    params = %{
      email: email,
      display_name: name,
      external_id: external_id,
      provider: :gateway
    }

    case User.provision_sso_user(params, actor: actor) do
      {:ok, user} ->
        Logger.info("Created new user via gateway JIT provisioning: #{user.id}")
        Hooks.on_user_created(user, :gateway)
        {:ok, user}

      {:error, error} ->
        Logger.error("Failed to create gateway user: #{inspect(error)}")
        {:error, :user_creation_failed}
    end
  end

  defp send_unauthorized(conn, message) do
    case conn.private[:phoenix_format] do
      "html" ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: "/users/log-in")
        |> halt()

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized", message: message}))
        |> halt()
    end
  end
end
