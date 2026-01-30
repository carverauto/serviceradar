defmodule ServiceRadar.AgentConfig.Compiler do
  @moduledoc """
  Behaviour for config compilers that transform Ash resources into agent-consumable format.

  Each config type (sweep, poller, checker) implements this behaviour to compile
  configurations from Ash resources into JSON format that agents expect.

  Schema isolation is handled by the database connection's search_path.

  ## Implementing a Compiler

      defmodule MyApp.SweepCompiler do
        @behaviour ServiceRadar.AgentConfig.Compiler

        @impl true
        def config_type, do: :sweep

        @impl true
        def compile(partition, agent_id, opts) do
          # Query Ash resources and build config
          {:ok, %{networks: [...], ports: [...]}}
        end

        @impl true
        def source_resources do
          [MyApp.SweepGroup, MyApp.SweepProfile]
        end
      end
  """

  @type partition :: String.t()
  @type agent_id :: String.t() | nil
  @type config_type :: :sweep | :sysmon | :snmp | :mapper | :poller | :checker
  @type compiled_config :: map()
  @type compile_opts :: [actor: map(), timeout: pos_integer()]

  @doc """
  Returns the config type this compiler handles.
  """
  @callback config_type() :: config_type()

  @doc """
  Compiles configuration for a specific partition and optional agent.

  Returns `{:ok, compiled_config}` or `{:error, reason}`.

  The compiled config should be a map that can be JSON-encoded and sent to agents.
  """
  @callback compile(partition(), agent_id(), compile_opts()) ::
              {:ok, compiled_config()} | {:error, term()}

  @doc """
  Returns the list of Ash resource modules that contribute to this config type.

  Used for cache invalidation - when any of these resources change, the cache
  for this config type is invalidated.
  """
  @callback source_resources() :: [module()]

  @doc """
  Optional callback to validate a compiled config before caching.

  Default implementation always returns `:ok`.
  """
  @callback validate(compiled_config()) :: :ok | {:error, term()}

  @optional_callbacks [validate: 1]

  # Registry of available compilers
  # Note: Dusk checker was migrated to the WASM plugin system and no longer
  # requires a compiler. It's managed through regular PluginAssignment records.
  @compilers %{
    sweep: ServiceRadar.AgentConfig.Compilers.SweepCompiler,
    sysmon: ServiceRadar.AgentConfig.Compilers.SysmonCompiler,
    snmp: ServiceRadar.AgentConfig.Compilers.SNMPCompiler,
    mapper: ServiceRadar.AgentConfig.Compilers.MapperCompiler
  }

  @doc """
  Returns the compiler module for a given config type, if registered.
  """
  @spec compiler_for(config_type()) :: {:ok, module()} | {:error, :unknown_config_type}
  def compiler_for(config_type) do
    case Map.get(@compilers, config_type) do
      nil -> {:error, :unknown_config_type}
      module -> {:ok, module}
    end
  end

  @doc """
  Returns all registered config types.
  """
  @spec config_types() :: [config_type()]
  def config_types do
    Map.keys(@compilers)
  end

  @doc """
  Computes a content hash for a compiled config.
  """
  @spec content_hash(compiled_config()) :: String.t()
  def content_hash(config) when is_map(config) do
    config
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
