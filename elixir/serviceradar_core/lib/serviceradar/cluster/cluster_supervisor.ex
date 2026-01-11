defmodule ServiceRadar.ClusterSupervisor do
  @moduledoc """
  Supervisor for cluster infrastructure components.

  Manages libcluster for node discovery and Horde for distributed
  process coordination. Supports dynamic cluster membership updates
  without requiring application restart.

  ## Cluster Strategies

  Configure via `CLUSTER_STRATEGY` environment variable:

  - `kubernetes` - Kubernetes DNS-based discovery (production)
  - `dns` - DNSPoll strategy for bare metal with service discovery
  - `epmd` - EPMD strategy for development and static bare metal
  - `gossip` - Gossip protocol for large-scale deployments (future)

  ## Environment Variables

  - `CLUSTER_ENABLED` - Enable cluster formation (default: false)
  - `CLUSTER_STRATEGY` - Discovery strategy (default: epmd)
  - `CLUSTER_HOSTS` - Comma-separated host list for EPMD strategy
  - `NAMESPACE` - Kubernetes namespace for k8s strategy
  - `KUBERNETES_SELECTOR` - Pod selector for k8s strategy
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      if topologies != [] do
        Logger.info(
          "Starting cluster supervisor with topologies: #{inspect(Keyword.keys(topologies))}"
        )

        [
          {Cluster.Supervisor, [topologies, [name: ServiceRadar.ClusterSupervisor.Cluster]]}
        ]
      else
        Logger.info("Cluster disabled - no topologies configured")
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Dynamically update cluster topology at runtime.

  Useful for adding new gateways without restarting the cluster.
  This stops the existing topology supervisor and restarts with new config.

  ## Examples

      iex> ServiceRadar.ClusterSupervisor.update_topology(:serviceradar, [
      ...>   strategy: Cluster.Strategy.Epmd,
      ...>   config: [hosts: [:"gateway1@192.168.1.20", :"gateway2@192.168.1.21"]]
      ...> ])
      {:ok, pid}
  """
  @spec update_topology(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def update_topology(topology_name, new_config) do
    Logger.info("Updating cluster topology: #{topology_name}")

    # Stop existing topology supervisor if running
    case Supervisor.terminate_child(__MODULE__, ServiceRadar.ClusterSupervisor.Cluster) do
      :ok -> Supervisor.delete_child(__MODULE__, ServiceRadar.ClusterSupervisor.Cluster)
      {:error, :not_found} -> :ok
    end

    # Start with new config
    topologies = [{topology_name, new_config}]

    Supervisor.start_child(
      __MODULE__,
      {Cluster.Supervisor, [topologies, [name: ServiceRadar.ClusterSupervisor.Cluster]]}
    )
  end

  @doc """
  Get the current cluster topology configuration.
  """
  @spec current_topologies() :: keyword()
  def current_topologies do
    Application.get_env(:libcluster, :topologies, [])
  end

  @doc """
  Check if cluster is enabled and running.
  """
  @spec cluster_enabled?() :: boolean()
  def cluster_enabled? do
    case Process.whereis(ServiceRadar.ClusterSupervisor.Cluster) do
      nil -> false
      _pid -> true
    end
  end

  @doc """
  Get list of connected nodes in the cluster.
  """
  @spec connected_nodes() :: [node()]
  def connected_nodes do
    Node.list()
  end

  @doc """
  Get cluster status information.
  """
  @spec cluster_status() :: map()
  def cluster_status do
    %{
      enabled: cluster_enabled?(),
      self: Node.self(),
      connected_nodes: connected_nodes(),
      node_count: length(connected_nodes()) + 1,
      topologies: Keyword.keys(current_topologies())
    }
  end
end
