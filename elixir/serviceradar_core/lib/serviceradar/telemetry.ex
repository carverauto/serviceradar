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
    :expired,
    :saturation_denied,
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
  def emit_cluster_event(event, metadata \\ %{}, measurements \\ %{})
      when event in @cluster_events do
    emit(@prefix ++ [:cluster, event], measurements, enrich_metadata(metadata))
  end

  @doc """
  Emits a gateway-related telemetry event.
  """
  @spec emit_gateway_event(atom(), map(), map()) :: :ok
  def emit_gateway_event(event, metadata \\ %{}, measurements \\ %{})
      when event in @gateway_events do
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
  def emit_registry_event(event, metadata \\ %{}, measurements \\ %{})
      when event in @registry_events do
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
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        ],
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
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        ],
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
        reporter_options: [
          buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000]
        ],
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
    ] ++
      endpoint_inventory_metrics() ++
      camera_relay_metrics() ++
      observability_signal_metrics() ++
      event_writer_metrics() ++
      prefix_tag_metrics() ++
      capacity_forecasting_metrics() ++
      stateful_alert_engine_metrics() ++ admission_lane_metrics() ++ notification_metrics()
  end

  @doc "Returns bounded core admission lane depth, latency, and outcome metrics."
  @spec admission_lane_metrics() :: list()
  def admission_lane_metrics do
    import Telemetry.Metrics

    state_event = [:serviceradar, :admission_lane, :state]
    admission_event = [:serviceradar, :admission_lane, :admission]
    execution_event = [:serviceradar, :admission_lane, :execution]
    completion_event = [:serviceradar, :admission_lane, :completion]
    duration_buckets_ms = [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
    event_count_buckets = [1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000]
    payload_buckets_bytes = [256, 1_024, 4_096, 16_384, 65_536, 262_144, 1_048_576, 4_194_304]

    [
      last_value("serviceradar.admission_lane.pending.count",
        event_name: state_event,
        measurement: :pending_count,
        tags: [:lane]
      ),
      last_value("serviceradar.admission_lane.pending.bytes",
        event_name: state_event,
        measurement: :pending_bytes,
        tags: [:lane]
      ),
      last_value("serviceradar.admission_lane.in_flight.count",
        event_name: state_event,
        measurement: :in_flight_count,
        tags: [:lane]
      ),
      last_value("serviceradar.admission_lane.in_flight.bytes",
        event_name: state_event,
        measurement: :in_flight_bytes,
        tags: [:lane]
      ),
      distribution("serviceradar.admission_lane.admission.wait.milliseconds",
        event_name: admission_event,
        measurement: :wait_ms,
        tags: [:lane],
        reporter_options: [buckets: duration_buckets_ms]
      ),
      distribution("serviceradar.admission_lane.execution.duration.milliseconds",
        event_name: execution_event,
        measurement: :duration_ms,
        tags: [:lane, :result],
        reporter_options: [buckets: duration_buckets_ms]
      ),
      distribution("serviceradar.admission_lane.execution.event.count",
        event_name: execution_event,
        measurement: :event_count,
        tags: [:lane, :result],
        reporter_options: [buckets: event_count_buckets]
      ),
      distribution("serviceradar.admission_lane.acknowledgement.milliseconds",
        event_name: completion_event,
        measurement: :acknowledgement_ms,
        tags: [:lane, :result],
        reporter_options: [buckets: duration_buckets_ms]
      ),
      distribution("serviceradar.admission_lane.payload.bytes",
        event_name: completion_event,
        measurement: :payload_bytes,
        tags: [:lane, :result],
        reporter_options: [buckets: payload_buckets_bytes]
      ),
      counter("serviceradar.admission_lane.rejected.count",
        event_name: [:serviceradar, :admission_lane, :rejected],
        measurement: :count,
        tags: [:lane, :reason]
      ),
      counter("serviceradar.admission_lane.timeout.count",
        event_name: [:serviceradar, :admission_lane, :timeout],
        measurement: :count,
        tags: [:lane, :reason]
      ),
      counter("serviceradar.admission_lane.crash.count",
        event_name: [:serviceradar, :admission_lane, :crash],
        measurement: :count,
        tags: [:lane, :reason, :exit_reason]
      )
    ]
  end

  @doc """
  Returns notification dispatch, suppression, escalation, and acknowledgement metrics.

  Defined next to the events in `ServiceRadar.Notifications.Telemetry` so the SLIs
  and their emission sites cannot drift. Without this line the events fire and
  nothing scrapes them.
  """
  def notification_metrics, do: ServiceRadar.Notifications.Telemetry.metrics()

  @doc """
  Returns prefix-tag lookup, swap, rebuild, freshness, and import metrics.

  These definitions are shared by the core-elx Prometheus reporter and any
  other runtime that consumes `metrics/0`.
  """
  @spec prefix_tag_metrics() :: list()
  def prefix_tag_metrics do
    import Telemetry.Metrics

    swap_duration_buckets_us =
      [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 50_000]

    materialize_duration_buckets_us =
      [
        1_000,
        5_000,
        10_000,
        50_000,
        100_000,
        500_000,
        1_000_000,
        5_000_000,
        10_000_000,
        30_000_000,
        60_000_000,
        120_000_000
      ]

    [
      counter("serviceradar.prefix_tags.lookup.count",
        event_name: [:serviceradar, :prefix_tags, :lookup],
        measurement: :count,
        tags: [:outcome],
        description: "Prefix-tag longest-prefix-match lookups"
      ),
      distribution("serviceradar.prefix_tags.lookup.match_depth",
        event_name: [:serviceradar, :prefix_tags, :lookup],
        measurement: :match_depth,
        tags: [:outcome],
        reporter_options: [buckets: [0, 1, 2, 3, 4, 6, 8, 12, 16]],
        description: "Number of prefix matches returned by a lookup"
      ),
      distribution("serviceradar.prefix_tags.swap.duration",
        event_name: [:serviceradar, :prefix_tags, :swap],
        measurement: :duration_us,
        tags: [:source],
        unit: :microsecond,
        reporter_options: [buckets: swap_duration_buckets_us],
        description: "Time to atomically install a source trie"
      ),
      last_value("serviceradar.prefix_tags.swap.ipv4_prefixes",
        event_name: [:serviceradar, :prefix_tags, :swap],
        measurement: :ipv4_prefixes,
        tags: [:source],
        description: "IPv4 prefixes in the newly installed source trie"
      ),
      last_value("serviceradar.prefix_tags.swap.ipv6_prefixes",
        event_name: [:serviceradar, :prefix_tags, :swap],
        measurement: :ipv6_prefixes,
        tags: [:source],
        description: "IPv6 prefixes in the newly installed source trie"
      ),
      last_value("serviceradar.prefix_tags.swap.total_prefixes",
        event_name: [:serviceradar, :prefix_tags, :swap],
        measurement: :total_prefixes,
        tags: [:source],
        description: "Total prefixes in the newly installed source trie"
      ),
      distribution("serviceradar.prefix_tags.rebuild.duration",
        event_name: [:serviceradar, :prefix_tags, :rebuild],
        measurement: :duration_us,
        tags: [:outcome, :scope],
        unit: :microsecond,
        reporter_options: [buckets: materialize_duration_buckets_us],
        description: "Time to rebuild snapshot-backed prefix-tag tries"
      ),
      last_value("serviceradar.prefix_tags.rebuild.row_count",
        event_name: [:serviceradar, :prefix_tags, :rebuild],
        measurement: :row_count,
        tags: [:outcome, :scope],
        description: "Rows processed by the latest prefix-tag rebuild"
      ),
      last_value("serviceradar.prefix_tags.rebuild.ipv4_prefixes",
        event_name: [:serviceradar, :prefix_tags, :rebuild],
        measurement: :ipv4_prefixes,
        tags: [:outcome, :scope],
        description: "Resident IPv4 prefixes after a prefix-tag rebuild"
      ),
      last_value("serviceradar.prefix_tags.rebuild.ipv6_prefixes",
        event_name: [:serviceradar, :prefix_tags, :rebuild],
        measurement: :ipv6_prefixes,
        tags: [:outcome, :scope],
        description: "Resident IPv6 prefixes after a prefix-tag rebuild"
      ),
      last_value("serviceradar.prefix_tags.rebuild.total_prefixes",
        event_name: [:serviceradar, :prefix_tags, :rebuild],
        measurement: :total_prefixes,
        tags: [:outcome, :scope],
        description: "Resident prefixes after a prefix-tag rebuild"
      ),
      last_value("serviceradar.prefix_tags.snapshot_age.age_seconds",
        event_name: [:serviceradar, :prefix_tags, :snapshot_age],
        measurement: :age_seconds,
        tags: [:source],
        unit: :second,
        description: "Age of durable backing data for each prefix-tag source"
      ),
      last_value("serviceradar.prefix_tags.snapshot_freshness.known",
        event_name: [:serviceradar, :prefix_tags, :snapshot_freshness],
        measurement: :known,
        tags: [:source],
        description:
          "Whether durable freshness is known for a prefix-tag source (1 known, 0 unknown)"
      ),
      distribution("serviceradar.prefix_tags.import.duration",
        event_name: [:serviceradar, :prefix_tags, :import],
        measurement: :duration_us,
        tags: [:outcome, :source],
        unit: :microsecond,
        reporter_options: [buckets: materialize_duration_buckets_us],
        description: "Prefix-tag import or external materialization duration"
      ),
      last_value("serviceradar.prefix_tags.import.record_count",
        event_name: [:serviceradar, :prefix_tags, :import],
        measurement: :record_count,
        tags: [:outcome, :source],
        description: "Records installed by the latest prefix-tag import"
      )
    ]
  end

  @doc """
  Returns EventWriter pipeline, producer, and ack health metrics.
  """
  @spec event_writer_metrics() :: list()
  def event_writer_metrics do
    import Telemetry.Metrics

    [
      counter("serviceradar.event_writer.producer.pull_request.count",
        event_name: [:serviceradar, :event_writer, :producer, :pull_request],
        measurement: :messages,
        tags: [:consumer_count],
        description: "JetStream messages requested by EventWriter pull consumers"
      ),
      last_value("serviceradar.event_writer.producer.queue_depth.value",
        event_name: [:serviceradar, :event_writer, :producer, :queue],
        measurement: :queue_depth,
        tags: [:operation, :subject_class],
        description: "EventWriter producer in-process queue depth"
      ),
      last_value("serviceradar.event_writer.producer.pull_inflight.value",
        event_name: [:serviceradar, :event_writer, :producer, :queue],
        measurement: :pull_inflight,
        tags: [:operation, :subject_class],
        description: "EventWriter producer requested-but-not-yet-received pull messages"
      ),
      counter("serviceradar.event_writer.producer.overflow.count",
        event_name: [:serviceradar, :event_writer, :producer, :overflow],
        measurement: :count,
        description: "EventWriter producer messages NAKed because the local buffer was full"
      ),
      counter("serviceradar.event_writer.ack.count",
        event_name: [:serviceradar, :event_writer, :ack],
        measurement: :count,
        tags: [:action, :result, :subject_class],
        description: "EventWriter JetStream ack/nack/term publish attempts"
      ),
      counter("serviceradar.event_writer.dead_letter.count",
        event_name: [:serviceradar, :event_writer, :dead_letter],
        measurement: :count,
        tags: [:subject_class, :stream, :consumer, :reason_class],
        description: "EventWriter messages terminally acked at JetStream max_deliver"
      ),
      distribution("serviceradar.event_writer.ack.duration",
        event_name: [:serviceradar, :event_writer, :ack],
        measurement: :duration,
        tags: [:action, :result, :subject_class],
        unit: {:native, :millisecond},
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]
        ],
        description: "Time from EventWriter message receipt to ack/nack completion"
      ),
      counter("serviceradar.event_writer.batch.count",
        event_name: [:serviceradar, :event_writer, :batch, :completed],
        measurement: :batch_size,
        tags: [:stream, :result, :subject_class],
        description: "EventWriter messages processed by batch result"
      ),
      distribution("serviceradar.event_writer.batch.duration",
        event_name: [:serviceradar, :event_writer, :batch, :completed],
        measurement: :duration,
        tags: [:stream, :result, :subject_class],
        unit: {:native, :millisecond},
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        ],
        description: "EventWriter batch processing duration"
      ),
      last_value("serviceradar.event_writer.consumer.pending_messages.value",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :pending_messages,
        tags: [:stream, :durable, :subject_class],
        description: "JetStream messages pending delivery for an EventWriter durable"
      ),
      last_value("serviceradar.event_writer.consumer.ack_pending_messages.value",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :ack_pending_messages,
        tags: [:stream, :durable, :subject_class],
        description: "JetStream messages delivered but not yet acked by an EventWriter durable"
      ),
      last_value("serviceradar.event_writer.consumer.redelivered_messages.value",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :redelivered_messages,
        tags: [:stream, :durable, :subject_class],
        description: "JetStream messages currently marked redelivered for an EventWriter durable"
      ),
      last_value("serviceradar.event_writer.consumer.lag_messages.value",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :lag_messages,
        tags: [:stream, :durable, :subject_class],
        description:
          "EventWriter durable lag: pending plus delivered-but-unacked JetStream messages"
      ),
      last_value("serviceradar.event_writer.consumer.retention_risk.level",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :retention_risk_level,
        tags: [:stream, :durable, :subject_class],
        description:
          "EventWriter flow retention risk: 0 clear, 1 warning, 2 critical from backlog plus stream byte/age utilization"
      ),
      last_value("serviceradar.event_writer.consumer.stream_info_available.value",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :stream_info_available,
        tags: [:stream, :durable, :subject_class],
        description: "Whether authoritative JetStream stream retention INFO was available"
      ),
      last_value("serviceradar.event_writer.consumer.stream_bytes.value",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :stream_bytes,
        tags: [:stream, :durable, :subject_class],
        description: "Current bytes retained by the JetStream stream"
      ),
      last_value("serviceradar.event_writer.consumer.stream_max_bytes.value",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :stream_max_bytes,
        tags: [:stream, :durable, :subject_class],
        description: "Configured JetStream stream MaxBytes limit"
      ),
      last_value("serviceradar.event_writer.consumer.stream_byte_utilization.ratio",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :stream_byte_utilization_ratio,
        tags: [:stream, :durable, :subject_class],
        description: "JetStream stream current bytes divided by configured MaxBytes"
      ),
      last_value("serviceradar.event_writer.consumer.stream_first_message_age.seconds",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :stream_first_message_age_seconds,
        tags: [:stream, :durable, :subject_class],
        unit: :second,
        description: "Age of the oldest message currently retained by the JetStream stream"
      ),
      last_value("serviceradar.event_writer.consumer.stream_max_age.seconds",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :stream_max_age_seconds,
        tags: [:stream, :durable, :subject_class],
        unit: :second,
        description: "Configured JetStream stream MaxAge in seconds"
      ),
      last_value("serviceradar.event_writer.consumer.stream_age_utilization.ratio",
        event_name: [:serviceradar, :event_writer, :consumer, :state],
        measurement: :stream_age_utilization_ratio,
        tags: [:stream, :durable, :subject_class],
        description: "Oldest retained message age divided by configured stream MaxAge"
      ),
      counter("serviceradar.event_writer.consumer.poll_error.count",
        event_name: [:serviceradar, :event_writer, :consumer, :poll_error],
        measurement: :count,
        tags: [:stream, :durable, :subject_class, :reason_class],
        description: "EventWriter JetStream consumer state poll failures"
      )
    ]
  end

  @doc """
  Returns capacity forecast source result metric definitions.
  """
  @spec capacity_forecasting_metrics() :: list()
  def capacity_forecasting_metrics do
    import Telemetry.Metrics

    event = [:serviceradar, :observability, :capacity_forecasting, :source]
    tags = [:source, :metric_class, :metric_name, :status, :skip_reason, :result]

    [
      counter("serviceradar.capacity_forecasting.source.count",
        event_name: event,
        measurement: :count,
        tags: tags,
        description: "Capacity forecasting source evaluations by status and result"
      ),
      sum("serviceradar.capacity_forecasting.source.rows.count",
        event_name: event,
        measurement: :rows,
        tags: tags,
        description: "Rows considered by capacity forecasting source evaluations"
      ),
      sum("serviceradar.capacity_forecasting.source.sample_count.count",
        event_name: event,
        measurement: :sample_count,
        tags: tags,
        description: "Usable history samples fitted by capacity forecasting source evaluations"
      )
    ]
  end

  @doc """
  Returns StatefulAlertEngine shard health metric definitions.
  """
  @spec stateful_alert_engine_metrics() :: list()
  def stateful_alert_engine_metrics do
    import Telemetry.Metrics

    [
      last_value("serviceradar.stateful_alert_engine.rules_loaded.count",
        event_name: [:serviceradar, :stateful_alert_engine, :rules_loaded],
        measurement: :count,
        tags: [:shard],
        description: "Active alert rules owned by a StatefulAlertEngine shard at its last load"
      ),
      counter("serviceradar.stateful_alert_engine.repo_unavailable.count",
        event_name: [:serviceradar, :stateful_alert_engine, :repo_unavailable],
        measurement: :count,
        tags: [:shard, :node],
        description:
          "Rule loads skipped because a StatefulAlertEngine shard runs on a repo-less node"
      )
    ]
  end

  @doc """
  Returns EventWriter per-signal counters and observability health gauges.
  """
  @spec observability_signal_metrics() :: list()
  def observability_signal_metrics do
    import Telemetry.Metrics

    [
      counter("serviceradar.event_writer.signal.count",
        event_name: [:serviceradar, :event_writer, :signal],
        measurement: :count,
        tags: [:signal, :outcome],
        description:
          "EventWriter per-signal volume (signal: logs/traces/metrics/metric_points; " <>
            "outcome: received/written/rejected/relayed)"
      ),
      sum("serviceradar.otlp_relay.spool.dropped.count",
        event_name: [:serviceradar, :otlp_relay, :spool],
        measurement: :dropped,
        tags: [:agent_id],
        description:
          "OTLP edge relay records evicted/dropped at the agent-side spool " <>
            "(delta carried on each relay TelemetryBatch)"
      ),
      last_value("serviceradar.otlp_relay.spool.queue_depth.value",
        event_name: [:serviceradar, :otlp_relay, :spool],
        measurement: :queue_depth,
        tags: [:agent_id],
        description: "OTLP edge relay spool depth reported by the most recent relay frame"
      ),
      counter("serviceradar.otlp_relay.record_rejected.count",
        event_name: [:serviceradar, :otlp_relay, :record_rejected],
        measurement: :count,
        tags: [:agent_id],
        description: "OTLP relay records dropped in core because their payload kind is unroutable"
      ),
      last_value("serviceradar.observability.root_span_ratio.ratio",
        event_name: [:serviceradar, :observability, :root_span_ratio],
        measurement: :ratio,
        description:
          "Share of spans ingested in the recent window that are root spans " <>
            "(parent_span_id IS NULL); sustained high values indicate lost parent linkage"
      ),
      counter("serviceradar.metric_envelope.decode.completed.count",
        event_name: [:serviceradar, :metric_envelope, :decode, :completed],
        measurement: :count,
        tags: [:source, :schema_version],
        tag_values: &metric_envelope_tag_values/1,
        description: "Canonical ServiceRadar metric envelope protobuf decode successes"
      ),
      sum("serviceradar.metric_envelope.decode.rows.count",
        event_name: [:serviceradar, :metric_envelope, :decode, :completed],
        measurement: :rows,
        tags: [:source, :schema_version],
        tag_values: &metric_envelope_tag_values/1,
        description: "Rows extracted from canonical ServiceRadar metric envelopes"
      ),
      distribution("serviceradar.metric_envelope.decode.duration",
        event_name: [:serviceradar, :metric_envelope, :decode, :completed],
        measurement: :duration,
        unit: {:native, :microsecond},
        tags: [:source, :schema_version],
        tag_values: &metric_envelope_tag_values/1,
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]],
        description: "Metric envelope protobuf decode and row extraction duration"
      ),
      counter("serviceradar.metric_envelope.decode.failed.count",
        event_name: [:serviceradar, :metric_envelope, :decode, :failed],
        measurement: :count,
        tags: [:source, :reason],
        tag_values: &metric_envelope_failure_tag_values/1,
        description: "Canonical ServiceRadar metric envelope protobuf decode failures"
      ),
      counter("serviceradar.metric_envelope.schema_version.count",
        event_name: [:serviceradar, :metric_envelope, :schema_version],
        measurement: :count,
        tags: [:source, :schema_version],
        tag_values: &metric_envelope_tag_values/1,
        description: "Observed canonical metric envelope schema versions"
      )
    ]
  end

  @doc """
  Returns endpoint inventory cost and volume metric definitions.
  """
  @spec endpoint_inventory_metrics() :: list()
  def endpoint_inventory_metrics do
    import Telemetry.Metrics

    ingest_event = [:serviceradar, :endpoint_inventory, :ingest, :scan]
    storage_event = [:serviceradar, :endpoint_inventory, :storage]
    table_event = [:serviceradar, :endpoint_inventory, :table]

    [
      counter("serviceradar.endpoint_inventory.ingest.scan.count",
        event_name: ingest_event,
        measurement: :count,
        tags: [:upload_reason],
        description: "Number of endpoint inventory scan reports ingested"
      ),
      counter("serviceradar.endpoint_inventory.ingest.changed_upload.count",
        event_name: ingest_event,
        measurement: :changed_upload_count,
        tags: [:upload_reason],
        description: "Number of endpoint inventory scan reports on the changed upload path"
      ),
      counter("serviceradar.endpoint_inventory.ingest.unchanged_upload.count",
        event_name: ingest_event,
        measurement: :unchanged_upload_count,
        tags: [:upload_reason],
        description: "Number of endpoint inventory scan reports on the unchanged hash path"
      ),
      counter("serviceradar.endpoint_inventory.ingest.package_rows_replaced.count",
        event_name: ingest_event,
        measurement: :package_rows_replaced_count,
        tags: [:upload_reason],
        description: "Number of endpoint inventory ingests that replaced current package rows"
      ),
      counter("serviceradar.endpoint_inventory.ingest.artifact_uploaded.count",
        event_name: ingest_event,
        measurement: :artifact_uploaded_count,
        tags: [:upload_reason],
        description: "Number of endpoint inventory ingests that stored or referenced an artifact"
      ),
      counter("serviceradar.endpoint_inventory.ingest.hash_mismatch.count",
        event_name: ingest_event,
        measurement: :package_set_hash_mismatch_count,
        tags: [:upload_reason],
        description: "Number of endpoint inventory ingests with package-set hash mismatches"
      ),
      counter("serviceradar.endpoint_inventory.ingest.reconcile_floor.count",
        event_name: ingest_event,
        measurement: :reconcile_floor_count,
        tags: [:upload_reason],
        description: "Number of endpoint inventory unchanged scans that reached reconcile floor"
      ),
      counter("serviceradar.endpoint_inventory.ingest.package_event.count",
        event_name: ingest_event,
        measurement: :package_event_count,
        tags: [:upload_reason],
        description: "Number of server-computed endpoint inventory package diff events"
      ),
      last_value("serviceradar.endpoint_inventory.storage.artifact_object.bytes",
        event_name: storage_event,
        measurement: :artifact_object_bytes,
        description: "Deduplicated endpoint SBOM artifact bytes in object storage"
      ),
      last_value("serviceradar.endpoint_inventory.storage.current_package_rows.count",
        event_name: storage_event,
        measurement: :current_package_row_count,
        description: "Current endpoint inventory package row count"
      ),
      last_value("serviceradar.endpoint_inventory.storage.current_scans.count",
        event_name: storage_event,
        measurement: :current_scan_count,
        description: "Current endpoint inventory scan row count"
      ),
      last_value("serviceradar.endpoint_inventory.storage.current_package_count_rows.count",
        event_name: storage_event,
        measurement: :current_package_count_rows,
        description: "Rows in maintained endpoint inventory package count table"
      ),
      last_value("serviceradar.endpoint_inventory.storage.current_cpe_count_rows.count",
        event_name: storage_event,
        measurement: :current_cpe_count_rows,
        description: "Rows in maintained endpoint inventory CPE count table"
      ),
      last_value("serviceradar.endpoint_inventory.storage.recent_changed.ratio",
        event_name: storage_event,
        measurement: :recent_changed_ratio,
        description:
          "Ratio of recent endpoint inventory reports that used the changed upload path"
      ),
      last_value("serviceradar.endpoint_inventory.storage.recent_unchanged.ratio",
        event_name: storage_event,
        measurement: :recent_unchanged_ratio,
        description:
          "Ratio of recent endpoint inventory reports that used the unchanged hash path"
      ),
      last_value("serviceradar.endpoint_inventory.table.live_rows.count",
        event_name: table_event,
        measurement: :live_rows,
        tags: [:table, :table_kind],
        description: "Postgres live row estimate for endpoint inventory tables"
      ),
      last_value("serviceradar.endpoint_inventory.table.dead_rows.count",
        event_name: table_event,
        measurement: :dead_rows,
        tags: [:table, :table_kind],
        description: "Postgres dead row estimate for endpoint inventory tables"
      ),
      last_value("serviceradar.endpoint_inventory.table.autovacuum_lag.seconds",
        event_name: table_event,
        measurement: :autovacuum_lag_seconds,
        tags: [:table, :table_kind],
        description: "Seconds since last autovacuum/vacuum for endpoint inventory tables"
      ),
      last_value("serviceradar.endpoint_inventory.table.compression_lag.seconds",
        event_name: table_event,
        measurement: :compression_lag_seconds,
        tags: [:table, :table_kind],
        description: "Oldest uncompressed Timescale chunk age for endpoint inventory history"
      ),
      last_value("serviceradar.endpoint_inventory.table.uncompressed_chunks.count",
        event_name: table_event,
        measurement: :uncompressed_chunk_count,
        tags: [:table, :table_kind],
        description: "Uncompressed Timescale chunk count for endpoint inventory history"
      )
    ]
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
      {__MODULE__, :measure_active_agents, []},
      {ServiceRadar.Inventory.EndpointInventoryTelemetry, :measure_cost_volume, []}
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

  defp metric_envelope_tag_values(metadata) do
    %{
      source: stringify(metadata[:source], "unknown"),
      schema_version: stringify(metadata[:schema_version], "unknown")
    }
  end

  defp metric_envelope_failure_tag_values(metadata) do
    %{
      source: stringify(metadata[:source], "unknown"),
      reason: stringify(metadata[:reason], "unknown")
    }
  end

  defp stringify(nil, default), do: default
  defp stringify("", default), do: default
  defp stringify(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value, _default) when is_binary(value), do: value
  defp stringify(value, _default), do: to_string(value)

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
