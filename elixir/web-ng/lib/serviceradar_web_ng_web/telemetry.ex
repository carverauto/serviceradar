defmodule ServiceRadarWebNGWeb.Telemetry do
  @moduledoc false
  use Supervisor

  import Telemetry.Metrics

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Storage.StorageUsageReports
  alias ServiceRadar.Telemetry, as: ServiceRadarTelemetry
  alias ServiceRadarWebNG.TenantUsage

  @prometheus_reporter :serviceradar_web_ng_prometheus_metrics
  @duration_buckets_ms [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  @spec prometheus_reporter() :: atom()
  def prometheus_reporter, do: @prometheus_reporter

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: @prometheus_reporter, start_async: false}
    ]

    children =
      if Application.get_env(:serviceradar_web_ng, :telemetry_poller_enabled, true) do
        children ++
          [
            # Telemetry poller will execute the given period measurements
            # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
            {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
            # Add reporters as children of your supervision tree.
            # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
          ]
      else
        children
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      last_value("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond},
        description: "Latest Phoenix endpoint start system time"
      ),
      duration_distribution("phoenix.endpoint.stop.duration",
        description: "Duration of Phoenix endpoint requests"
      ),
      last_value("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond},
        description: "Latest Phoenix router dispatch start system time"
      ),
      duration_distribution("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        description: "Duration of Phoenix router dispatches that raised exceptions"
      ),
      duration_distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        description: "Duration of Phoenix router dispatches"
      ),
      duration_distribution("phoenix.socket_connected.duration",
        description: "Duration of Phoenix socket connection setup"
      ),
      sum("phoenix.socket_drain.count"),
      duration_distribution("phoenix.channel_joined.duration",
        description: "Duration of Phoenix channel joins"
      ),
      duration_distribution("phoenix.channel_handled_in.duration",
        tags: [:event],
        description: "Duration of Phoenix channel event handling"
      ),

      # Database Metrics
      duration_distribution("serviceradar_web_ng.repo.query.total_time",
        description: "The sum of the other measurements"
      ),
      duration_distribution("serviceradar_web_ng.repo.query.decode_time",
        description: "The time spent decoding the data received from the database"
      ),
      duration_distribution("serviceradar_web_ng.repo.query.query_time",
        description: "The time spent executing the query"
      ),
      duration_distribution("serviceradar_web_ng.repo.query.queue_time",
        description: "The time spent waiting for a database connection"
      ),
      duration_distribution("serviceradar_web_ng.repo.query.idle_time",
        description: "The time the connection spent waiting before being checked out for the query"
      ),

      # Ash Framework Metrics
      duration_distribution("ash.action.stop.duration",
        tags: [:domain, :resource, :action, :action_type],
        description: "Duration of Ash resource actions"
      ),
      counter("ash.action.stop.count",
        tags: [:domain, :resource, :action, :action_type],
        description: "Count of Ash resource actions"
      ),
      duration_distribution("ash.query.stop.duration",
        tags: [:domain, :resource],
        description: "Duration of Ash queries"
      ),
      counter("ash.query.stop.count",
        tags: [:domain, :resource],
        description: "Count of Ash queries"
      ),

      # SRQL Metrics
      duration_distribution("serviceradar.srql.query.duration",
        tags: [:path, :entity, :status],
        description: "Duration of SRQL queries"
      ),
      counter("serviceradar.srql.query.count",
        tags: [:path, :entity, :status],
        description: "Count of SRQL queries"
      ),

      # API Error Metrics
      counter("serviceradar.api.error.count",
        tags: [:status, :path, :method],
        description: "Count of API errors by status code"
      ),

      # Cluster Metrics
      last_value("serviceradar.cluster.nodes.count",
        description: "Number of connected ERTS nodes"
      ),
      last_value("serviceradar.cluster.gateways.count",
        description: "Number of registered gateways in Horde"
      ),
      last_value("serviceradar.cluster.agents.count",
        description: "Number of registered agents in Horde"
      ),
      last_value("serviceradar.tenant_usage.managed_devices.count",
        description: "Current count of non-deleted inventory devices known to this deployment runtime"
      ),
      last_value("serviceradar.tenant_usage.collectors.count",
        tags: [:collector_type],
        description: "Current count of non-revoked collector packages in this deployment, tagged by collector type"
      ),
      last_value("serviceradar.managed_devices",
        description: "Hosted-runtime contract gauge for current managed device count"
      ),
      last_value("serviceradar.collectors.total",
        description: "Hosted-runtime contract gauge for current collector package count"
      ),
      last_value("serviceradar.leaf_nodes.total",
        description: "Hosted-runtime contract gauge for current NATS leaf node count"
      ),

      # Camera Recording Storage Gauges (F.6)
      last_value("serviceradar.camera_recording.object_used_bytes",
        description: "Current camera recording archive object bytes used"
      ),
      last_value("serviceradar.camera_recording.object_hard_limit_bytes",
        description: "Current camera recording archive object hard limit bytes (0 when unlimited)"
      ),
      last_value("serviceradar.camera_recording.object_cutoff_days",
        description: "Current calculated camera recording archive common age cutoff T in days (-1 when infinite)"
      ),
      last_value("serviceradar.camera_recording.object_held_bytes",
        description: "Current camera recording archive bytes pinned by active holds"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ] ++
      ServiceRadarTelemetry.camera_relay_metrics() ++
      ServiceRadarTelemetry.prefix_tag_metrics() ++
      ServiceRadarTelemetry.audit_metrics()
  end

  defp duration_distribution(metric_name, opts) do
    distribution(
      metric_name,
      Keyword.merge(
        [
          unit: {:native, :millisecond},
          reporter_options: [buckets: @duration_buckets_ms]
        ],
        opts
      )
    )
  end

  defp periodic_measurements do
    [
      # Cluster health measurements
      {__MODULE__, :measure_cluster_health, []},
      {__MODULE__, :measure_tenant_usage, []},
      {__MODULE__, :emit_camera_recording_storage_gauges, []}
    ]
  end

  @doc """
  Emits cluster health metrics periodically.
  Called by telemetry_poller to gather Horde registry and cluster stats.
  """
  def measure_cluster_health do
    # Cluster node count
    node_count = length(Node.list()) + 1

    :telemetry.execute(
      [:serviceradar, :cluster, :nodes],
      %{count: node_count},
      %{}
    )

    # Gateway and agent registry counts (via ClusterStatus which works from any node)
    # web-ng doesn't run ClusterHealth - those only run on core-elx
    {gateway_count, agent_count} =
      try do
        status = ServiceRadar.Cluster.ClusterStatus.get_status()
        {status.gateway_count, status.agent_count}
      catch
        :exit, _ -> {0, 0}
      end

    :telemetry.execute(
      [:serviceradar, :cluster, :gateways],
      %{count: gateway_count},
      %{}
    )

    :telemetry.execute(
      [:serviceradar, :cluster, :agents],
      %{count: agent_count},
      %{}
    )
  end

  @doc """
  Emits plan-relevant usage metrics based on runtime-local inventory data.
  """
  def measure_tenant_usage do
    managed_device_count = TenantUsage.managed_device_count()

    :telemetry.execute(
      [:serviceradar, :tenant_usage, :managed_devices],
      %{count: managed_device_count},
      %{}
    )

    :telemetry.execute(
      [:serviceradar],
      %{managed_devices: managed_device_count},
      %{}
    )

    collector_counts = TenantUsage.collector_counts_by_type()
    collector_total = collector_counts |> Map.values() |> Enum.sum()

    Enum.each(TenantUsage.collector_usage_types(), fn collector_type ->
      :telemetry.execute(
        [:serviceradar, :tenant_usage, :collectors],
        %{count: Map.get(collector_counts, collector_type, 0)},
        %{collector_type: collector_type}
      )
    end)

    :telemetry.execute(
      [:serviceradar, :collectors],
      %{total: collector_total},
      %{}
    )

    :telemetry.execute(
      [:serviceradar, :leaf_nodes],
      %{total: TenantUsage.leaf_node_count()},
      %{}
    )
  end

  @doc """
  Emits current-day camera recording object storage gauges (`F.6`, `design.md` `F5`).
  Safe in `:db_free` environments: rescues/catches repository unavailability so
  `/metrics` never crashes.
  """
  @spec emit_camera_recording_storage_gauges(keyword()) :: :ok
  def emit_camera_recording_storage_gauges(opts \\ []) when is_list(opts) do
    gauges = read_camera_recording_storage_gauges(opts)

    :telemetry.execute(
      [:serviceradar, :camera_recording],
      %{
        object_used_bytes: normalize_gauge_bytes(gauges[:used_bytes] || gauges[:object_used_bytes]),
        object_hard_limit_bytes: normalize_gauge_bytes(gauges[:hard_limit_bytes] || gauges[:object_hard_limit_bytes]),
        object_cutoff_days: normalize_gauge_cutoff_days(gauges[:cutoff_days] || gauges[:object_cutoff_days]),
        object_held_bytes: normalize_gauge_bytes(gauges[:held_bytes] || gauges[:object_held_bytes])
      },
      %{}
    )
  end

  defp read_camera_recording_storage_gauges(opts) do
    case Keyword.get(opts, :gauges) do
      %{} = supplied ->
        supplied

      _ ->
        call_opts = Keyword.put_new(opts, :actor, SystemActor.system(:telemetry_storage_gauges))

        case StorageUsageReports.current_gauges(call_opts) do
          {:ok, %{} = map} -> map
          _ -> %{}
        end
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp normalize_gauge_bytes(val) when is_number(val) and val >= 0, do: trunc(val)
  defp normalize_gauge_bytes(_), do: 0

  defp normalize_gauge_cutoff_days(val) when is_number(val), do: val * 1.0
  defp normalize_gauge_cutoff_days(_), do: -1.0
end
