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

  @behaviour ServiceRadarWebNG.Mcp.OAuth.IdPRefreshClient

  alias ServiceRadarWebNG.Pkce
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.OIDCStrategy
  alias ServiceRadarWebNGWeb.Auth.OutboundFetch
  alias ServiceRadarWebNGWeb.Auth.OutboundURLPolicy

  require Logger

  @discovery_suffix "/.well-known/openid-configuration"

  # Allowed clock skew (seconds) when validating the time-based JWT claims
  # exp/nbf/iat. Accounts for small clock drift between the IdP and this host.
  @clock_skew_seconds 60

  # Minimum interval (milliseconds) between *forced* JWKS refetches for a given
  # jwks_uri. A burst of tokens carrying an unknown `kid` would otherwise
  # stampede the IdP; this throttle bounds forced refetches to one per window.
  @jwks_refetch_min_interval_ms 60_000

  @doc """
  Generates the authorization URL for initiating OIDC login.

  Returns `{:ok, url, session}` where session includes `state`, `nonce`,
  `code_verifier`, and `pkce?` and must be stored for callback validation.
  """
  def authorize_url(opts \\ []) do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url),
         {:ok, authorization_endpoint} <-
           validate_redirect_endpoint(metadata["authorization_endpoint"]),
         {:ok, pkce_decision} <- pkce_decision(config, metadata) do
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

      {params, session} = maybe_put_pkce(params, pkce_decision, state, nonce)
      url = "#{authorization_endpoint}?#{URI.encode_query(params)}"

      {:ok, url, session}
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
      body =
        maybe_put_code_verifier(
          %{
            grant_type: "authorization_code",
            code: code,
            client_id: config.client_id,
            client_secret: config.client_secret,
            redirect_uri: opts[:redirect_uri] || config.redirect_uri
          },
          opts[:code_verifier]
        )

      exchange_tokens(metadata["token_endpoint"], body)
    end
  end

  @doc """
  Refreshes IdP tokens using the identity provider's refresh token.

  Used to confirm the IdP session is still alive before minting a new
  MCP access token.
  """
  def refresh_tokens(refresh_token) when is_binary(refresh_token) and refresh_token != "" do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url) do
      body = %{
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: config.client_id,
        client_secret: config.client_secret
      }

      exchange_tokens(metadata["token_endpoint"], body)
    end
  end

  def refresh_tokens(_), do: {:error, :invalid_refresh_token}

  @logout_event "http://schemas.openid.net/event/backchannel-logout"

  @doc """
  Verifies an OIDC back-channel logout token and returns its claims.
  """
  def verify_logout_token(logout_token) when is_binary(logout_token) and logout_token != "" do
    with {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url),
         {:ok, jwks} <- fetch_jwks(metadata["jwks_uri"]),
         {:ok, claims} <- decode_and_verify_jwt(logout_token, jwks, metadata["jwks_uri"]) do
      cond do
        claims["iss"] != metadata["issuer"] ->
          {:error, :invalid_issuer}

        not audience_includes?(claims["aud"], config.client_id) ->
          {:error, :invalid_audience}

        Map.has_key?(claims, "nonce") ->
          {:error, :nonce_present}

        not logout_event?(claims["events"]) ->
          {:error, :invalid_events}

        is_nil(claims["sid"]) and is_nil(claims["sub"]) ->
          {:error, :missing_sid}

        true ->
          {:ok, claims}
      end
    end
  end

  def verify_logout_token(_), do: {:error, :invalid_logout_token}

  defp audience_includes?(aud, client_id) when is_binary(client_id) do
    aud == client_id or client_id in List.wrap(aud)
  end

  defp audience_includes?(_, _), do: false

  defp logout_event?(events) when is_map(events), do: Map.has_key?(events, @logout_event)
  defp logout_event?(_), do: false

  @doc """
  Verifies an ID token and extracts claims.

  Validates:
  - Token signature (using JWKS; refetched once on `kid` miss for key rotation)
  - Issuer claim
  - Audience claim
  - Expiration (`exp`), not-before (`nbf`), and issued-at (`iat`) within a small
    clock-skew leeway. `nbf`/`iat` are only enforced when present.
  - Nonce (if provided)

  Returns `{:ok, claims}` on success.
  """
  def verify_id_token(id_token, opts \\ []) do
    with {:ok, expected_nonce} <- fetch_expected_nonce(opts),
         {:ok, config} <- get_config(),
         {:ok, metadata} <- fetch_discovery_metadata(config.discovery_url),
         {:ok, jwks} <- fetch_jwks(metadata["jwks_uri"]),
         {:ok, claims} <- decode_and_verify_jwt(id_token, jwks, metadata["jwks_uri"]) do
      now = System.system_time(:second)

      cond do
        claims["iss"] != metadata["issuer"] ->
          {:error, :invalid_issuer}

        claims["aud"] != config.client_id and config.client_id not in List.wrap(claims["aud"]) ->
          {:error, :invalid_audience}

        token_expired?(claims["exp"], now) ->
          {:error, :token_expired}

        token_not_yet_valid?(claims["nbf"], now) ->
          {:error, :token_not_yet_valid}

        invalid_iat?(claims["iat"], now) ->
          {:error, :invalid_iat}

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

  # A pooled keep-alive connection the identity provider (or an intermediary) has
  # already closed surfaces as %Req.TransportError{reason: :closed} when the next
  # request tries to use it. The request never reaches the server, so retrying on
  # a fresh connection turns what the user sees as a failed login into a
  # transparent recovery. Observed on demo as repeated
  # `token_exchange_failed` immediately after a successful authentication at the
  # IdP -- the credential was fine, only the back-channel exchange died.
  #
  # Only *transport* errors are retried, never an HTTP response. The
  # authorization code is single-use, so if the provider did process the first
  # attempt the retry comes back `invalid_grant` and the user sees exactly the
  # failure they would have seen without the retry -- this is never worse than
  # not retrying, and usually better.
  @token_exchange_max_attempts 2
  @token_exchange_retry_delay_ms 150

  defp exchange_tokens(token_endpoint, body), do: exchange_tokens(token_endpoint, body, 1)

  defp exchange_tokens(token_endpoint, body, attempt) do
    case token_post(token_endpoint, form: body) do
      {:ok, %{status: 200, body: tokens}} ->
        {:ok, tokens}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("OIDC token exchange failed: status=#{status}, body=#{inspect(response_body)}")

        {:error, :token_exchange_failed}

      {:error, reason}
      when reason in [
             :disallowed_scheme,
             :disallowed_host,
             :invalid_url,
             :dns_resolution_failed
           ] ->
        {:error, :token_exchange_failed}

      {:error, reason} ->
        if attempt < @token_exchange_max_attempts and stale_connection?(reason) do
          Logger.warning(
            "OIDC token exchange transport error on attempt #{attempt}, retrying on a fresh connection: #{inspect(reason)}"
          )

          Process.sleep(@token_exchange_retry_delay_ms)
          exchange_tokens(token_endpoint, body, attempt + 1)
        else
          Logger.error("OIDC token exchange error: #{inspect(reason)}")
          {:error, :token_exchange_failed}
        end
    end
  end

  # Deliberately narrow. `:closed` is the signal that the socket was gone before
  # the request was written; a timeout could mean the provider processed it, and
  # retrying that would only trade one failure message for another while
  # doubling how long the user waits.
  @doc false
  @spec stale_connection?(term()) :: boolean()
  def stale_connection?(%Req.TransportError{reason: :closed}), do: true
  def stale_connection?(_reason), do: false

  defp validate_redirect_endpoint(url) when is_binary(url) do
    case OutboundURLPolicy.validate(url) do
      {:ok, _uri} -> {:ok, url}
      {:error, _reason} -> {:error, :discovery_failed}
    end
  end

  defp validate_redirect_endpoint(_url), do: {:error, :discovery_failed}

  defp decode_and_verify_jwt(token, jwks, jwks_uri) do
    # Parse JWT header to get key ID
    case String.split(token, ".") do
      [header_b64, _payload_b64, _signature] ->
        with {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(header_json) do
          verify_with_kid(token, header["kid"], jwks, jwks_uri)
        else
          _ -> {:error, :invalid_token_format}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  # Resolve the signing key by `kid` and verify. JWKS is cached (~1h), so when an
  # IdP rotates signing keys the cached set will be missing the new `kid`. On a
  # miss, bust the cache and refetch the JWKS once, then retry the lookup before
  # giving up with `:key_not_found`.
  defp verify_with_kid(token, kid, jwks, jwks_uri) do
    case find_signing_key(jwks, kid) do
      nil ->
        verify_with_refetched_kid(token, kid, jwks_uri)

      key_map ->
        verify_jwt_with_key(token, key_map)
    end
  end

  defp verify_with_refetched_kid(token, kid, jwks_uri) do
    case refetch_jwks(jwks_uri) do
      {:ok, fresh_jwks} ->
        case find_signing_key(fresh_jwks, kid) do
          nil -> {:error, :key_not_found}
          key_map -> verify_jwt_with_key(token, key_map)
        end

      {:error, _reason} ->
        {:error, :key_not_found}
    end
  end

  defp find_signing_key(jwks, kid) do
    Enum.find(List.wrap(jwks), fn k -> k["kid"] == kid end)
  end

  # Force a one-shot JWKS refetch for `jwks_uri`, busting the cached set so the
  # next read goes to the network. A short min-interval guard (cached under its
  # own key) ensures at most one forced refetch per window even under a flood of
  # tokens carrying unknown `kid`s, preventing a refetch storm against the IdP.
  defp refetch_jwks(jwks_uri) do
    guard_key = "oidc_jwks_refetch:#{jwks_uri}"

    case ConfigCache.get_cached(guard_key) do
      {:ok, _recent} ->
        {:error, :jwks_refetch_throttled}

      :miss ->
        ConfigCache.put_cached(guard_key, true, ttl: @jwks_refetch_min_interval_ms)
        ConfigCache.delete_cached("oidc_jwks:#{jwks_uri}")
        fetch_jwks(jwks_uri)
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

  # `exp` is the only mandatory time claim per OIDC, but to stay backward
  # compatible we only assert it when present/numeric. The token is expired once
  # `now` passes `exp` plus the allowed clock skew.
  defp token_expired?(exp, now) when is_number(exp), do: exp + @clock_skew_seconds < now
  defp token_expired?(_exp, _now), do: false

  # `nbf` (not-before) is optional; when present the token is not yet valid until
  # `now` reaches `nbf` minus the allowed clock skew.
  defp token_not_yet_valid?(nbf, now) when is_number(nbf), do: now < nbf - @clock_skew_seconds
  defp token_not_yet_valid?(_nbf, _now), do: false

  # `iat` (issued-at) sanity: an optional claim that must not be in the future
  # beyond the allowed clock skew (guards against tokens minted with a skewed or
  # malicious future timestamp).
  defp invalid_iat?(iat, now) when is_number(iat), do: iat > now + @clock_skew_seconds
  defp invalid_iat?(_iat, _now), do: false

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

  defp pkce_decision(config, metadata) do
    methods = metadata["code_challenge_methods_supported"]

    case Map.get(config, :pkce_mode, :auto) do
      :disabled ->
        {:ok, :omit}

      :required ->
        if methods_present_without_s256?(methods) do
          {:error, :pkce_s256_unsupported}
        else
          {:ok, :s256}
        end

      _auto ->
        if methods_present_without_s256?(methods) do
          Logger.warning("OIDC provider does not advertise PKCE S256; omitting PKCE and not using plain")

          {:ok, :omit}
        else
          {:ok, :s256}
        end
    end
  end

  defp methods_present_without_s256?(methods) when is_list(methods), do: "S256" not in methods
  defp methods_present_without_s256?(_methods), do: false

  defp maybe_put_pkce(params, :s256, state, nonce) do
    verifier = Pkce.generate_verifier()

    params =
      Map.merge(params, %{
        code_challenge: Pkce.challenge_s256(verifier),
        code_challenge_method: "S256"
      })

    {params, %{state: state, nonce: nonce, code_verifier: verifier, pkce?: true}}
  end

  defp maybe_put_pkce(params, :omit, state, nonce) do
    {params, %{state: state, nonce: nonce, code_verifier: nil, pkce?: false}}
  end

  defp maybe_put_code_verifier(body, verifier) when is_binary(verifier) and verifier != "" do
    Map.put(body, :code_verifier, verifier)
  end

  defp maybe_put_code_verifier(body, _verifier), do: body

  defp token_post(url, opts) do
    case Application.get_env(:serviceradar_web_ng, :oidc_token_poster) do
      fun when is_function(fun, 2) -> fun.(url, opts)
      _ -> OutboundFetch.post(url, opts)
    end
  end
end
