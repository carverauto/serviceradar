defmodule ServiceRadar.AgentConfig.ConfigServer do
  @moduledoc """
  GenServer that orchestrates config compilation and caching.

  Provides the main API for getting compiled configs with automatic
  caching, hash-based change detection, and cache invalidation.

  ## Usage

      # Get config for an agent
      {:ok, config} = ConfigServer.get_config(:sweep, "default", "agent-123")

      # Check if config has changed
      case ConfigServer.get_config_if_changed(:sweep, "default", nil, current_hash) do
        {:ok, config} -> # Config changed, update agent
        :unchanged -> # No change, agent is up to date
      end

      # Invalidate cache when resources change
      ConfigServer.invalidate(:sweep)
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.AgentConfig.ConfigInstance

  require Logger

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
  @spec get_config(atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_config(config_type, partition, agent_id \\ nil, opts \\ []) do
    scope = cache_scope(config_type, opts)

    # Check cache first
    case ConfigCache.get(config_type, partition, agent_id, scope) do
      {:ok, entry} ->
        {:ok, entry}

      :miss ->
        # Cache miss - compile and cache
        compile_and_cache(config_type, partition, agent_id, opts)
    end
  end

  @doc """
  Gets a compiled config only if it has changed from the given hash.

  Returns:
  - `{:ok, entry}` if config changed or not cached
  - `:unchanged` if hash matches cached config
  - `{:error, reason}` on compilation error
  """
  @spec get_config_if_changed(atom(), String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map()} | :unchanged | {:error, term()}
  def get_config_if_changed(config_type, partition, agent_id, current_hash, opts \\ []) do
    scope = cache_scope(config_type, opts)

    case ConfigCache.get_if_changed(config_type, partition, agent_id, current_hash, scope) do
      :unchanged ->
        :unchanged

      {:ok, entry} ->
        {:ok, entry}

      :miss ->
        # Cache miss - compile and check
        compile_cache_miss(config_type, partition, agent_id, current_hash, opts)
    end
  end

  defp compile_cache_miss(config_type, partition, agent_id, current_hash, opts) do
    case compile_and_cache(config_type, partition, agent_id, opts) do
      {:ok, entry} when entry.hash == current_hash ->
        :unchanged

      {:ok, entry} ->
        {:ok, entry}

      error ->
        error
    end
  end

  @doc """
  Invalidates cached configs for a config type.

  Call this when source resources change.
  """
  @spec invalidate(atom()) :: :ok
  def invalidate(config_type) do
    ConfigCache.invalidate(config_type)
    Logger.debug("ConfigServer: invalidated cache for type=#{config_type}")
    ServiceRadar.Edge.AgentCommandBus.push_config_for_type(config_type)
    :ok
  end

  @doc """
  Compiles config without using cache (force recompile).
  """
  @spec compile(atom(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map() | ConfigInstance.t()} | {:error, term()}
  def compile(config_type, partition, agent_id, opts \\ []) do
    case Compiler.compiler_for(config_type) do
      {:ok, compiler} ->
        compiler.compile(partition, agent_id, opts)

      {:error, :unknown_config_type} ->
        # No compiler registered - try to load from database
        load_from_database(config_type, partition, agent_id)
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  # Private helpers

  defp compile_and_cache(config_type, partition, agent_id, opts) do
    scope = cache_scope(config_type, opts)

    case compile(config_type, partition, agent_id, opts) do
      {:ok, compiled_result} ->
        entry = build_cache_entry(compiled_result)
        ConfigCache.put(config_type, partition, agent_id, entry, scope)
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

  defp load_from_database(config_type, partition, agent_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:config_server)

    # Try to load pre-compiled config from database using the :for_agent read action
    case Ash.read(
           ConfigInstance,
           action: :for_agent,
           args: %{
             config_type: config_type,
             partition: partition,
             agent_id: agent_id
           },
           actor: actor
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

  defp cache_scope(config_type, opts)

  defp cache_scope(config_type, opts) when config_type in [:mapper, :snmp, :sysmon] do
    case Keyword.get(opts, :device_uid) do
      device_uid when is_binary(device_uid) and device_uid != "" ->
        {:device_uid, device_uid}

      _ ->
        nil
    end
  end

  defp cache_scope(_config_type, _opts), do: nil
end
