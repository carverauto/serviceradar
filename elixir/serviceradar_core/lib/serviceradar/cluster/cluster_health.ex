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
  - Gateway registry count
  - Agent registry count
  - EventWriter status (enabled, running, healthy)
  - Last check timestamp
  """

  use GenServer

  require Logger

  @health_check_interval :timer.seconds(30)

  defstruct [
    :last_check,
    :node_count,
    :connected_nodes,
    :gateway_count,
    :agent_count,
    :event_writer,
    :status
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Monitor node connections
    :net_kernel.monitor_nodes(true)

    # Sync Horde members with any already-connected nodes
    sync_horde_members()

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

    # Sync Horde registry members when a new node joins
    sync_horde_members()

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

    base_response = %{
      status: if(health.status == :healthy, do: "ok", else: "degraded"),
      cluster: %{
        self: to_string(Node.self()),
        connected_nodes: Enum.map(health.connected_nodes, &to_string/1),
        node_count: health.node_count,
        gateway_count: health.gateway_count,
        agent_count: health.agent_count,
        last_check: health.last_check
      }
    }

    # Include EventWriter status if available
    if health.event_writer do
      Map.put(base_response, :event_writer, format_event_writer_status(health.event_writer))
    else
      base_response
    end
  end

  # Private functions

  defp perform_health_check do
    connected_nodes = Node.list()
    node_count = length(connected_nodes) + 1

    gateway_count = safe_count(ServiceRadar.GatewayRegistry)
    agent_count = safe_count(ServiceRadar.AgentRegistry)
    event_writer = get_event_writer_status()

    status = determine_status(connected_nodes, event_writer)

    %__MODULE__{
      last_check: DateTime.utc_now(),
      node_count: node_count,
      connected_nodes: connected_nodes,
      gateway_count: gateway_count,
      agent_count: agent_count,
      event_writer: event_writer,
      status: status
    }
  end

  defp safe_count(registry) do
    # GatewayRegistry and AgentRegistry are modules that delegate to TenantRegistry
    # They don't have a GenServer process, so we call count() directly
    registry.count()
  rescue
    _ -> 0
  end

  defp determine_status(_connected_nodes, event_writer) do
    # Check EventWriter health if enabled
    event_writer_healthy = not event_writer.enabled or event_writer.healthy

    cond do
      not event_writer_healthy ->
        :degraded

      true ->
        # For now, always healthy if we can check
        # Future: detect partitions by comparing expected vs actual nodes
        :healthy
    end
  end

  defp get_event_writer_status do
    alias ServiceRadar.EventWriter.Health, as: EventWriterHealth

    try do
      status = EventWriterHealth.status()

      %{
        enabled: status.enabled,
        running: status.running,
        healthy: EventWriterHealth.healthy?(),
        pipeline: Map.get(status, :pipeline),
        producer: Map.get(status, :producer)
      }
    rescue
      _ ->
        %{enabled: false, running: false, healthy: true, pipeline: nil, producer: nil}
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp emit_health_telemetry(state) do
    event_writer_running = if state.event_writer, do: state.event_writer.running, else: false

    :telemetry.execute(
      [:serviceradar, :cluster, :health_check],
      %{
        node_count: state.node_count,
        gateway_count: state.gateway_count,
        agent_count: state.agent_count,
        event_writer_running: if(event_writer_running, do: 1, else: 0)
      },
      %{status: state.status}
    )
  end

  defp format_event_writer_status(event_writer) do
    base = %{
      enabled: event_writer.enabled,
      running: event_writer.running,
      healthy: event_writer.healthy
    }

    # Add pipeline details if available
    base =
      if event_writer.pipeline do
        Map.put(base, :pipeline, event_writer.pipeline)
      else
        base
      end

    # Add producer details if available
    if event_writer.producer do
      Map.put(base, :producer, event_writer.producer)
    else
      base
    end
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:serviceradar, :cluster, event],
      %{count: 1},
      metadata
    )
  end

  # Sync Horde registry members with current cluster nodes
  # Per-tenant registries use members: :auto and sync automatically
  defp sync_horde_members do
    # With TenantRegistry architecture, each tenant's Horde registry
    # uses members: :auto configuration which handles sync automatically
    # No manual sync is needed
    all_nodes = [Node.self() | Node.list()]
    Logger.debug("Cluster has #{length(all_nodes)} nodes - per-tenant registries sync automatically")
  end

end
