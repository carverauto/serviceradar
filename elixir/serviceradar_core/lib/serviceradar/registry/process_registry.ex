defmodule ServiceRadar.ProcessRegistry do
  @moduledoc """
  Singleton Horde registry for process discovery.

  Each deployment runs its own ERTS cluster with isolated resources.
  This single registry handles all process registration for the local instance.

  ## Usage

      # Register a gateway (per-node key)
      ProcessRegistry.register({:gateway, "gateway-001", node()}, %{status: :available})

      # Lookup all gateway instances
      ProcessRegistry.lookup_gateway("gateway-001")

      # Find all gateways
      ProcessRegistry.select_by_type(:gateway)
  """

  @registry_name __MODULE__
  @supervisor_name ServiceRadar.ProcessSupervisor

  @doc """
  Child specs for the supervision tree.

  Every node joins the Horde registry (cluster-wide process lookups for the
  UI and gateways), but only process-host nodes start the Horde
  DynamicSupervisor: `members: :auto` makes every supervisor member a
  placement target, and web-ng must never host distributed agent processes
  (they pull agent-config compilation and other core-elx work onto the web
  tier). Configure with:

      config :serviceradar_core, host_distributed_processes: false

  ## DeltaCrdt sync interval

  Horde gossips the registry/supervisor CRDT to peers every `sync_interval`
  milliseconds. The library default (~50ms) means a small idle cluster still
  re-gossips ~20x/sec, which dominated idle BEAM reductions even with only a
  handful of registry entries — it is sync *frequency*, not state size. These
  singletons are stable, so a multi-second interval keeps failover acceptable
  while cutting the idle churn. Configure with the
  `SERVICERADAR_HORDE_SYNC_INTERVAL_MS` env var (default `3000`) or:

      config :serviceradar_core, horde_sync_interval_ms: 3000

  ## Joining the registry mesh

  Every Horde.Registry member is a DeltaCrdt node in the shared CRDT, and each
  CRDT process picks a *random* `node_id` that is never collectable: once a
  member has gossiped, its dot lingers in the merged CRDT state forever. The
  ServiceRadar nodes use ephemeral names (`basename@POD_IP`) and roll
  frequently, so a tier that rolls often (web-ng) permanently injects a fresh
  random dot on every rollout, bloating the shared causal context. web-ng only
  *reads* the registry (and can RPC those reads to a core node), so it is taken
  out of the mesh entirely. The agent-gateway *writes* the entries core reads,
  so it must stay a member. Configure with:

      config :serviceradar_core, join_process_registry: false
  """
  @default_horde_sync_interval_ms 3000

  # DeltaCrdt's own default; Horde overrides it to `:infinite`. We re-pin it as a
  # defensive bound on the per-sync key/merkle fan-out for these stable
  # singletons.
  @max_sync_size 200

  def child_specs do
    if join_process_registry?() do
      sync_interval = horde_sync_interval_ms()

      registry =
        {Horde.Registry,
         name: @registry_name,
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: sync_interval, max_sync_size: @max_sync_size]}

      if host_distributed_processes?() do
        [
          registry,
          {Horde.DynamicSupervisor,
           name: @supervisor_name,
           strategy: :one_for_one,
           members: :auto,
           delta_crdt_options: [sync_interval: sync_interval, max_sync_size: @max_sync_size]}
        ]
      else
        [registry]
      end
    else
      []
    end
  end

  @doc """
  DeltaCrdt sync interval (ms) for the Horde registry and supervisor.

  Resolution order: `SERVICERADAR_HORDE_SYNC_INTERVAL_MS` env var, then the
  `:horde_sync_interval_ms` app env, then the #{@default_horde_sync_interval_ms}ms
  default.
  """
  @spec horde_sync_interval_ms() :: pos_integer()
  def horde_sync_interval_ms do
    case System.get_env("SERVICERADAR_HORDE_SYNC_INTERVAL_MS") do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {ms, ""} when ms > 0 -> ms
          _ -> app_env_horde_sync_interval_ms()
        end

      _ ->
        app_env_horde_sync_interval_ms()
    end
  end

  defp app_env_horde_sync_interval_ms do
    case Application.get_env(:serviceradar_core, :horde_sync_interval_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_horde_sync_interval_ms
    end
  end

  @doc "Whether this node hosts Horde-distributed processes (default true)."
  @spec host_distributed_processes?() :: boolean()
  def host_distributed_processes? do
    Application.get_env(:serviceradar_core, :host_distributed_processes, true)
  end

  @doc """
  Whether this node joins the Horde registry CRDT mesh (default true).

  When false the registry child is not started at all, so this node neither
  gossips nor injects a permanent random `node_id` into the shared CRDT. Read
  paths (gateway/agent lookups) must RPC a core node instead — see
  `core_node/0`.
  """
  @spec join_process_registry?() :: boolean()
  def join_process_registry? do
    Application.get_env(:serviceradar_core, :join_process_registry, true)
  end

  @doc """
  Whether the local Horde registry process is running on this node.

  Read wrappers use this to decide between a local registry call and an RPC to a
  core node (for tiers that left the mesh via `join_process_registry?/0`).
  """
  @spec registry_present?() :: boolean()
  def registry_present? do
    Process.whereis(@registry_name) != nil
  end

  @doc """
  Picks a connected core node to satisfy a registry read RPC, or `nil`.

  Core nodes are identified by their cluster basename (the same
  `serviceradar_core@…` convention libcluster/runtime.exs use). The basename is
  configurable via `config :serviceradar_core, :core_node_basename, "…"` and
  defaults to `"serviceradar_core"`.
  """
  @spec core_node() :: node() | nil
  def core_node, do: List.first(core_nodes())

  @doc "Connected core nodes that can satisfy registry read RPCs."
  @spec core_nodes() :: [node()]
  def core_nodes do
    Enum.filter(registry_nodes(), &node_has_basename?(&1, core_node_basename()))
  end

  @doc """
  Connected nodes that host the Horde registry.

  Agent gateways own the live control-session registrations and core nodes
  receive them through Horde CRDT replication. Querying every connected
  registry member prevents a newly connected session from being missed merely
  because the first core node selected for an RPC has not converged yet.
  """
  @spec registry_nodes([node()]) :: [node()]
  def registry_nodes(nodes \\ Node.list(:visible)) when is_list(nodes) do
    basenames = MapSet.new([core_node_basename(), gateway_node_basename()])

    nodes
    |> Enum.filter(fn node ->
      Enum.any?(basenames, &node_has_basename?(node, &1))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Cluster basename for core nodes (default `serviceradar_core`)."
  @spec core_node_basename() :: String.t()
  def core_node_basename do
    case Application.get_env(:serviceradar_core, :core_node_basename, "serviceradar_core") do
      value when is_binary(value) and value != "" -> value
      _ -> "serviceradar_core"
    end
  end

  @doc "Cluster basename for agent-gateway nodes (default `serviceradar_agent_gateway`)."
  @spec gateway_node_basename() :: String.t()
  def gateway_node_basename do
    case Application.get_env(
           :serviceradar_core,
           :gateway_node_basename,
           "serviceradar_agent_gateway"
         ) do
      value when is_binary(value) and value != "" -> value
      _ -> "serviceradar_agent_gateway"
    end
  end

  defp node_has_basename?(node, basename) when is_atom(node) and is_binary(basename) do
    node
    |> Atom.to_string()
    |> String.starts_with?(basename <> "@")
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
    if host_distributed_processes?() do
      Horde.DynamicSupervisor.start_child(@supervisor_name, child_spec)
    else
      {:error, :not_a_process_host}
    end
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

    - `key` - Registration key (e.g., `{:gateway, "gateway-001", node()}`)
    - `metadata` - Process metadata

  ## Examples

      ProcessRegistry.register({:gateway, "gateway-001", node()}, %{
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
    # Match keys that start with the type atom and include the node key
    match_spec = [
      {{{type, :"$1", :"$2", :"$3"}, :"$4", :"$5"}, [],
       [{{{{type, :"$1", :"$2", :"$3"}}, :"$4", :"$5"}}]},
      {{{type, :"$1", :"$2"}, :"$3", :"$4"}, [], [{{{{type, :"$1", :"$2"}}, :"$3", :"$4"}}]},
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
    type |> select_by_type() |> length()
  end

  # ============================================================================
  # Via tuple support
  # ============================================================================

  @doc """
  Returns a via tuple for process registration.

  ## Examples

      GenServer.start_link(MyWorker, args, name: ProcessRegistry.via({:gateway, "gw-001", node()}))
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
  @spec register_gateway(String.t(), map(), node()) :: {:ok, pid()} | {:error, term()}
  def register_gateway(gateway_id, metadata, node \\ Node.self()) do
    full_metadata =
      metadata
      |> Map.put(:type, :gateway)
      |> Map.put(:registered_at, DateTime.utc_now())
      |> Map.put(:last_heartbeat, DateTime.utc_now())

    register({:gateway, gateway_id, node}, full_metadata)
  end

  @doc """
  Unregisters a gateway instance from the registry.
  """
  @spec unregister_gateway(String.t(), node()) :: :ok
  def unregister_gateway(gateway_id, node \\ Node.self()) do
    unregister({:gateway, gateway_id, node})
  end

  @doc """
  Finds all gateways.
  """
  @spec find_gateways() :: [map()]
  def find_gateways do
    :gateway
    |> select_by_type()
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Looks up all gateway instances for a gateway ID.
  """
  @spec lookup_gateway(String.t()) :: [{pid(), map()}]
  def lookup_gateway(gateway_id) when is_binary(gateway_id) do
    match_spec = [
      {{{:gateway, gateway_id, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]},
      {{{:gateway, gateway_id}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    Horde.Registry.select(@registry_name, match_spec)
  end

  @doc """
  Finds available gateways.
  """
  @spec find_available_gateways() :: [map()]
  def find_available_gateways do
    Enum.filter(find_gateways(), &(&1[:status] == :available))
  end

  @doc """
  Updates heartbeat for a gateway.
  """
  @spec gateway_heartbeat(String.t(), node()) :: :ok | :error
  def gateway_heartbeat(gateway_id, node \\ Node.self()) do
    case update_value({:gateway, gateway_id, node}, fn meta ->
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
  @spec register_agent(String.t(), map(), node()) :: {:ok, pid()} | {:error, term()}
  def register_agent(agent_id, metadata, node \\ Node.self()) do
    full_metadata =
      metadata
      |> Map.put(:type, :agent)
      |> Map.put(:registered_at, DateTime.utc_now())
      |> Map.put(:last_heartbeat, DateTime.utc_now())

    register({:agent, agent_id, node}, full_metadata)
  end

  @doc """
  Unregisters an agent instance from the registry.
  """
  @spec unregister_agent(String.t(), node()) :: :ok
  def unregister_agent(agent_id, node \\ Node.self()) do
    unregister({:agent, agent_id, node})
  end

  @doc """
  Finds all agents.
  """
  @spec find_agents() :: [map()]
  def find_agents do
    :agent
    |> select_by_type()
    |> Enum.map(fn {key, pid, metadata} ->
      Map.merge(metadata, %{key: key, pid: pid})
    end)
  end

  @doc """
  Looks up all agent instances for an agent ID.
  """
  @spec lookup_agent(String.t()) :: [{pid(), map()}]
  def lookup_agent(agent_id) when is_binary(agent_id) do
    match_spec = [
      {{{:agent, agent_id, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]},
      {{{:agent, agent_id}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    Horde.Registry.select(@registry_name, match_spec)
  end

  @doc """
  Looks up active control-stream sessions for one authenticated edge principal.

  Control authority is keyed by the certificate-derived `{partition_id,
  agent_id}` pair. The gateway node remains part of the registry key so rolling
  reconnects on separate gateways can coexist while Horde converges.
  """
  @spec lookup_agent_control(String.t(), String.t()) :: [{pid(), map()}]
  def lookup_agent_control(partition_id, agent_id)
      when is_binary(partition_id) and is_binary(agent_id) do
    match_spec = [
      {{{:agent_control, partition_id, agent_id, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}
    ]

    Horde.Registry.select(@registry_name, match_spec)
  end

  @doc """
  Enumerates every control stream carrying an agent id across all partitions.

  This is a fleet-observation API only. Its result is not an authority lookup:
  callers that send commands, resolve credentials, or consume plugin evidence
  must first choose a server-owned partition and then call
  `lookup_agent_control/2`.

  Legacy two- and three-element keys are included only so operators can observe
  them during a rolling upgrade. They are never returned by the exact lookup.
  """
  @spec list_agent_controls(String.t()) :: [{pid(), map()}]
  def list_agent_controls(agent_id) when is_binary(agent_id) do
    match_spec = [
      {{{:agent_control, :"$1", agent_id, :"$2"}, :"$3", :"$4"}, [], [{{:"$3", :"$4"}}]},
      {{{:agent_control, agent_id, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]},
      {{{:agent_control, agent_id}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    Horde.Registry.select(@registry_name, match_spec)
  end

  @doc """
  Legacy agent-only control-stream enumeration.

  This delegates to `list_agent_controls/1` and must not be used to select an
  authoritative session. Use `lookup_agent_control/2` for all control actions.
  """
  @spec lookup_agent_control(String.t()) :: [{pid(), map()}]
  def lookup_agent_control(agent_id) when is_binary(agent_id), do: list_agent_controls(agent_id)

  @doc """
  Updates heartbeat for an agent.
  """
  @spec agent_heartbeat(String.t(), node()) :: :ok | :error
  def agent_heartbeat(agent_id, node \\ Node.self()) do
    case update_value({:agent, agent_id, node}, fn meta ->
           %{meta | last_heartbeat: DateTime.utc_now()}
         end) do
      {_new, _old} -> :ok
      :error -> :error
    end
  end
end
