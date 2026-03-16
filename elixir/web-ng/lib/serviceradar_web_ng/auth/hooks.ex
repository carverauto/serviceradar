defmodule ServiceRadarWebNG.Auth.Hooks do
  @moduledoc """
  Authentication lifecycle hooks for extensibility.

  This module defines callbacks that are invoked at key points in the
  authentication lifecycle. The default implementation is a no-op, but
  future integrations can implement these callbacks to:

  - Sync users to external authorization systems
  - Enrich tokens with authorization context
  - Log authentication events for audit trails
  """

  alias ServiceRadar.Identity.User

  require Logger

  @callback on_user_created(user :: User.t(), source :: atom()) :: :ok | {:error, term()}
  @callback on_user_authenticated(user :: User.t(), claims :: map()) :: :ok | {:error, term()}

  @callback on_token_generated(user :: User.t(), token :: String.t(), claims :: map()) ::
              :ok | {:error, term()}

  @callback enrich_claims(claims :: map(), user :: User.t()) :: map()
  @callback on_auth_failed(reason :: atom(), context :: map()) :: :ok | {:error, term()}

  @doc false
  def on_user_created(user, source), do: hooks_module().on_user_created(user, source)

  @doc false
  def on_user_authenticated(user, claims), do: hooks_module().on_user_authenticated(user, claims)

  @doc false
  def on_token_generated(user, token, claims),
    do: hooks_module().on_token_generated(user, token, claims)

  @doc false
  def enrich_claims(claims, user), do: hooks_module().enrich_claims(claims, user)

  @doc false
  def on_auth_failed(reason, context), do: hooks_module().on_auth_failed(reason, context)

  defp hooks_module do
    Application.get_env(:serviceradar_web_ng, :auth_hooks_module, ServiceRadarWebNG.Auth.Hooks.Default)
  end
end

defmodule ServiceRadarWebNG.Auth.Hooks.Default do
  @moduledoc false

  @behaviour ServiceRadarWebNG.Auth.Hooks

  require Logger

  @impl true
  def on_user_created(user, source) do
    Logger.debug("Auth hook: user created user_id=#{user.id} source=#{inspect(source)}")
    :ok
  end

  @impl true
  def on_user_authenticated(user, _claims) do
    Logger.debug("Auth hook: user authenticated", user_id: user.id)
    :ok
  end

  @impl true
  def on_token_generated(user, _token, claims) do
    Logger.debug("Auth hook: token generated", user_id: user.id, token_type: claims["typ"])
    :ok
  end

  @impl true
  def enrich_claims(claims, _user), do: claims

  @impl true
  def on_auth_failed(reason, context) do
    Logger.warning("Authentication failed reason=#{inspect(reason)} context=#{inspect(context)}")
    :ok
  end
end
