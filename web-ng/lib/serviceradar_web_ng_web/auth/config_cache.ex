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
    ttl_ms = current_ttl_ms()

    case :ets.lookup(@table, :auth_settings) do
      [{:auth_settings, settings, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, settings}
        else
          # TTL expired. Refresh in the caller process (avoids Ecto SQL sandbox ownership issues
          # when ConfigCache is running in tests and the GenServer isn't allowed).
          load_and_cache(ttl_ms)
        end

      [] ->
        # Cache miss, fetch and cache (in caller).
        load_and_cache(ttl_ms)
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
    load_and_cache(current_ttl_ms())
  end

  @doc """
  Invalidates the cache and forces a refresh.

  Call this after updating auth settings to ensure all nodes pick up changes.
  """
  def invalidate do
    # Clear the local cache
    :ets.delete(@table, :auth_settings)
    # Force a refresh to reload from database
    refresh()
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

  @doc """
  Alias for get_config/0 for consistency with other code.
  """
  def get_settings do
    get_config()
  end

  @doc """
  Gets a cached value by key.

  Returns `{:ok, value}` if found and not expired, `:miss` otherwise.
  Used for caching OIDC discovery metadata, JWKS, etc.
  """
  def get_cached(key) do
    case :ets.lookup(@table, {:cache, key}) do
      [{{:cache, ^key}, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, {:cache, key})
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Stores a value in the cache with optional TTL.

  Options:
  - `:ttl` - Time-to-live in milliseconds (default: 60 seconds)
  """
  def put_cached(key, value, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl_ms)
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table, {{:cache, key}, value, expires_at})
    :ok
  end

  @doc """
  Removes a cached value by key.
  """
  def delete_cached(key) do
    :ets.delete(@table, {:cache, key})
    :ok
  end

  @doc """
  Clears all cached values (but not auth_settings).
  """
  def clear_cache do
    :ets.match_delete(@table, {{:cache, :_}, :_, :_})
    :ok
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    # Create ETS table for caching
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # Subscribe to auth settings changes
    Phoenix.PubSub.subscribe(ServiceRadarWebNG.PubSub, @pubsub_topic)

    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    # Store TTL in ETS so refreshes can happen in the caller process without a GenServer call.
    :ets.insert(@table, {:ttl_ms, ttl_ms})

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

  defp current_ttl_ms do
    case :ets.lookup(@table, :ttl_ms) do
      [{:ttl_ms, ttl_ms}] when is_integer(ttl_ms) and ttl_ms > 0 -> ttl_ms
      _ -> @default_ttl_ms
    end
  end
end
