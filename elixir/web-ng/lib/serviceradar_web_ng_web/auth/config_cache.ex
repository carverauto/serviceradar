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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthSettings

  require Logger

  @table __MODULE__
  @default_ttl_ms 60_000
  @refresh_timeout 15_000
  @pubsub_topic "auth_settings:changed"
  @pubsub_server ServiceRadar.PubSub

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
    case cached_auth_settings() do
      {:ok, settings} -> {:ok, settings}
      :stale -> coordinated_refresh(:stale)
      :miss -> coordinated_refresh(:miss)
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
    coordinated_refresh(:force)
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
    Phoenix.PubSub.subscribe(@pubsub_server, @pubsub_topic)

    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    # Store TTL in ETS so refreshes can happen in the caller process without a GenServer call.
    :ets.insert(@table, {:ttl_ms, ttl_ms})

    {:ok, %{ttl_ms: ttl_ms, refreshing: nil}}
  end

  @impl GenServer
  def handle_call({:begin_refresh, mode}, from, state) do
    reply_or_wait_for_refresh(mode, from, state)
  end

  def handle_call({:complete_refresh, refresh_ref, result}, _from, state) do
    case state.refreshing do
      %{ref: ^refresh_ref, waiters: waiters, monitor_ref: monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, result))
        {:reply, :ok, %{state | refreshing: nil}}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_info({:auth_settings_updated, settings}, state) do
    Logger.info("Auth settings updated, refreshing cache")
    cache_settings(settings, state.ttl_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case state.refreshing do
      %{monitor_ref: ^monitor_ref, waiters: waiters} ->
        Logger.warning("Auth config refresh owner exited before completion: #{inspect(reason)}")
        Enum.each(waiters, &GenServer.reply(&1, {:error, :load_failed}))
        {:noreply, %{state | refreshing: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp coordinated_refresh(mode) do
    case GenServer.call(__MODULE__, {:begin_refresh, mode}, @refresh_timeout) do
      {:ok, _settings} = ok ->
        ok

      {:refresh, refresh_ref, ttl_ms} ->
        result = load_and_cache(ttl_ms)
        :ok = GenServer.call(__MODULE__, {:complete_refresh, refresh_ref, result}, @refresh_timeout)
        result
    end
  end

  defp reply_or_wait_for_refresh(mode, from, state) do
    case {mode, cached_auth_settings(), state.refreshing} do
      {:force, _cached, %{waiters: waiters} = refreshing} ->
        {:noreply, %{state | refreshing: %{refreshing | waiters: [from | waiters]}}}

      {:force, _cached, nil} ->
        {new_state, refresh_ref} = begin_refresh(state, from)
        {:reply, {:refresh, refresh_ref, state.ttl_ms}, new_state}

      {_mode, {:ok, settings}, _refreshing} ->
        {:reply, {:ok, settings}, state}

      {_mode, _cached, %{waiters: waiters} = refreshing} ->
        {:noreply, %{state | refreshing: %{refreshing | waiters: [from | waiters]}}}

      {_mode, _cached, nil} ->
        {new_state, refresh_ref} = begin_refresh(state, from)
        {:reply, {:refresh, refresh_ref, state.ttl_ms}, new_state}
    end
  end

  defp begin_refresh(state, {owner, _tag}) do
    refresh_ref = make_ref()
    monitor_ref = Process.monitor(owner)

    new_state = %{state | refreshing: %{ref: refresh_ref, monitor_ref: monitor_ref, waiters: []}}
    {new_state, refresh_ref}
  end

  defp load_and_cache(ttl_ms) do
    case load_settings() do
      {:ok, settings} ->
        cache_settings(settings, ttl_ms)
        {:ok, settings}

      {:error, :not_configured} ->
        Logger.warning("No auth_settings found in database")
        {:error, :not_configured}

      {:error, error} ->
        Logger.error("Failed to load auth_settings: #{inspect(error)}")
        {:error, :load_failed}
    end
  end

  defp load_settings do
    auth_settings_loader().()
  end

  defp auth_settings_loader do
    Application.get_env(:serviceradar_web_ng, :auth_settings_loader, &load_settings_from_db/0)
  end

  defp load_settings_from_db do
    actor = SystemActor.system(:config_cache)

    case Ash.read_one(AuthSettings, actor: actor) do
      {:ok, nil} -> {:error, :not_configured}
      {:ok, settings} -> {:ok, settings}
      {:error, error} -> {:error, error}
    end
  end

  defp cache_settings(settings, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {:auth_settings, settings, expires_at})
  end

  defp cached_auth_settings do
    case :ets.lookup(@table, :auth_settings) do
      [{:auth_settings, settings, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, settings}
        else
          :stale
        end

      [] ->
        :miss
    end
  end
end
