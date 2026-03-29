defmodule ServiceRadarWebNG.Auth.Guardian do
  @moduledoc """
  Guardian implementation for JWT token management.

  This module handles all JWT operations for ServiceRadar authentication:
  - Access tokens (short-lived, configurable; default 1 hour)
  - Refresh tokens (long-lived, configurable; default 30 days)
  - API tokens (client credentials, configurable expiration)

  ## Token Types

  Tokens include a "typ" claim to distinguish their purpose:
  - "access" - Browser session tokens
  - "refresh" - Token refresh grants
  - "api" - Client credentials tokens

  ## Token Revocation

  Tokens can be revoked via `ServiceRadarWebNG.Auth.TokenRevocation`.
  Revoked tokens are rejected during verification even if not expired.

  ## Integration with Permit

  The `build_claims/3` callback provides an extension point for adding
  Permit authorization context to tokens in the future.
  """

  use Guardian, otp_app: :serviceradar_web_ng

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Auth.Hooks
  alias ServiceRadarWebNG.Auth.TokenRevocation

  @default_idle_timeout_seconds 60 * 60
  @default_absolute_timeout_seconds 30 * 24 * 60 * 60
  @default_api_token_ttl {1, :hour}

  @doc """
  Returns the subject identifier for a user.

  The subject is formatted as "user:<uuid>" to support future
  extension to other resource types.
  """
  @impl Guardian
  def subject_for_token(%User{id: id}, _claims) do
    {:ok, "user:#{id}"}
  end

  def subject_for_token(_, _) do
    {:error, :invalid_resource}
  end

  @doc """
  Loads a user from the subject claim.

  Extracts the user ID from the "user:<uuid>" format and loads
  the user from the database.
  """
  @impl Guardian
  def resource_from_claims(%{"sub" => "user:" <> id}) do
    actor = SystemActor.system(:guardian)

    case Ash.get(User, id, actor: actor) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, :user_not_found}
    end
  end

  def resource_from_claims(_claims) do
    {:error, :invalid_claims}
  end

  @doc """
  Builds claims for a token.

  Adds custom claims based on token type:
  - typ: Token type (access, refresh, api)
  - scopes: Permission scopes for API tokens
  - role: User's role for quick authorization checks

  This is the extension point for future Permit integration.
  """
  @impl Guardian
  def build_claims(claims, %User{} = user, opts) do
    token_type = Keyword.get(opts, :token_type, "access")
    scopes = Keyword.get(opts, :scopes, [])

    claims =
      claims
      |> Map.put("typ", token_type)
      |> Map.put("role", to_string(user.role))

    claims =
      if scopes == [] do
        claims
      else
        Map.put(claims, "scopes", Enum.map(scopes, &to_string/1))
      end

    # Extension point for Permit integration
    claims = Hooks.enrich_claims(claims, user)

    {:ok, claims}
  end

  def build_claims(claims, _resource, _opts), do: {:ok, claims}

  @doc """
  Verifies claims after token decode.

  Performs additional validation:
  - Checks token type matches expected type (if specified)
  - Validates scopes for API tokens
  - Checks if token has been revoked
  - Checks if all user tokens have been revoked
  """
  @impl Guardian
  def verify_claims(claims, opts) do
    expected_type = Keyword.get(opts, :token_type)

    with :ok <- verify_token_type(claims, expected_type),
         :ok <- verify_not_revoked(claims) do
      {:ok, claims}
    end
  end

  defp verify_token_type(_claims, nil), do: :ok

  defp verify_token_type(claims, expected_type) do
    if Map.get(claims, "typ") == expected_type do
      :ok
    else
      {:error, :invalid_token_type}
    end
  end

  defp verify_not_revoked(claims) do
    jti = Map.get(claims, "jti")
    sub = Map.get(claims, "sub")
    iat = Map.get(claims, "iat")

    # Check if this specific token is revoked, then check user-wide revocation
    with :ok <- TokenRevocation.check_revoked(jti) do
      check_user_revocation(sub, iat)
    end
  end

  defp check_user_revocation("user:" <> user_id, iat) when not is_nil(iat) do
    TokenRevocation.check_user_revoked(user_id, iat)
  end

  defp check_user_revocation(_, _), do: :ok

  @doc """
  Called after a token is generated.

  This hook can be used for audit logging or Permit sync.
  """
  @impl Guardian
  def after_encode_and_sign(resource, claims, token, _opts) do
    # Extension point for Permit integration
    Hooks.on_token_generated(resource, token, claims)
    {:ok, {resource, claims, token}}
  end

  # Token Generation Helpers

  @doc """
  Creates an access token for a user.

  Returns `{:ok, token, claims}` on success.
  """
  def create_access_token(user, opts \\ []) do
    opts = Keyword.merge([token_type: "access", ttl: access_token_ttl()], opts)
    encode_and_sign(user, %{}, opts)
  end

  @doc """
  Creates a refresh token for a user.

  Returns `{:ok, token, claims}` on success.
  """
  def create_refresh_token(user, opts \\ []) do
    opts = Keyword.merge([token_type: "refresh", ttl: refresh_token_ttl()], opts)
    encode_and_sign(user, %{}, opts)
  end

  @doc """
  Creates an API token for client credentials.

  Options:
  - `:scopes` - List of scopes (e.g., [:read, :write])
  - `:ttl` - Token lifetime (default: 1 hour)

  Returns `{:ok, token, claims}` on success.
  """
  def create_api_token(user, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, [:read])
    ttl = Keyword.get(opts, :ttl, @default_api_token_ttl)

    opts = [token_type: "api", scopes: scopes, ttl: ttl]
    encode_and_sign(user, %{}, opts)
  end

  @doc """
  Exchanges a refresh token for a new access token.

  Returns `{:ok, user, credentials}` on success, where `credentials` contains
  newly issued access and refresh tokens and claims.
  """
  def exchange_refresh_token(refresh_token) do
    with {:ok, claims} <- decode_and_verify(refresh_token, %{}, token_type: "refresh"),
         {:ok, user} <- resource_from_claims(claims),
         :ok <- revoke_refresh_token(claims, user),
         {:ok, new_access_token, new_access_claims} <- create_access_token(user),
         {:ok, new_refresh_token, new_refresh_claims} <- create_refresh_token(user) do
      {:ok, user,
       %{
         access_token: new_access_token,
         access_claims: new_access_claims,
         refresh_token: new_refresh_token,
         refresh_claims: new_refresh_claims
       }}
    end
  end

  @doc """
  Verifies a token and returns the user.

  Options:
  - `:token_type` - Expected token type ("access", "refresh", "api")

  Returns `{:ok, user, claims}` on success.
  """
  def verify_token(token, opts \\ []) do
    with {:ok, claims} <- decode_and_verify(token, %{}, opts),
         {:ok, user} <- resource_from_claims(claims) do
      {:ok, user, claims}
    end
  end

  @doc """
  Extracts scopes from token claims.

  Returns a list of atoms representing the token's scopes.
  """
  def get_scopes(claims) do
    claims
    |> Map.get("scopes", [])
    |> Enum.map(&String.to_existing_atom/1)
  rescue
    ArgumentError -> []
  end

  @doc """
  Checks if claims include a specific scope.
  """
  def has_scope?(claims, scope) when is_atom(scope) do
    scope in get_scopes(claims)
  end

  def has_scope?(claims, scope) when is_binary(scope) do
    scope in Map.get(claims, "scopes", [])
  end

  defp access_token_ttl do
    {session_idle_timeout_seconds(), :second}
  end

  defp revoke_refresh_token(claims, user) do
    jti = Map.get(claims, "jti")

    if is_binary(jti) and jti != "" do
      ttl = refresh_token_revocation_ttl(claims)

      TokenRevocation.revoke_token(jti,
        reason: :refresh_rotated,
        user_id: user.id,
        ttl: ttl
      )
    else
      {:error, :missing_jti}
    end
  end

  defp refresh_token_revocation_ttl(claims) do
    now = System.system_time(:second)

    case Map.get(claims, "exp") do
      exp when is_integer(exp) and exp > now -> (exp - now) * 1000
      _ -> 1_000
    end
  end

  defp refresh_token_ttl do
    {session_absolute_timeout_seconds(), :second}
  end

  defp session_idle_timeout_seconds do
    Keyword.get(session_config(), :idle_timeout_seconds, @default_idle_timeout_seconds)
  end

  defp session_absolute_timeout_seconds do
    Keyword.get(session_config(), :absolute_timeout_seconds, @default_absolute_timeout_seconds)
  end

  defp session_config do
    Application.get_env(:serviceradar_web_ng, :session, [])
  end
end
