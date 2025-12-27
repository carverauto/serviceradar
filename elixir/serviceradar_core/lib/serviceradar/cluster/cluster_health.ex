defmodule ServiceRadar.ClusterHealth do
  @moduledoc """
  GenServer for monitoring cluster health and connectivity.

  Tracks connected nodes, detects partitions, and emits telemetry events
  for cluster status changes.

  ## Telemetry Events

  - `[:serviceradar, :cluster, :node_up]` - Node joined the cluster
  - `[:serviceradar, :cluster, :node_down]` - Node left the cluster
  - `[:serviceradar, :cluster, :partition]` - Cluster partition detected
  - `[:serviceradar, :cluster, :health_check]` - Periodic health check

  ## Health Status

  The health status includes:
  - Node count and list
  - Poller registry count
  - Agent registry count
  - Last check timestamp
  """

  use GenServer

  require Logger

  @health_check_interval :timer.seconds(30)

  defstruct [
    :last_check,
    :node_count,
    :connected_nodes,
    :poller_count,
    :agent_count,
    :status
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Monitor node connections
    :net_kernel.monitor_nodes(true)

    state = perform_health_check()
    schedule_health_check()

    Logger.info("Cluster health monitoring started: #{state.node_count} nodes connected")

    {:ok, state}
  end

  @impl true
  def handle_info(:health_check, _state) do
    state = perform_health_check()
    emit_health_telemetry(state)
    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, _state) do
    Logger.info("Node joined cluster: #{node}")

    emit_telemetry(:node_up, %{node: node})

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "cluster:events",
      {:node_up, node}
    )

    new_state = perform_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodedown, node}, _state) do
    Logger.warning("Node left cluster: #{node}")

    emit_telemetry(:node_down, %{node: node})

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "cluster:events",
      {:node_down, node}
    )

    new_state = perform_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_health, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:check_now, _from, _state) do
    state = perform_health_check()
    {:reply, state, state}
  end

  # Public API

  @doc """
  Get current cluster health status.
  """
  @spec get_health() :: map()
  def get_health do
    GenServer.call(__MODULE__, :get_health)
  end

  @doc """
  Force a health check now.
  """
  @spec check_now() :: map()
  def check_now do
    GenServer.call(__MODULE__, :check_now)
  end

  @doc """
  Check if cluster is healthy.

  Returns true if:
  - At least one node is connected (for multi-node clusters)
  - No partition detected
  """
  @spec healthy?() :: boolean()
  def healthy? do
    health = get_health()
    health.status == :healthy
  end

  @doc """
  Get cluster status for health endpoint.
  """
  @spec health_check_response() :: map()
  def health_check_response do
    health = get_health()

    %{
      status: if(health.status == :healthy, do: "ok", else: "degraded"),
      cluster: %{
        self: to_string(Node.self()),
        connected_nodes: Enum.map(health.connected_nodes, &to_string/1),
        node_count: health.node_count,
        poller_count: health.poller_count,
        agent_count: health.agent_count,
        last_check: health.last_check
      }
    }
  end

  # Private functions

  defp perform_health_check do
    connected_nodes = Node.list()
    node_count = length(connected_nodes) + 1

    poller_count = safe_count(ServiceRadar.PollerRegistry)
    agent_count = safe_count(ServiceRadar.AgentRegistry)

    status = determine_status(connected_nodes)

    %__MODULE__{
      last_check: DateTime.utc_now(),
      node_count: node_count,
      connected_nodes: connected_nodes,
      poller_count: poller_count,
      agent_count: agent_count,
      status: status
    }
  end

  defp safe_count(registry) do
    if Process.whereis(registry) do
      registry.count()
    else
      0
    end
  rescue
    _ -> 0
  end

  defp determine_status(_connected_nodes) do
    # For now, always healthy if we can check
    # Future: detect partitions by comparing expected vs actual nodes
    :healthy
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp emit_health_telemetry(state) do
    :telemetry.execute(
      [:serviceradar, :cluster, :health_check],
      %{
        node_count: state.node_count,
        poller_count: state.poller_count,
        agent_count: state.agent_count
      },
      %{status: state.status}
    )
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:serviceradar, :cluster, event],
      %{count: 1},
      metadata
    )
  end
end
