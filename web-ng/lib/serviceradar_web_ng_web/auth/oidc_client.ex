defmodule ServiceRadarWebNGWeb.Auth.OIDCClient do
  @moduledoc """
  OIDC client for handling OpenID Connect authentication flows.

  This module implements the OIDC authorization code flow:
  1. Generate authorization URL with state and nonce
  2. Exchange authorization code for tokens
  3. Verify ID token signature and claims
  4. Extract user information from claims

  ## Discovery

  Provider metadata is fetched from the discovery URL and cached
  by the ConfigCache for performance.
  """

  require Logger

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy

  @discovery_suffix "/.well-known/openid-configuration"

  @doc """
  Generates the authorization URL for initiating OIDC login.

  Returns `{:ok, url, state}` where state should be stored in session
  for CSRF protection.
  """
  def authorize_url(opts \\ []) do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url) do
      state = generate_state()
      nonce = generate_nonce()

      params = %{
        client_id: config.client_id,
        redirect_uri: opts[:redirect_uri] || config.redirect_uri,
        response_type: "code",
        scope: Enum.join(config.scopes, " "),
        state: state,
        nonce: nonce
      }

      url = "#{metadata["authorization_endpoint"]}?#{URI.encode_query(params)}"

      {:ok, url, %{state: state, nonce: nonce}}
    end
  end

  @doc """
  Exchanges an authorization code for tokens.

  Returns `{:ok, tokens}` where tokens contains:
  - access_token
  - id_token
  - refresh_token (if provided)
  - expires_in
  """
  def exchange_code(code, opts \\ []) do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url) do
      body = %{
        grant_type: "authorization_code",
        code: code,
        client_id: config.client_id,
        client_secret: config.client_secret,
        redirect_uri: opts[:redirect_uri] || config.redirect_uri
      }

      case Req.post(metadata["token_endpoint"], form: body) do
        {:ok, %{status: 200, body: tokens}} ->
          {:ok, tokens}

        {:ok, %{status: status, body: body}} ->
          Logger.error("OIDC token exchange failed: status=#{status}, body=#{inspect(body)}")
          {:error, :token_exchange_failed}

        {:error, reason} ->
          Logger.error("OIDC token exchange error: #{inspect(reason)}")
          {:error, :token_exchange_failed}
      end
    end
  end

  @doc """
  Verifies an ID token and extracts claims.

  Validates:
  - Token signature (using JWKS)
  - Issuer claim
  - Audience claim
  - Expiration
  - Nonce (if provided)

  Returns `{:ok, claims}` on success.
  """
  def verify_id_token(id_token, opts \\ []) do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url),
         {:ok, jwks} <- fetch_jwks(metadata["jwks_uri"]),
         {:ok, claims} <- decode_and_verify_jwt(id_token, jwks) do
      # Validate claims
      expected_nonce = opts[:nonce]

      cond do
        claims["iss"] != metadata["issuer"] ->
          {:error, :invalid_issuer}

        claims["aud"] != config.client_id and config.client_id not in List.wrap(claims["aud"]) ->
          {:error, :invalid_audience}

        claims["exp"] && claims["exp"] < System.system_time(:second) ->
          {:error, :token_expired}

        expected_nonce && claims["nonce"] != expected_nonce ->
          {:error, :invalid_nonce}

        true ->
          {:ok, claims}
      end
    end
  end

  @doc """
  Extracts user attributes from ID token claims using configured mappings.

  Returns a map with :email, :name, and :external_id keys.
  """
  def extract_user_info(claims) do
    mappings = OIDCStrategy.claim_mappings()

    %{
      email: get_claim(claims, mappings["email"] || "email"),
      name: get_claim(claims, mappings["name"] || "name"),
      external_id: get_claim(claims, mappings["sub"] || "sub")
    }
  end

  @doc """
  Fetches the OIDC discovery metadata from the provider.

  Results are cached by ConfigCache for performance.
  """
  def fetch_discovery_metadata(discovery_url) do
    # Check cache first
    cache_key = "oidc_metadata:#{discovery_url}"

    case ConfigCache.get_cached(cache_key) do
      {:ok, metadata} ->
        {:ok, metadata}

      :miss ->
        # Ensure URL ends with discovery suffix
        url =
          if String.ends_with?(discovery_url, @discovery_suffix) do
            discovery_url
          else
            String.trim_trailing(discovery_url, "/") <> @discovery_suffix
          end

        case Req.get(url) do
          {:ok, %{status: 200, body: metadata}} ->
            ConfigCache.put_cached(cache_key, metadata, ttl: :timer.minutes(60))
            {:ok, metadata}

          {:ok, %{status: status}} ->
            Logger.error("OIDC discovery failed: status=#{status}")
            {:error, :discovery_failed}

          {:error, reason} ->
            Logger.error("OIDC discovery error: #{inspect(reason)}")
            {:error, :discovery_failed}
        end
    end
  end

  @doc """
  Validates the OIDC configuration by attempting discovery.

  Returns :ok if the discovery URL is accessible and returns valid metadata.
  """
  def validate_config do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url) do
      required_fields = ["authorization_endpoint", "token_endpoint", "jwks_uri", "issuer"]
      missing = Enum.filter(required_fields, &(not Map.has_key?(metadata, &1)))

      if Enum.empty?(missing) do
        :ok
      else
        {:error, {:missing_metadata_fields, missing}}
      end
    end
  end

  # Private functions

  defp get_config do
    case OIDCStrategy.get_config() do
      nil -> {:error, :oidc_not_configured}
      config -> {:ok, config}
    end
  end

  defp fetch_jwks(jwks_uri) do
    cache_key = "oidc_jwks:#{jwks_uri}"

    case ConfigCache.get_cached(cache_key) do
      {:ok, jwks} ->
        {:ok, jwks}

      :miss ->
        case Req.get(jwks_uri) do
          {:ok, %{status: 200, body: %{"keys" => keys}}} ->
            ConfigCache.put_cached(cache_key, keys, ttl: :timer.minutes(60))
            {:ok, keys}

          {:ok, %{status: status}} ->
            Logger.error("JWKS fetch failed: status=#{status}")
            {:error, :jwks_fetch_failed}

          {:error, reason} ->
            Logger.error("JWKS fetch error: #{inspect(reason)}")
            {:error, :jwks_fetch_failed}
        end
    end
  end

  defp decode_and_verify_jwt(token, jwks) do
    # Parse JWT header to get key ID
    case String.split(token, ".") do
      [header_b64, _payload_b64, _signature] ->
        with {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(header_json) do
          # Find matching key by kid
          kid = header["kid"]
          key_map = Enum.find(jwks, fn k -> k["kid"] == kid end)

          cond do
            is_nil(key_map) ->
              {:error, :key_not_found}

            true ->
              # Convert JWK to JOSE key and verify
              verify_jwt_with_key(token, key_map)
          end
        else
          _ -> {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp verify_jwt_with_key(token, jwk_map) do
    try do
      # Convert the JWK map to a JOSE.JWK struct
      jwk = JOSE.JWK.from_map(jwk_map)

      # Verify the token signature and decode
      case JOSE.JWT.verify_strict(jwk, [jwk_map["alg"] || "RS256"], token) do
        {true, %JOSE.JWT{fields: claims}, _jws} ->
          {:ok, claims}

        {false, _, _} ->
          Logger.warning("JWT signature verification failed")
          {:error, :invalid_signature}
      end
    rescue
      e ->
        Logger.error("JWT verification error: #{inspect(e)}")
        {:error, :verification_failed}
    end
  end

  defp get_claim(claims, path) when is_binary(path) do
    # Support nested paths like "user.email"
    path
    |> String.split(".")
    |> Enum.reduce(claims, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key)
        _ -> nil
      end
    end)
  end

  defp generate_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
