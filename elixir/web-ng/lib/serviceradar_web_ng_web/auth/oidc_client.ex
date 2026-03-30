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

  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy
  alias ServiceRadarWebNGWeb.Auth.OutboundFetch
  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy

  require Logger

  @discovery_suffix "/.well-known/openid-configuration"

  @doc """
  Generates the authorization URL for initiating OIDC login.

  Returns `{:ok, url, state}` where state should be stored in session
  for CSRF protection.
  """
  def authorize_url(opts \\ []) do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url),
         {:ok, authorization_endpoint} <-
           validate_redirect_endpoint(metadata["authorization_endpoint"]) do
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

      url = "#{authorization_endpoint}?#{URI.encode_query(params)}"

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

      exchange_tokens(metadata["token_endpoint"], body)
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
    with {:ok, expected_nonce} <- fetch_expected_nonce(opts),
         {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url),
         {:ok, jwks} <- fetch_jwks(metadata["jwks_uri"]),
         {:ok, claims} <- decode_and_verify_jwt(id_token, jwks) do
      cond do
        claims["iss"] != metadata["issuer"] ->
          {:error, :invalid_issuer}

        claims["aud"] != config.client_id and config.client_id not in List.wrap(claims["aud"]) ->
          {:error, :invalid_audience}

        claims["exp"] && claims["exp"] < System.system_time(:second) ->
          {:error, :token_expired}

        claims["nonce"] != expected_nonce ->
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
    email = get_claim(claims, mappings["email"] || "email")
    name = get_claim(claims, mappings["name"] || "name")
    external_id = get_claim(claims, mappings["sub"] || "sub")

    cond do
      not is_binary(external_id) or String.trim(external_id) == "" ->
        {:error, :missing_external_id}

      not is_binary(email) or String.trim(email) == "" ->
        {:error, :missing_email}

      true ->
        {:ok,
         %{
           email: String.trim(email),
           name: normalize_optional_claim(name),
           external_id: String.trim(external_id)
         }}
    end
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
        discovery_url
        |> ensure_discovery_suffix()
        |> fetch_discovery_metadata_uncached(cache_key)
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
        fetch_jwks_uncached(jwks_uri, cache_key)
    end
  end

  defp ensure_discovery_suffix(discovery_url) do
    if String.ends_with?(discovery_url, @discovery_suffix) do
      discovery_url
    else
      String.trim_trailing(discovery_url, "/") <> @discovery_suffix
    end
  end

  defp fetch_discovery_metadata_uncached(url, cache_key) do
    case OutboundFetch.get(url) do
      {:ok, response} ->
        handle_discovery_response(response, cache_key)

      {:error, reason} ->
        handle_oidc_fetch_error("OIDC discovery", reason, :discovery_failed)
    end
  end

  defp handle_discovery_response(%{status: 200, body: metadata}, cache_key) do
    ConfigCache.put_cached(cache_key, metadata, ttl: to_timeout(hour: 1))
    {:ok, metadata}
  end

  defp handle_discovery_response(%{status: status}, _cache_key) do
    Logger.error("OIDC discovery failed: status=#{status}")
    {:error, :discovery_failed}
  end

  defp fetch_jwks_uncached(jwks_uri, cache_key) do
    case OutboundFetch.get(jwks_uri) do
      {:ok, response} ->
        handle_jwks_response(response, cache_key)

      {:error, reason} ->
        handle_oidc_fetch_error("JWKS fetch", reason, :jwks_fetch_failed)
    end
  end

  defp handle_jwks_response(%{status: 200, body: %{"keys" => keys}}, cache_key) do
    ConfigCache.put_cached(cache_key, keys, ttl: to_timeout(hour: 1))
    {:ok, keys}
  end

  defp handle_jwks_response(%{status: status}, _cache_key) do
    Logger.error("JWKS fetch failed: status=#{status}")
    {:error, :jwks_fetch_failed}
  end

  defp handle_oidc_fetch_error(_label, reason, failure)
       when reason in [:disallowed_scheme, :disallowed_host, :invalid_url, :dns_resolution_failed] do
    {:error, failure}
  end

  defp handle_oidc_fetch_error(label, reason, failure) do
    Logger.error("#{label} error: #{inspect(reason)}")
    {:error, failure}
  end

  defp exchange_tokens(token_endpoint, body) do
    case OutboundFetch.post(token_endpoint, form: body) do
      {:ok, response} ->
        case response do
          %{status: 200, body: tokens} ->
            {:ok, tokens}

          %{status: status, body: response_body} ->
            Logger.error("OIDC token exchange failed: status=#{status}, body=#{inspect(response_body)}")

            {:error, :token_exchange_failed}
        end

      {:error, :disallowed_scheme} ->
        {:error, :token_exchange_failed}

      {:error, :disallowed_host} ->
        {:error, :token_exchange_failed}

      {:error, :invalid_url} ->
        {:error, :token_exchange_failed}

      {:error, :dns_resolution_failed} ->
        {:error, :token_exchange_failed}

      {:error, reason} ->
        Logger.error("OIDC token exchange error: #{inspect(reason)}")
        {:error, :token_exchange_failed}
    end
  end

  defp validate_redirect_endpoint(url) when is_binary(url) do
    case OutboundURLPolicy.validate(url) do
      {:ok, _uri} -> {:ok, url}
      {:error, _reason} -> {:error, :discovery_failed}
    end
  end

  defp validate_redirect_endpoint(_url), do: {:error, :discovery_failed}

  defp decode_and_verify_jwt(token, jwks) do
    # Parse JWT header to get key ID
    case String.split(token, ".") do
      [header_b64, _payload_b64, _signature] ->
        with {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(header_json) do
          # Find matching key by kid
          kid = header["kid"]
          key_map = Enum.find(jwks, fn k -> k["kid"] == kid end)

          if is_nil(key_map) do
            {:error, :key_not_found}
          else
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

  defp fetch_expected_nonce(opts) do
    case Keyword.get(opts, :nonce) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_nonce}
    end
  end

  defp normalize_optional_claim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_claim(_value), do: nil

  defp generate_state do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp generate_nonce do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
