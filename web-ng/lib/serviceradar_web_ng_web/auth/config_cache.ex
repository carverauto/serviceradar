defmodule ServiceRadarWebNGWeb.Auth.ConfigCache do
  @moduledoc """
  Caches authentication settings for fast access during request handling.

  This GenServer maintains an ETS cache of the auth_settings configuration,
  refreshing it on a TTL basis and responding to PubSub invalidation events
  when an admin updates the configuration.

  ## Usage

      # Get current auth settings (cached)
      {:ok, settings} = ConfigCache.get_config()

      # Force a refresh (rarely needed)
      ConfigCache.refresh()

  ## Cache Behavior

  - TTL: 60 seconds (configurable)
  - Immediate invalidation via PubSub when admin saves changes
  - Fallback to database on cache miss
  - Returns `{:error, :not_configured}` if no settings exist
  """

  use GenServer
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthSettings

  @table __MODULE__
  @default_ttl_ms 60_000
  @pubsub_topic "auth_settings:changed"

  # Client API

  @doc """
  Starts the ConfigCache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the cached auth settings.

  Returns `{:ok, settings}` if configured, `{:error, :not_configured}` otherwise.
  The result is cached and will be refreshed after the TTL expires or when
  the settings are updated via the admin UI.
  """
  def get_config do
    case :ets.lookup(@table, :auth_settings) do
      [{:auth_settings, settings, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, settings}
        else
          # TTL expired, refresh
          GenServer.call(__MODULE__, :refresh)
        end

      [] ->
        # Cache miss, fetch and cache
        GenServer.call(__MODULE__, :refresh)
    end
  end

  @doc """
  Gets the cached auth settings, raising on error.

  Raises `RuntimeError` if settings are not configured.
  """
  def get_config! do
    case get_config() do
      {:ok, settings} -> settings
      {:error, reason} -> raise "Failed to get auth config: #{inspect(reason)}"
    end
  end

  @doc """
  Forces a cache refresh.

  Useful after manual database changes outside of the normal update flow.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc """
  Checks if SSO is enabled without fetching full settings.

  This is a fast path for checking if SSO redirection should happen.
  """
  def sso_enabled? do
    case get_config() do
      {:ok, settings} -> AuthSettings.sso_enabled?(settings)
      {:error, _} -> false
    end
  end

  @doc """
  Gets the current authentication mode.

  Returns `:password_only`, `:active_sso`, or `:passive_proxy`.
  """
  def get_mode do
    case get_config() do
      {:ok, settings} -> settings.mode
      {:error, _} -> :password_only
    end
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    # Create ETS table for caching
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # Subscribe to auth settings changes
    Phoenix.PubSub.subscribe(ServiceRadarWebNG.PubSub, @pubsub_topic)

    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    # Initial load
    load_and_cache(ttl_ms)

    {:ok, %{ttl_ms: ttl_ms}}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    result = load_and_cache(state.ttl_ms)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:auth_settings_updated, settings}, state) do
    Logger.info("Auth settings updated, refreshing cache")
    cache_settings(settings, state.ttl_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp load_and_cache(ttl_ms) do
    actor = SystemActor.system(:config_cache)

    case Ash.read_one(AuthSettings, actor: actor) do
      {:ok, nil} ->
        Logger.warning("No auth_settings found in database")
        {:error, :not_configured}

      {:ok, settings} ->
        cache_settings(settings, ttl_ms)
        {:ok, settings}

      {:error, error} ->
        Logger.error("Failed to load auth_settings: #{inspect(error)}")
        {:error, :load_failed}
    end
  end

  defp cache_settings(settings, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {:auth_settings, settings, expires_at})
  end
end
