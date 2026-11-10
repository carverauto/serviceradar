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
  - StarRocks node memory (`ServiceRadar.Analytics.StarRocks.NodeMemory.health/0`):
    each warehouse node's process limit, the reserve it leaves under the
    memory the node detects, and the memory settings core holds it to. Its
    `status` is `:warning` when a reserve is below
    `NodeMemory.reserve_warning_bytes/0` or a setting could not be applied.
    That does not degrade the cluster status: the warehouse still answers.
  - Edge pipeline status (registry epochs, transition blockers, issuer key,
    awaiting-roll-forward counts)
  - Last check timestamp
  """

  use GenServer

  alias ServiceRadar.Analytics.StarRocks.NodeMemory
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.ContractRegistryTransition
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.PipelineStats

  require Logger

  @health_check_interval to_timeout(second: 30)
  @event_writer_rpc_timeout to_timeout(second: 2)
  # The dead-letter reason EventWriter files unprojectable bulk-stream records
  # under while they await roll-forward (Decision 5); 1.4 produces it.
  @awaiting_roll_forward_reason "awaiting_roll_forward"

  defstruct [
    :last_check,
    :node_count,
    :connected_nodes,
    :gateway_count,
    :agent_count,
    :event_writer,
    :starrocks_memory,
    :edge_pipeline,
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

    # Public API

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
      },
      edge_pipeline: health.edge_pipeline
    }

    base_response
    |> put_event_writer(health.event_writer)
    |> Map.put(:starrocks_memory, health.starrocks_memory)
  end

  defp put_event_writer(response, nil), do: response

  defp put_event_writer(response, event_writer),
    do: Map.put(response, :event_writer, format_event_writer_status(event_writer))

  # Private functions

  defp perform_health_check do
    connected_nodes = Node.list()
    node_count = length(connected_nodes) + 1

    gateway_count = safe_count(ServiceRadar.GatewayRegistry)
    agent_count = safe_count(ServiceRadar.AgentRegistry)
    event_writer = get_event_writer_status()
    edge_pipeline = get_edge_pipeline_status()

    status = determine_status(connected_nodes, event_writer)

    %__MODULE__{
      last_check: DateTime.utc_now(),
      node_count: node_count,
      connected_nodes: connected_nodes,
      gateway_count: gateway_count,
      agent_count: agent_count,
      event_writer: event_writer,
      starrocks_memory: NodeMemory.health(),
      edge_pipeline: edge_pipeline,
      status: status
    }
  end

  defp safe_count(registry) do
    # GatewayRegistry and AgentRegistry are modules that delegate to ProcessRegistry
    # They don't have a GenServer process, so we call count() directly
    registry.count()
  rescue
    _ -> 0
  end

  defp determine_status(_connected_nodes, event_writer) do
    # Check EventWriter health if enabled
    if not event_writer.enabled or event_writer.healthy do
      # For now, always healthy if we can check
      # Future: detect partitions by comparing expected vs actual nodes
      :healthy
    else
      :degraded
    end
  end

  defp get_event_writer_status do
    alias ServiceRadar.EventWriter.Health, as: EventWriterHealth

    try do
      status = EventWriterHealth.status()
      # Every core replica runs EventWriter workers, so the deployment is only
      # healthy when each replica's workers are.
      cluster = EventWriterHealth.cluster_status(@event_writer_rpc_timeout)

      %{
        enabled: status.enabled,
        running: status.running,
        healthy: status.healthy and cluster.healthy,
        reason: event_writer_reason(status, cluster),
        pipelines: status.pipelines,
        nodes: node_summaries(cluster.nodes)
      }
    rescue
      _ ->
        %{
          enabled: true,
          running: false,
          healthy: false,
          reason: "health_check_failed",
          pipelines: %{},
          nodes: %{}
        }
    end
  end

  # The durable edge-record pipeline's status for the health response: the
  # registry epochs this node sees, the transition's blockers cluster-wide,
  # whether the issuer key is present, and the awaiting-roll-forward counts
  # summed over every connected node. Never raises; a failed read leaves an explicit error, the way the
  # EventWriter section degrades instead of crashing the check.
  defp get_edge_pipeline_status do
    edge_pipeline_status(
      pipeline_snapshots(),
      ContractRegistryTransition.status(),
      ContractRegistry.view(),
      IssuerKey.configured()
    )
  rescue
    reason -> %{error: "edge_pipeline_status_failed: #{inspect(reason)}"}
  end

  @doc """
  Maps the pipeline inputs to the health response's `edge_pipeline` section.
  `snapshots` pairs each connected node with its `:erpc` answer to
  `PipelineStats.snapshot/0` (gateways count spool refusals, EventWriter
  cores count dead letters), `transition` is this node's
  `ContractRegistryTransition.status/0`, `epochs` the verified
  `ContractRegistry.view/0` (a refused row is named in `epochs.error`, never
  listed as active, candidate or draining), and `key` the
  `IssuerKey.configured/0` result.

  `awaiting_roll_forward.overflow` is nil, unknown: no overflow counter
  exists yet, and an unknown loss must not read as zero.
  """
  @spec edge_pipeline_status(
          [{node(), term()}],
          map() | nil,
          {:ok, ContractRegistry.view()} | {:error, term()},
          {:ok, map()} | {:error, term()}
        ) :: map()
  def edge_pipeline_status(snapshots, transition_status, epochs_result, key_result) do
    %{
      node: to_string(node()),
      issuer_key_present: match?({:ok, _}, key_result),
      epochs: pipeline_epochs(epochs_result),
      transition: transition_summary(transition_status),
      awaiting_roll_forward: roll_forward_counts(snapshots)
    }
  end

  defp pipeline_snapshots do
    nodes = [node() | Node.list()]
    Enum.zip(nodes, :erpc.multicall(nodes, PipelineStats, :snapshot, [], @event_writer_rpc_timeout))
  end

  defp pipeline_epochs({:ok, %{epochs: epochs, invalid: invalid}}) do
    by_state = Enum.group_by(epochs, & &1.state)

    %{
      active: epoch_number(by_state, :active),
      candidate: epoch_number(by_state, :candidate),
      draining: by_state |> Map.get(:draining, []) |> Enum.map(& &1.epoch) |> Enum.sort(),
      error: refused_epochs(invalid)
    }
  end

  defp refused_epochs([]), do: nil

  defp refused_epochs(invalid) do
    Enum.map_join(invalid, "; ", fn %{epoch: epoch, state: state, reason: reason} ->
      "#{state} epoch #{epoch} refused: #{reason}"
    end)
  end

  defp pipeline_epochs({:error, reason}),
    do: %{active: nil, candidate: nil, draining: [], error: inspect(reason)}

  defp epoch_number(by_state, state) do
    case Map.get(by_state, state, []) do
      [%{epoch: epoch} | _] -> epoch
      [] -> nil
    end
  end

  defp transition_summary(%{outcome: :no_candidate, evaluated_at: evaluated_at}),
    do: %{outcome: "no_candidate", evaluated_at: evaluated_at, epoch: nil, waiting_on: []}

  defp transition_summary(%{outcome: {:activated, epoch, _previous}, evaluated_at: evaluated_at}),
    do: %{outcome: "activated", evaluated_at: evaluated_at, epoch: epoch, waiting_on: []}

  defp transition_summary(%{outcome: {:waiting, epoch, blockers}, evaluated_at: evaluated_at}),
    do: %{
      outcome: "waiting",
      evaluated_at: evaluated_at,
      epoch: epoch,
      waiting_on: Enum.map(blockers, &ContractRegistryTransition.describe/1)
    }

  defp transition_summary(%{outcome: {:abandoned, epoch}, evaluated_at: evaluated_at}),
    do: %{outcome: "abandoned", evaluated_at: evaluated_at, epoch: epoch, waiting_on: []}

  defp transition_summary(%{outcome: {:error, reason}, evaluated_at: evaluated_at}),
    do: %{
      outcome: "error",
      evaluated_at: evaluated_at,
      epoch: nil,
      waiting_on: [],
      detail: inspect(reason)
    }

  defp transition_summary(_status),
    do: %{outcome: "unknown", evaluated_at: nil, epoch: nil, waiting_on: []}

  # A node that runs no stats table (or predates it) counts nothing; a node
  # that did not answer leaves the sums incomplete, which `error` says.
  defp roll_forward_counts(results) do
    {snapshots, unreachable} =
      Enum.reduce(results, {[], []}, fn
        {_node, {:ok, {:ok, snapshot}}}, {ok, bad} -> {[snapshot | ok], bad}
        {_node, {:ok, {:error, :unavailable}}}, acc -> acc
        {_node, {:error, {:exception, :undef, [{PipelineStats, _, _, _} | _]}}}, acc -> acc
        {node, _error}, {ok, bad} -> {ok, [to_string(node) | bad]}
      end)

    %{
      withheld_by_contract: withheld_by_contract(snapshots),
      dead_lettered_by_contract: dead_lettered_by_contract(snapshots),
      overflow: nil,
      nodes: snapshots |> Enum.map(& &1.node) |> Enum.sort(),
      error: snapshot_error(snapshots, Enum.sort(unreachable))
    }
  end

  defp withheld_by_contract(snapshots) do
    snapshots
    |> Enum.flat_map(& &1.contracts)
    |> Enum.group_by(& &1.contract, &Map.get(&1, :gateway_withheld, 0))
    |> Enum.map(fn {contract, counts} -> %{contract: contract, count: Enum.sum(counts)} end)
    |> Enum.filter(&(&1.count > 0))
    |> Enum.sort_by(& &1.contract)
  end

  defp dead_lettered_by_contract(snapshots) do
    snapshots
    |> Enum.flat_map(&Map.get(&1, :dead_letter_reasons, []))
    |> Enum.filter(&(&1.reason == @awaiting_roll_forward_reason))
    |> Enum.group_by(& &1.contract, & &1.count)
    |> Enum.map(fn {contract, counts} ->
      %{contract: contract, reason: @awaiting_roll_forward_reason, count: Enum.sum(counts)}
    end)
    |> Enum.sort_by(& &1.contract)
  end

  defp snapshot_error([], []), do: "no node reported pipeline stats"
  defp snapshot_error(_snapshots, []), do: nil

  defp snapshot_error(_snapshots, unreachable),
    do: "pipeline stats unavailable from: #{Enum.join(unreachable, ", ")}"

  defp event_writer_reason(%{reason: :ok}, %{healthy: false, nodes: nodes}) do
    nodes
    |> Enum.flat_map(fn
      {_node, %{healthy: false, reason: reason}} -> [inspect(reason)]
      _node_status -> []
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp event_writer_reason(%{reason: reason}, _cluster), do: inspect(reason)

  defp node_summaries(nodes) do
    Map.new(nodes, fn {node, status} ->
      {node,
       %{
         running: status.running,
         healthy: status.healthy,
         reason: inspect(status.reason)
       }}
    end)
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
        event_writer_running: if(event_writer_running, do: 1, else: 0),
        event_writer_healthy: if(state.event_writer && state.event_writer.healthy, do: 1, else: 0)
      },
      %{status: state.status}
    )
  end

  defp format_event_writer_status(event_writer) do
    %{
      enabled: event_writer.enabled,
      running: event_writer.running,
      healthy: event_writer.healthy,
      reason: event_writer.reason,
      pipelines: event_writer.pipelines,
      nodes: Map.get(event_writer, :nodes, %{})
    }
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:serviceradar, :cluster, event],
      %{count: 1},
      metadata
    )
  end

  # Sync Horde registry members with current cluster nodes
  # ProcessRegistry uses members: :auto and syncs automatically
  defp sync_horde_members do
    # With singleton ProcessRegistry architecture, the Horde registry
    # uses members: :auto configuration which handles sync automatically
    # No manual sync is needed
    all_nodes = [Node.self() | Node.list()]
    Logger.debug("Cluster has #{length(all_nodes)} nodes - ProcessRegistry syncs automatically")
  end
end
