defmodule ServiceRadar.Telemetry do
  @moduledoc """
  Shared telemetry definitions for ServiceRadar distributed cluster.

  This module defines telemetry events, metrics, and helpers used across
  all ServiceRadar components (core, gateway, agent).

  ## Event Naming Convention

  All ServiceRadar telemetry events follow the pattern:
  ```
  [:serviceradar, <component>, <action>, <status>]
  ```

  Where:
  - `component`: cluster, gateway, agent, registry, etc.
  - `action`: connect, disconnect, register, heartbeat, etc.
  - `status`: start, stop, exception (optional)

  ## Measurements

  Common measurements include:
  - `duration`: Time in native units (use `System.convert_time_unit/3`)
  - `count`: Integer count
  - `queue_length`: Number of items in queue

  ## Metadata

  Common metadata fields:
  - `node`: The node name
  - `partition_id`: The partition identifier
  - `gateway_id`: The gateway identifier
  - `agent_id`: The agent identifier
  - `spiffe_id`: The SPIFFE identity

  ## Usage

  ```elixir
  # Emit a telemetry event
  ServiceRadar.Telemetry.emit_cluster_event(:node_connected, %{node: node()}, %{latency_ms: 5})

  # Attach handlers
  ServiceRadar.Telemetry.attach_default_handlers()
  ```
  """

  require Logger

  # Event prefixes
  @prefix [:serviceradar]

  # Standard event names
  @cluster_events [
    :node_connected,
    :node_disconnected,
    :cluster_formed,
    :cluster_partitioned,
    :topology_changed
  ]

  @gateway_events [
    :registered,
    :unregistered,
    :heartbeat,
    :heartbeat_missed,
    :task_assigned,
    :task_completed
  ]

  @agent_events [
    :connected,
    :disconnected,
    :check_started,
    :check_completed,
    :check_failed
  ]

  @registry_events [
    :process_registered,
    :process_unregistered,
    :lookup_hit,
    :lookup_miss
  ]

  @camera_relay_session_events [
    :opened,
    :closing,
    :closed,
    :failed,
    :viewer_count_changed
  ]

  @camera_relay_analysis_events [
    :branch_opened,
    :branch_closed,
    :branch_count_changed,
    :sample_emitted,
    :sample_dropped,
    :limit_rejected,
    :worker_selected,
    :worker_selection_failed,
    :worker_probe_succeeded,
    :worker_probe_failed,
    :worker_health_changed,
    :worker_flapping_changed,
    :worker_alert_changed,
    :worker_failover_succeeded,
    :worker_failover_failed,
    :dispatch_succeeded,
    :dispatch_failed,
    :dispatch_timed_out,
    :dispatch_dropped
  ]

  # ============================================================================
  # Event Emission
  # ============================================================================

  @doc """
  Emits a cluster-related telemetry event.

  ## Examples

      ServiceRadar.Telemetry.emit_cluster_event(:node_connected, %{node: :"gateway@10.0.0.1"}, %{})
  """
  @spec emit_cluster_event(atom(), map(), map()) :: :ok
  def emit_cluster_event(event, metadata \\ %{}, measurements \\ %{}) when event in @cluster_events do
    emit(@prefix ++ [:cluster, event], measurements, enrich_metadata(metadata))
  end

  @doc """
  Emits a gateway-related telemetry event.
  """
  @spec emit_gateway_event(atom(), map(), map()) :: :ok
  def emit_gateway_event(event, metadata \\ %{}, measurements \\ %{}) when event in @gateway_events do
    emit(@prefix ++ [:gateway, event], measurements, enrich_metadata(metadata))
  end

  @doc """
  Emits an agent-related telemetry event.
  """
  @spec emit_agent_event(atom(), map(), map()) :: :ok
  def emit_agent_event(event, metadata \\ %{}, measurements \\ %{}) when event in @agent_events do
    emit(@prefix ++ [:agent, event], measurements, enrich_metadata(metadata))
  end

  @doc """
  Emits a registry-related telemetry event.
  """
  @spec emit_registry_event(atom(), map(), map()) :: :ok
  def emit_registry_event(event, metadata \\ %{}, measurements \\ %{}) when event in @registry_events do
    emit(@prefix ++ [:registry, event], measurements, enrich_metadata(metadata))
  end

  @doc """
  Emits a camera relay session lifecycle event.
  """
  @spec emit_camera_relay_session_event(atom(), map(), map()) :: :ok
  def emit_camera_relay_session_event(event, metadata \\ %{}, measurements \\ %{})
      when event in @camera_relay_session_events do
    emit(@prefix ++ [:camera_relay, :session, event], measurements, enrich_metadata(metadata))
  end

  @doc """
  Emits a camera relay analysis branch or sample event.
  """
  @spec emit_camera_relay_analysis_event(atom(), map(), map()) :: :ok
  def emit_camera_relay_analysis_event(event, metadata \\ %{}, measurements \\ %{})
      when event in @camera_relay_analysis_events do
    emit(@prefix ++ [:camera_relay, :analysis, event], measurements, enrich_metadata(metadata))
  end

  @doc """
  Executes a function and emits start/stop/exception telemetry events.

  Returns the result of the function.

  ## Examples

      ServiceRadar.Telemetry.span([:serviceradar, :gateway, :check], %{target: "192.168.1.1"}, fn ->
        # perform check
        {:ok, result}
      end)
  """
  @spec span(list(atom()), map(), (-> result)) :: result when result: term()
  def span(event_name, metadata, fun) when is_function(fun, 0) do
    :telemetry.span(event_name, enrich_metadata(metadata), fn ->
      result = fun.()
      {result, %{}}
    end)
  end

  # ============================================================================
  # Metrics Definitions
  # ============================================================================

  @doc """
  Returns the list of telemetry metrics definitions for use with TelemetryMetrics.

  These can be used with Phoenix.LiveDashboard or other metrics reporters.
  """
  @spec metrics() :: list()
  def metrics do
    import Telemetry.Metrics

    [
      # Cluster metrics
      counter("serviceradar.cluster.node_connected.count",
        tags: [:node],
        description: "Number of nodes that connected to the cluster"
      ),
      counter("serviceradar.cluster.node_disconnected.count",
        tags: [:node],
        description: "Number of nodes that disconnected from the cluster"
      ),
      last_value("serviceradar.cluster.nodes.count",
        description: "Current number of nodes in the cluster"
      ),

      # Gateway metrics
      counter("serviceradar.gateway.registered.count",
        tags: [:partition_id, :gateway_id],
        description: "Number of gateways registered"
      ),
      counter("serviceradar.gateway.heartbeat.count",
        tags: [:partition_id, :gateway_id],
        description: "Number of heartbeats received from gateways"
      ),
      counter("serviceradar.gateway.heartbeat_missed.count",
        tags: [:partition_id, :gateway_id],
        description: "Number of missed heartbeats"
      ),
      last_value("serviceradar.gateway.active.count",
        tags: [:partition_id],
        description: "Current number of active gateways"
      ),
      distribution("serviceradar.gateway.task.duration",
        tags: [:partition_id, :task_type],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]],
        description: "Duration of gateway tasks"
      ),

      # Agent metrics
      counter("serviceradar.agent.connected.count",
        tags: [:partition_id, :gateway_id],
        description: "Number of agents connected"
      ),
      counter("serviceradar.agent.disconnected.count",
        tags: [:partition_id, :gateway_id],
        description: "Number of agents disconnected"
      ),
      last_value("serviceradar.agent.active.count",
        tags: [:partition_id, :gateway_id],
        description: "Current number of active agents"
      ),
      distribution("serviceradar.agent.check.duration",
        tags: [:check_type],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]],
        description: "Duration of agent checks"
      ),
      counter("serviceradar.agent.check.success.count",
        tags: [:check_type],
        description: "Number of successful checks"
      ),
      counter("serviceradar.agent.check.failure.count",
        tags: [:check_type],
        description: "Number of failed checks"
      ),

      # Registry metrics
      counter("serviceradar.registry.lookup.count",
        tags: [:registry, :result],
        description: "Number of registry lookups"
      ),
      distribution("serviceradar.registry.lookup.duration",
        tags: [:registry],
        unit: {:native, :microsecond},
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000]],
        description: "Duration of registry lookups"
      ),
      last_value("serviceradar.registry.processes.count",
        tags: [:registry],
        description: "Number of processes in registry"
      ),

      # SPIFFE/TLS metrics
      counter("serviceradar.spiffe.verification.success.count",
        description: "Number of successful SPIFFE ID verifications"
      ),
      counter("serviceradar.spiffe.verification.failure.count",
        tags: [:reason],
        description: "Number of failed SPIFFE ID verifications"
      ),
      counter("serviceradar.spiffe.certificate.rotation.count",
        description: "Number of certificate rotations"
      ),
      last_value("serviceradar.spiffe.cert.expires_in.seconds",
        event_name: [:serviceradar, :spiffe, :cert_expiry],
        measurement: :seconds_remaining,
        tags: [:status],
        description: "Seconds remaining before SPIFFE certificate expiration"
      ),
      last_value("serviceradar.spiffe.cert.expires_in.days",
        event_name: [:serviceradar, :spiffe, :cert_expiry],
        measurement: :days_remaining,
        tags: [:status],
        description: "Days remaining before SPIFFE certificate expiration"
      )
    ] ++ camera_relay_metrics()
  end

  @doc """
  Returns the camera relay metric definitions.

  This subset is exposed separately so other apps, such as `web-ng`, can export
  relay metrics without duplicating the rest of the shared cluster metric set.
  """
  @spec camera_relay_metrics() :: list()
  def camera_relay_metrics do
    import Telemetry.Metrics

    [
      counter("serviceradar.camera_relay.session.opened.count",
        tags: [:relay_boundary, :gateway_id],
        description: "Number of camera relay sessions opened"
      ),
      counter("serviceradar.camera_relay.session.closing.count",
        tags: [:relay_boundary, :termination_kind],
        description: "Number of camera relay sessions entering closing state"
      ),
      counter("serviceradar.camera_relay.session.closed.count",
        tags: [:relay_boundary, :termination_kind],
        description: "Number of camera relay sessions closed"
      ),
      counter("serviceradar.camera_relay.session.failed.count",
        tags: [:relay_boundary, :stage],
        description: "Number of camera relay session failures"
      ),
      last_value("serviceradar.camera_relay.session.viewer_count",
        event_name: [:serviceradar, :camera_relay, :session, :viewer_count_changed],
        measurement: :viewer_count,
        tags: [:relay_boundary, :relay_session_id],
        description: "Latest viewer count for a camera relay session"
      ),
      counter("serviceradar.camera_relay.analysis.branch_opened.count",
        tags: [:relay_boundary],
        description: "Number of relay-scoped analysis branches opened"
      ),
      counter("serviceradar.camera_relay.analysis.branch_closed.count",
        tags: [:relay_boundary, :reason],
        description: "Number of relay-scoped analysis branches closed"
      ),
      counter("serviceradar.camera_relay.analysis.sample_emitted.count",
        tags: [:relay_boundary],
        description: "Number of analysis samples emitted to workers"
      ),
      counter("serviceradar.camera_relay.analysis.sample_dropped.count",
        tags: [:relay_boundary, :reason],
        description: "Number of analysis samples dropped by guardrails"
      ),
      counter("serviceradar.camera_relay.analysis.limit_rejected.count",
        tags: [:relay_boundary, :limit],
        description: "Number of analysis branch requests rejected by limits"
      ),
      counter("serviceradar.camera_relay.analysis.worker_selected.count",
        tags: [:relay_boundary, :selection_mode, :worker_id],
        description: "Number of successful analysis worker selections"
      ),
      counter("serviceradar.camera_relay.analysis.worker_selection_failed.count",
        tags: [:relay_boundary, :reason],
        description: "Number of failed analysis worker selections"
      ),
      counter("serviceradar.camera_relay.analysis.worker_probe_succeeded.count",
        tags: [:relay_boundary, :worker_id, :adapter],
        description: "Number of successful camera analysis worker health probes"
      ),
      counter("serviceradar.camera_relay.analysis.worker_probe_failed.count",
        tags: [:relay_boundary, :worker_id, :adapter, :reason],
        description: "Number of failed camera analysis worker health probes"
      ),
      counter("serviceradar.camera_relay.analysis.worker_health_changed.count",
        tags: [:relay_boundary, :worker_id, :health_status],
        description: "Number of camera analysis worker health state changes"
      ),
      counter("serviceradar.camera_relay.analysis.worker_flapping_changed.count",
        tags: [:relay_boundary, :worker_id, :flapping_state],
        description: "Number of camera analysis worker flapping state changes"
      ),
      counter("serviceradar.camera_relay.analysis.worker_alert_changed.count",
        tags: [:relay_boundary, :worker_id, :alert_state],
        description: "Number of camera analysis worker alert state changes"
      ),
      counter("serviceradar.camera_relay.analysis.worker_failover_succeeded.count",
        tags: [:relay_boundary, :worker_id, :replacement_worker_id],
        description: "Number of successful camera analysis worker failovers"
      ),
      counter("serviceradar.camera_relay.analysis.worker_failover_failed.count",
        tags: [:relay_boundary, :worker_id, :reason],
        description: "Number of failed camera analysis worker failovers"
      ),
      counter("serviceradar.camera_relay.analysis.dispatch_succeeded.count",
        tags: [:relay_boundary, :worker_id],
        description: "Number of successful analysis worker dispatches"
      ),
      counter("serviceradar.camera_relay.analysis.dispatch_failed.count",
        tags: [:relay_boundary, :worker_id, :reason],
        description: "Number of failed analysis worker dispatches"
      ),
      counter("serviceradar.camera_relay.analysis.dispatch_timed_out.count",
        tags: [:relay_boundary, :worker_id],
        description: "Number of timed out analysis worker dispatches"
      ),
      counter("serviceradar.camera_relay.analysis.dispatch_dropped.count",
        tags: [:relay_boundary, :worker_id, :reason],
        description: "Number of dropped analysis worker dispatches"
      ),
      last_value("serviceradar.camera_relay.analysis.branch_count",
        event_name: [:serviceradar, :camera_relay, :analysis, :branch_count_changed],
        measurement: :branch_count,
        tags: [:relay_boundary, :relay_session_id],
        description: "Latest active analysis branch count for a relay session"
      )
    ]
  end

  @doc """
  Returns a list of periodic measurements to be used with TelemetryPoller.
  """
  @spec periodic_measurements() :: list()
  def periodic_measurements do
    [
      {__MODULE__, :measure_cluster_size, []},
      {__MODULE__, :measure_registry_sizes, []},
      {__MODULE__, :measure_active_gateways, []},
      {__MODULE__, :measure_active_agents, []}
    ]
  end

  # ============================================================================
  # Periodic Measurements
  # ============================================================================

  @doc false
  def measure_cluster_size do
    nodes = [node() | Node.list()]

    emit(
      @prefix ++ [:cluster, :nodes],
      %{count: length(nodes)},
      %{nodes: nodes}
    )
  end

  @doc false
  def measure_registry_sizes do
    # Measure GatewayRegistry size
    if registry_available?(ServiceRadar.GatewayRegistry) do
      count = count_registry_processes(ServiceRadar.GatewayRegistry)
      emit(@prefix ++ [:registry, :processes], %{count: count}, %{registry: :gateway})
    end

    # Measure AgentRegistry size
    if registry_available?(ServiceRadar.AgentRegistry) do
      count = count_registry_processes(ServiceRadar.AgentRegistry)
      emit(@prefix ++ [:registry, :processes], %{count: count}, %{registry: :agent})
    end
  end

  @doc false
  def measure_active_gateways do
    if registry_available?(ServiceRadar.GatewayRegistry) do
      gateways = list_registry_processes(ServiceRadar.GatewayRegistry)

      gateways
      |> Enum.group_by(fn {{partition_id, _}, _} -> partition_id end)
      |> Enum.each(fn {partition_id, partition_gateways} ->
        emit(
          @prefix ++ [:gateway, :active],
          %{count: length(partition_gateways)},
          %{partition_id: partition_id}
        )
      end)
    end
  end

  @doc false
  def measure_active_agents do
    if registry_available?(ServiceRadar.AgentRegistry) do
      agents = list_registry_processes(ServiceRadar.AgentRegistry)

      agents
      |> Enum.group_by(fn {{partition_id, gateway_id, _}, _} -> {partition_id, gateway_id} end)
      |> Enum.each(fn {{partition_id, gateway_id}, partition_agents} ->
        emit(
          @prefix ++ [:agent, :active],
          %{count: length(partition_agents)},
          %{partition_id: partition_id, gateway_id: gateway_id}
        )
      end)
    end
  end

  # ============================================================================
  # Handler Attachment
  # ============================================================================

  @doc """
  Attaches default telemetry handlers for logging.

  This is useful for development and debugging.
  """
  @spec attach_default_handlers() :: :ok
  def attach_default_handlers do
    events = [
      @prefix ++ [:cluster, :node_connected],
      @prefix ++ [:cluster, :node_disconnected],
      @prefix ++ [:gateway, :registered],
      @prefix ++ [:gateway, :unregistered],
      @prefix ++ [:gateway, :heartbeat_missed],
      @prefix ++ [:agent, :connected],
      @prefix ++ [:agent, :disconnected],
      @prefix ++ [:camera_relay, :session, :failed],
      @prefix ++ [:camera_relay, :session, :closed]
    ]

    :telemetry.attach_many(
      "serviceradar-default-handler",
      events,
      &handle_event/4,
      nil
    )

    :ok
  end

  @doc """
  Detaches the default telemetry handlers.
  """
  @spec detach_default_handlers() :: :ok | {:error, :not_found}
  def detach_default_handlers do
    :telemetry.detach("serviceradar-default-handler")
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp emit(event_name, measurements, metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  defp enrich_metadata(metadata) do
    metadata
    |> Map.put_new(:node, node())
    |> Map.put_new(:timestamp, System.system_time(:millisecond))
  end

  defp handle_event(event, measurements, metadata, _config) do
    event_name = Enum.join(event, ".")

    Logger.debug(
      "Telemetry: #{event_name}",
      measurements: measurements,
      metadata: Map.delete(metadata, :timestamp)
    )
  end

  defp registry_available?(registry) do
    case Process.whereis(registry) do
      nil -> false
      _pid -> true
    end
  end

  defp count_registry_processes(registry) do
    registry
    |> Horde.Registry.select([{{:"$1", :"$2", :"$3"}, [], [true]}])
    |> length()
  rescue
    _ -> 0
  end

  defp list_registry_processes(registry) do
    Horde.Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    _ -> []
  end
end
