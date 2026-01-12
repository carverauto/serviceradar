defmodule ServiceRadar.AgentConfig.ConfigServer do
  @moduledoc """
  GenServer that orchestrates config compilation and caching.

  Provides the main API for getting compiled configs with automatic
  caching, hash-based change detection, and cache invalidation.

  ## Usage

      # Get config for an agent
      {:ok, config} = ConfigServer.get_config(tenant_id, :sweep, "default", "agent-123")

      # Check if config has changed
      case ConfigServer.get_config_if_changed(tenant_id, :sweep, "default", nil, current_hash) do
        {:ok, config} -> # Config changed, update agent
        :unchanged -> # No change, agent is up to date
      end

      # Invalidate cache when resources change
      ConfigServer.invalidate(tenant_id, :sweep)
  """

  use GenServer

  require Logger

  alias ServiceRadar.AgentConfig.{Compiler, ConfigCache, ConfigInstance}

  # Client API

  @doc """
  Starts the ConfigServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a compiled config for the specified parameters.

  Returns cached config if available, otherwise compiles and caches.
  """
  @spec get_config(String.t(), atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_config(tenant_id, config_type, partition, agent_id \\ nil, opts \\ []) do
    # Check cache first
    case ConfigCache.get(tenant_id, config_type, partition, agent_id) do
      {:ok, entry} ->
        {:ok, entry}

      :miss ->
        # Cache miss - compile and cache
        compile_and_cache(tenant_id, config_type, partition, agent_id, opts)
    end
  end

  @doc """
  Gets a compiled config only if it has changed from the given hash.

  Returns:
  - `{:ok, entry}` if config changed or not cached
  - `:unchanged` if hash matches cached config
  - `{:error, reason}` on compilation error
  """
  @spec get_config_if_changed(String.t(), atom(), String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map()} | :unchanged | {:error, term()}
  def get_config_if_changed(tenant_id, config_type, partition, agent_id, current_hash, opts \\ []) do
    case ConfigCache.get_if_changed(tenant_id, config_type, partition, agent_id, current_hash) do
      :unchanged ->
        :unchanged

      {:ok, entry} ->
        {:ok, entry}

      :miss ->
        # Cache miss - compile and check
        case compile_and_cache(tenant_id, config_type, partition, agent_id, opts) do
          {:ok, entry} ->
            if entry.hash == current_hash do
              :unchanged
            else
              {:ok, entry}
            end

          error ->
            error
        end
    end
  end

  @doc """
  Invalidates cached configs for a tenant and config type.

  Call this when source resources change.
  """
  @spec invalidate(String.t(), atom()) :: :ok
  def invalidate(tenant_id, config_type) do
    ConfigCache.invalidate(tenant_id, config_type)
    Logger.debug("ConfigServer: invalidated cache for tenant=#{tenant_id} type=#{config_type}")
    :ok
  end

  @doc """
  Invalidates all cached configs for a tenant.
  """
  @spec invalidate_tenant(String.t()) :: :ok
  def invalidate_tenant(tenant_id) do
    ConfigCache.invalidate_tenant(tenant_id)
    Logger.debug("ConfigServer: invalidated all cache for tenant=#{tenant_id}")
    :ok
  end

  @doc """
  Compiles config without using cache (force recompile).
  """
  @spec compile(String.t(), atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map() | ConfigInstance.t()} | {:error, term()}
  def compile(tenant_id, config_type, partition, agent_id, opts \\ []) do
    case Compiler.compiler_for(config_type) do
      {:ok, compiler} ->
        compiler.compile(tenant_id, partition, agent_id, opts)

      {:error, :unknown_config_type} ->
        # No compiler registered - try to load from database
        load_from_database(tenant_id, config_type, partition, agent_id)
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  # Private helpers

  defp compile_and_cache(tenant_id, config_type, partition, agent_id, opts) do
    case compile(tenant_id, config_type, partition, agent_id, opts) do
      {:ok, compiled_result} ->
        entry = build_cache_entry(compiled_result)
        ConfigCache.put(tenant_id, config_type, partition, agent_id, entry)
        {:ok, entry}

      {:error, _} = error ->
        error
    end
  end

  defp build_cache_entry(%ConfigInstance{compiled_config: compiled_config} = instance) do
    %{
      config: compiled_config,
      hash: instance.content_hash || Compiler.content_hash(compiled_config),
      version: instance.version || 1,
      cached_at: DateTime.utc_now()
    }
  end

  defp build_cache_entry(compiled_config) do
    %{
      config: compiled_config,
      hash: Compiler.content_hash(compiled_config),
      version: 1,
      cached_at: DateTime.utc_now()
    }
  end

  defp load_from_database(tenant_id, config_type, partition, agent_id) do
    # Try to load pre-compiled config from database using the :for_agent read action
    case Ash.read(
           ConfigInstance,
           action: :for_agent,
           tenant: tenant_id,
           authorize?: false,
           args: %{
             config_type: config_type,
             partition: partition,
             agent_id: agent_id
           }
        ) do
      {:ok, [instance | _]} ->
        {:ok, instance}

      {:ok, []} ->
        {:error, :no_config_found}

      {:error, reason} ->
        Logger.warning("ConfigServer: failed to load config from database: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("ConfigServer: exception loading config: #{inspect(e)}")
      {:error, e}
  end
end
