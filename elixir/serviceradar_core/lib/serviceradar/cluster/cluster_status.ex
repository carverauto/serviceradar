defmodule ServiceRadar.Cluster.ClusterStatus do
  @moduledoc """
  Unified API for cluster status queries from any node.

  This module provides cluster status information that works from any node
  in the ERTS cluster, regardless of whether the node is running the
  ClusterSupervisor/ClusterHealth coordinator processes.

  ## web-ng -> core-elx Architecture

  ServiceRadar uses a distributed architecture where different node types
  have different responsibilities:

  ```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                         ERTS Cluster                                │
  ├─────────────────────────────────────────────────────────────────────┤
  │                                                                     │
  │  ┌───────────────┐      ┌───────────────┐      ┌───────────────┐   │
  │  │   core-elx    │      │    web-ng     │      │  poller-elx   │   │
  │  │               │      │               │      │               │   │
  │  │ • ClusterSupv │      │ • LiveViews   │      │ • PollerProc  │   │
  │  │ • ClusterHlth │◄────►│ • ClusterStat │◄────►│ • Horde reg   │   │
  │  │ • AshOban     │      │ • Telemetry   │      │ • No DB       │   │
  │  │ • PollOrch    │      │ • DB access   │      │               │   │
  │  │ • DB access   │      │               │      │               │   │
  │  │               │      │               │      │               │   │
  │  │ cluster_coord │      │ cluster_coord │      │ cluster_coord │   │
  │  │    = true     │      │    = false    │      │    = false    │   │
  │  └───────────────┘      └───────────────┘      └───────────────┘   │
  │         │                      │                      │            │
  │         └──────────────────────┼──────────────────────┘            │
  │                                │                                   │
  │                    Horde Registries (synced)                       │
  │                    Phoenix.PubSub (broadcast)                      │
  │                    RPC (for coordinator queries)                   │
  │                                                                    │
  └─────────────────────────────────────────────────────────────────────┘
  ```

  ### Node Responsibilities

  - **core-elx** (cluster_coordinator=true):
    - Runs ClusterSupervisor for libcluster topology management
    - Runs ClusterHealth for cluster health monitoring and telemetry
    - Owns AshOban scheduler for job triggering
    - Orchestrates polls via PollOrchestrator
    - Has full database access

  - **web-ng** (cluster_coordinator=false):
    - Serves Phoenix LiveViews for the web UI
    - Uses this ClusterStatus module for cluster visibility
    - Queries Horde registries directly (synced across cluster)
    - Has database access for Ash resources
    - Does NOT run ClusterSupervisor/ClusterHealth

  - **poller-elx** (cluster_coordinator=false):
    - Runs PollerProcess for executing monitoring jobs
    - Registers in Horde for discovery by core-elx
    - No direct database access (uses gRPC to core)
    - Does NOT run ClusterSupervisor/ClusterHealth

  ### Cross-Node Communication

  1. **Horde Registries**: Process registration is automatically synced
     across all nodes via Horde's CRDT-based replication

  2. **Phoenix.PubSub**: Events (node_up, node_down, agent_registered)
     are broadcast to all nodes automatically

  3. **RPC**: This module uses `:rpc.call/4` to query ClusterHealth
     on core-elx when needed from web-ng

  ## Usage from web-ng

  web-ng nodes don't run ClusterSupervisor or ClusterHealth (they have
  `cluster_coordinator: false`), but they can still query cluster status
  through this module which:

  1. Gets node info directly from the ERTS `Node` module
  2. Queries registries via Horde (syncs across the cluster automatically)
  3. Optionally RPCs to core-elx for coordinator-specific health data

  ## Examples

      # Get full cluster status
      ServiceRadar.Cluster.ClusterStatus.get_status()

      # Get just node info
      ServiceRadar.Cluster.ClusterStatus.node_info()

      # Get registry counts
      ServiceRadar.Cluster.ClusterStatus.registry_counts()

      # Check if this node is the coordinator
      ServiceRadar.Cluster.ClusterStatus.coordinator?()

      # Find the coordinator node
      ServiceRadar.Cluster.ClusterStatus.find_coordinator()
  """

  alias ServiceRadar.PollerRegistry
  alias ServiceRadar.AgentRegistry

  @doc """
  Get comprehensive cluster status.

  Returns a map with node info, registry counts, and health status.
  Works from any node in the cluster.
  """
  @spec get_status() :: map()
  def get_status do
    node_info = node_info()
    counts = registry_counts()
    health = coordinator_health()

    %{
      enabled: node_info.connected_nodes != [],
      self: node_info.self,
      connected_nodes: node_info.connected_nodes,
      node_count: node_info.node_count,
      topologies: get_topologies(),
      poller_count: counts.poller_count,
      agent_count: counts.agent_count,
      status: health.status,
      last_check: health.last_check
    }
  end

  @doc """
  Get basic cluster node information.

  This always works as it uses the Node module directly.
  """
  @spec node_info() :: map()
  def node_info do
    connected = Node.list()

    %{
      self: Node.self(),
      connected_nodes: connected,
      node_count: length(connected) + 1
    }
  end

  @doc """
  Get registry counts from Horde registries.

  Works across the cluster via Horde's distributed state.
  """
  @spec registry_counts() :: map()
  def registry_counts do
    poller_count = safe_call(fn -> PollerRegistry.count() end, 0)
    agent_count = safe_call(fn -> AgentRegistry.count() end, 0)

    %{
      poller_count: poller_count,
      agent_count: agent_count
    }
  end

  @doc """
  Get health status from the cluster coordinator.

  If this node is the coordinator, queries ClusterHealth directly.
  Otherwise, attempts RPC to a connected core-elx node.
  Falls back to :unknown status if coordinator is unavailable.
  """
  @spec coordinator_health() :: map()
  def coordinator_health do
    cond do
      # Check if ClusterHealth is running locally
      cluster_health_local?() ->
        get_local_health()

      # Try RPC to core-elx nodes
      true ->
        get_remote_health()
    end
  end

  @doc """
  Check if this node is the cluster coordinator.

  Returns true if ClusterSupervisor and ClusterHealth are running locally.
  """
  @spec coordinator?() :: boolean()
  def coordinator? do
    cluster_health_local?()
  end

  @doc """
  Find the coordinator node in the cluster.

  Returns the node running ClusterHealth, or nil if not found.
  """
  @spec find_coordinator() :: node() | nil
  def find_coordinator do
    if coordinator?() do
      Node.self()
    else
      # Check connected nodes for coordinator
      Enum.find(Node.list(), fn node ->
        case :rpc.call(node, Process, :whereis, [ServiceRadar.ClusterHealth], 5000) do
          pid when is_pid(pid) -> true
          _ -> false
        end
      end)
    end
  end

  # Private functions

  defp cluster_health_local? do
    Process.whereis(ServiceRadar.ClusterHealth) != nil
  end

  defp get_local_health do
    try do
      health = ServiceRadar.ClusterHealth.get_health()

      %{
        status: health.status || :healthy,
        last_check: health.last_check,
        poller_count: health.poller_count || 0,
        agent_count: health.agent_count || 0
      }
    rescue
      _ ->
        %{status: :unknown, last_check: nil, poller_count: 0, agent_count: 0}
    end
  end

  defp get_remote_health do
    case find_coordinator() do
      nil ->
        # No coordinator found - return basic status
        %{status: :no_coordinator, last_check: nil, poller_count: 0, agent_count: 0}

      coordinator_node ->
        # RPC to coordinator for health status
        case :rpc.call(coordinator_node, ServiceRadar.ClusterHealth, :get_health, [], 5000) do
          {:badrpc, _reason} ->
            %{status: :rpc_error, last_check: nil, poller_count: 0, agent_count: 0}

          health when is_map(health) or is_struct(health) ->
            %{
              status: Map.get(health, :status, :healthy),
              last_check: Map.get(health, :last_check),
              poller_count: Map.get(health, :poller_count, 0),
              agent_count: Map.get(health, :agent_count, 0)
            }

          _ ->
            %{status: :unknown, last_check: nil, poller_count: 0, agent_count: 0}
        end
    end
  end

  defp get_topologies do
    Application.get_env(:libcluster, :topologies, [])
    |> Keyword.keys()
  rescue
    _ -> []
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
