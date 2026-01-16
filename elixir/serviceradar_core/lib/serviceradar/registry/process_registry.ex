defmodule ServiceRadar.ProcessRegistry do
  @moduledoc """
  Singleton Horde registry for process discovery.

  Each tenant deployment runs its own ERTS cluster with isolated resources.
  This single registry handles all process registration for the local instance.

  ## Usage

      # Register a gateway
      ProcessRegistry.register({:gateway, "gateway-001"}, %{status: :available})

      # Lookup
      ProcessRegistry.lookup({:gateway, "gateway-001"})

      # Find all gateways
      ProcessRegistry.select_by_type(:gateway)
  """

  @registry_name __MODULE__
  @supervisor_name ServiceRadar.ProcessRegistry.Supervisor

  @doc """
  Child specs for the supervision tree.
  """
  def child_specs do
    [
      {Horde.Registry,
       name: @registry_name,
       keys: :unique,
       members: :auto,
       delta_crdt_options: [sync_interval: 100]},
      {Horde.DynamicSupervisor,
       name: @supervisor_name,
       strategy: :one_for_one,
       members: :auto,
       delta_crdt_options: [sync_interval: 100]}
    ]
  end

  @doc """
  Returns the registry name.
  """
  @spec registry_name() :: atom()
  def registry_name, do: @registry_name

  @doc """
  Returns the supervisor name.
  """
  @spec supervisor_name() :: atom()
  def supervisor_name, do: @supervisor_name

  # ============================================================================
  # Child Process Management
  # ============================================================================

  @doc """
  Starts a child process under the DynamicSupervisor.
  """
  @spec start_child(Supervisor.child_spec()) :: {:ok, pid()} | {:error, term()}
  def start_child(child_spec) do
    Horde.DynamicSupervisor.start_child(@supervisor_name, child_spec)
  end

  @doc """
  Terminates a child process.
  """
  @spec terminate_child(pid()) :: :ok | {:error, :not_found}
  def terminate_child(pid) do
    Horde.DynamicSupervisor.terminate_child(@supervisor_name, pid)
  end

  # ============================================================================
  # Registration API
  # ============================================================================

  @doc """
  Registers a process in the registry.

  ## Parameters

    - `key` - Registration key (e.g., `{:gateway, "gateway-001"}`)
    - `metadata` - Process metadata

  ## Examples

      ProcessRegistry.register({:gateway, "gateway-001"}, %{
        partition_id: "partition-1",
        status: :available
      })
  """
  @spec register(term(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()} | term()}
  def register(key, metadata) do
    Horde.Registry.register(@registry_name, key, metadata)
  end

  @doc """
  Unregisters a process from the registry.
  """
  @spec unregister(term()) :: :ok
  def unregister(key) do
    Horde.Registry.unregister(@registry_name, key)
  end

  @doc """
  Updates metadata for a registered process.
  """
  @spec update_value(term(), (map() -> map())) :: {any(), any()} | :error
  def update_value(key, callback) do
    Horde.Registry.update_value(@registry_name, key, callback)
  end

  # ============================================================================
  # Lookup API
  # ============================================================================

  @doc """
  Looks up a process in the registry.

  Returns `[{pid, metadata}]` or `[]` if not found.
  """
  @spec lookup(term()) :: [{pid(), map()}]
  def lookup(key) do
    Horde.Registry.lookup(@registry_name, key)
  end

  @doc """
  Selects processes from the registry by type.

  ## Parameters

    - `type` - Process type atom (`:gateway`, `:agent`, `:checker`)

  ## Examples

      # Find all gateways
      ProcessRegistry.select_by_type(:gateway)
  """
  @spec select_by_type(atom()) :: [{term(), pid(), map()}]
  def select_by_type(type) do
    # Match keys that start with the type atom
    match_spec = [
      {{{type, :"$1"}, :"$2", :"$3"}, [], [{{{{type, :"$1"}}, :"$2", :"$3"}}]}
    ]

    Horde.Registry.select(@registry_name, match_spec)
  end

  @doc """
  Selects all processes from the registry.
  """
  @spec select_all() :: [{term(), pid(), map()}]
  def select_all do
    Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc """
  Counts processes in the registry.
  """
  @spec count() :: non_neg_integer()
  def count do
    Horde.Registry.count(@registry_name)
  end

  @doc """
  Counts processes of a specific type in the registry.
  """
  @spec count_by_type(atom()) :: non_neg_integer()
  def count_by_type(type) do
    select_by_type(type) |> length()
  end

  # ============================================================================
  # Via tuple support
  # ============================================================================

  @doc """
  Returns a via tuple for process registration.

  ## Examples

      GenServer.start_link(MyWorker, args, name: ProcessRegistry.via({:gateway, "gw-001"}))
  """
  @spec via(term()) :: {:via, module(), {atom(), term()}}
  def via(key) do
    {:via, Horde.Registry, {@registry_name, key}}
  end

  @doc """
  Returns a via tuple with initial metadata.
  """
  @spec via(term(), map()) :: {:via, module(), {atom(), term(), map()}}
  def via(key, metadata) do
    {:via, Horde.Registry, {@registry_name, key, metadata}}
  end

  # ============================================================================
  # Convenience Functions for Gateways
  # ============================================================================

  @doc """
  Registers a gateway in the registry.
  """
  @spec register_gateway(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def register_gateway(gateway_id, metadata) do
    full_metadata =
      metadata
      |> Map.put(:type, :gateway)
      |> Map.put(:registered_at, DateTime.utc_now())
      |> Map.put(:last_heartbeat, DateTime.utc_now())

    register({:gateway, gateway_id}, full_metadata)
  end

  @doc """
  Finds all gateways.
  """
  @spec find_gateways() :: [map()]
  def find_gateways do
    select_by_type(:gateway)
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Finds available gateways.
  """
  @spec find_available_gateways() :: [map()]
  def find_available_gateways do
    find_gateways()
    |> Enum.filter(&(&1[:status] == :available))
  end

  @doc """
  Updates heartbeat for a gateway.
  """
  @spec gateway_heartbeat(String.t()) :: :ok | :error
  def gateway_heartbeat(gateway_id) do
    case update_value({:gateway, gateway_id}, fn meta ->
           %{meta | last_heartbeat: DateTime.utc_now()}
         end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end

  # ============================================================================
  # Convenience Functions for Agents
  # ============================================================================

  @doc """
  Registers an agent in the registry.
  """
  @spec register_agent(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def register_agent(agent_id, metadata) do
    full_metadata =
      metadata
      |> Map.put(:type, :agent)
      |> Map.put(:registered_at, DateTime.utc_now())
      |> Map.put(:last_heartbeat, DateTime.utc_now())

    register({:agent, agent_id}, full_metadata)
  end

  @doc """
  Finds all agents.
  """
  @spec find_agents() :: [map()]
  def find_agents do
    select_by_type(:agent)
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Updates heartbeat for an agent.
  """
  @spec agent_heartbeat(String.t()) :: :ok | :error
  def agent_heartbeat(agent_id) do
    case update_value({:agent, agent_id}, fn meta ->
           %{meta | last_heartbeat: DateTime.utc_now()}
         end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end
end
