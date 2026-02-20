defmodule ServiceRadarWebNGWeb.Auth.Hooks do
  @moduledoc """
  Authentication lifecycle hooks for extensibility.

  This module defines callbacks that are invoked at key points in the
  authentication lifecycle. The default implementation is a no-op, but
  future integrations (like Permit) can implement these callbacks to:

  - Sync users to external authorization systems
  - Enrich tokens with authorization context
  - Log authentication events for audit trails

  ## Callbacks

  - `on_user_created/2` - Called after JIT user provisioning
  - `on_user_authenticated/2` - Called after successful authentication
  - `on_token_generated/3` - Called after token generation
  - `enrich_claims/2` - Called to add custom claims to tokens

  ## Configuration

  To use a custom hooks implementation:

      config :serviceradar_web_ng, :auth_hooks_module, MyApp.Auth.CustomHooks

  The custom module must implement the `ServiceRadarWebNGWeb.Auth.Hooks` behaviour.
  """

  alias ServiceRadar.Identity.User
  require Logger

  @doc """
  Called when a new user is created via JIT provisioning.

  The `source` atom indicates how the user was created:
  - `:oidc` - OpenID Connect authentication
  - `:saml` - SAML 2.0 authentication
  - `:gateway` - Gateway/proxy JWT authentication
  - `:password` - Password registration (if enabled)

  ## Example

      def on_user_created(user, :oidc) do
        # Sync user to Permit
        Permit.sync_user(user)
        :ok
      end
  """
  @callback on_user_created(user :: User.t(), source :: atom()) :: :ok | {:error, term()}

  @doc """
  Called after a user successfully authenticates.

  The `claims` map contains the token claims from the authentication source.
  For OIDC, this includes the ID token claims. For SAML, the assertion attributes.
  For password auth, this is the Guardian claims.

  ## Example

      def on_user_authenticated(user, claims) do
        # Log to audit system
        AuditLog.log(:authentication, user, claims)
        :ok
      end
  """
  @callback on_user_authenticated(user :: User.t(), claims :: map()) :: :ok | {:error, term()}

  @doc """
  Called after a token is generated for a user.

  This hook is useful for audit logging or external token registration.

  ## Example

      def on_token_generated(user, token, claims) do
        # Register token with external system
        TokenRegistry.register(user.id, claims["jti"])
        :ok
      end
  """
  @callback on_token_generated(user :: User.t(), token :: String.t(), claims :: map()) ::
              :ok | {:error, term()}

  @doc """
  Called to enrich token claims with additional context.

  This hook allows adding custom claims to tokens, such as:
  - Permission context from Permit
  - Feature flags
  - Custom metadata

  The returned claims map will be merged into the token.

  ## Example

      def enrich_claims(claims, user) do
        permissions = Permit.get_permissions(user)
        Map.put(claims, "permissions", permissions)
      end
  """
  @callback enrich_claims(claims :: map(), user :: User.t()) :: map()

  @doc """
  Called when an authentication attempt fails.

  Useful for audit logging and security monitoring.

  The `reason` atom indicates why authentication failed:
  - `:invalid_credentials` - Wrong password
  - `:user_not_found` - No user with given email
  - `:invalid_token` - Invalid or expired token
  - `:signature_validation_failed` - Invalid SAML/JWT signature
  - `:rate_limited` - Too many attempts

  The `context` map contains relevant details about the attempt.

  ## Example

      def on_auth_failed(reason, context) do
        AuditLog.log(:auth_failure, reason, context)
        :ok
      end
  """
  @callback on_auth_failed(reason :: atom(), context :: map()) :: :ok | {:error, term()}

  # Public API - delegates to configured implementation

  @doc """
  Invokes the `on_user_created` callback.
  """
  def on_user_created(user, source) do
    impl().on_user_created(user, source)
  rescue
    e ->
      Logger.error("Auth hook on_user_created failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Invokes the `on_user_authenticated` callback.
  """
  def on_user_authenticated(user, claims) do
    impl().on_user_authenticated(user, claims)
  rescue
    e ->
      Logger.error("Auth hook on_user_authenticated failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Invokes the `on_token_generated` callback.
  """
  def on_token_generated(user, token, claims) do
    impl().on_token_generated(user, token, claims)
  rescue
    e ->
      Logger.error("Auth hook on_token_generated failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Invokes the `enrich_claims` callback.
  """
  def enrich_claims(claims, user) do
    impl().enrich_claims(claims, user)
  rescue
    e ->
      Logger.error("Auth hook enrich_claims failed: #{inspect(e)}")
      claims
  end

  @doc """
  Invokes the `on_auth_failed` callback for failed authentication attempts.
  """
  def on_auth_failed(reason, context) do
    impl().on_auth_failed(reason, context)
  rescue
    e ->
      Logger.error("Auth hook on_auth_failed failed: #{inspect(e)}")
      {:error, e}
  end

  defp impl do
    Application.get_env(:serviceradar_web_ng, :auth_hooks_module, __MODULE__.Default)
  end
end

defmodule ServiceRadarWebNGWeb.Auth.Hooks.Default do
  @moduledoc """
  Default implementation of authentication hooks with structured logging.

  This module provides audit logging for authentication events. Replace this
  with a custom implementation when integrating with Permit or other
  authorization systems.

  ## Logging

  All authentication events are logged with structured metadata for security
  monitoring and debugging:

  - `event_type` - The type of auth event (user_created, auth_success, auth_failed)
  - `user_id` - The user ID (if available)
  - `email` - The user's email (if available)
  - `method` - The authentication method (oidc, saml, password, gateway)
  - `timestamp` - ISO8601 timestamp

  ## Example Log Output

      [info] auth_event: user_created user_id=uuid-123 method=oidc email=user@example.com
      [info] auth_event: auth_success user_id=uuid-123 method=password ip=192.168.1.1
      [warning] auth_event: auth_failed reason=invalid_credentials email=user@example.com ip=192.168.1.1
  """

  @behaviour ServiceRadarWebNGWeb.Auth.Hooks

  require Logger

  @impl true
  def on_user_created(user, source) do
    email = if is_nil(user.email), do: nil, else: to_string(user.email)

    Logger.info(
      "auth_event: user_created",
      event_type: :user_created,
      user_id: user.id,
      email: email,
      method: source,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    )

    :ok
  end

  @impl true
  def on_user_authenticated(user, claims) do
    method = claims["method"] || claims[:method] || detect_auth_method(claims)
    email = if is_nil(user.email), do: nil, else: to_string(user.email)

    Logger.info(
      "auth_event: auth_success",
      event_type: :auth_success,
      user_id: user.id,
      email: email,
      method: method,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    )

    :ok
  end

  @impl true
  def on_token_generated(user, _token, claims) do
    Logger.debug(
      "auth_event: token_generated",
      event_type: :token_generated,
      user_id: user.id,
      token_type: claims["typ"],
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    )

    :ok
  end

  @impl true
  def enrich_claims(claims, _user) do
    # Future: Add Permit permissions here
    # permissions = Permit.get_permissions(user)
    # Map.put(claims, "permissions", permissions)
    claims
  end

  @impl true
  def on_auth_failed(reason, context) do
    Logger.warning(
      "auth_event: auth_failed",
      event_type: :auth_failed,
      reason: reason,
      email: context[:email],
      method: context[:method],
      ip: context[:ip],
      user_agent: context[:user_agent],
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    )

    :ok
  end

  # Detect the authentication method from claims structure
  defp detect_auth_method(claims) do
    cond do
      Map.has_key?(claims, "assertion") -> :saml
      Map.has_key?(claims, "iss") and Map.has_key?(claims, "aud") -> :oidc
      Map.has_key?(claims, "sub") and Map.has_key?(claims, "typ") -> :jwt
      true -> :unknown
    end
  end
end
