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

  defp impl do
    Application.get_env(:serviceradar_web_ng, :auth_hooks_module, __MODULE__.Default)
  end
end

defmodule ServiceRadarWebNGWeb.Auth.Hooks.Default do
  @moduledoc """
  Default no-op implementation of authentication hooks.

  This module provides pass-through implementations that don't perform
  any external operations. Replace this with a custom implementation
  when integrating with Permit or other authorization systems.
  """

  @behaviour ServiceRadarWebNGWeb.Auth.Hooks

  require Logger

  @impl true
  def on_user_created(user, source) do
    Logger.debug("User created via #{source}: #{user.id}")
    :ok
  end

  @impl true
  def on_user_authenticated(user, _claims) do
    Logger.debug("User authenticated: #{user.id}")
    :ok
  end

  @impl true
  def on_token_generated(_user, _token, _claims) do
    :ok
  end

  @impl true
  def enrich_claims(claims, _user) do
    # Future: Add Permit permissions here
    # permissions = Permit.get_permissions(user)
    # Map.put(claims, "permissions", permissions)
    claims
  end
end
