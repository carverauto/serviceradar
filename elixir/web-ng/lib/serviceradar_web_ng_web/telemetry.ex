defmodule ServiceRadarWebNGWeb.Telemetry do
  @moduledoc false
  use Supervisor

  import Telemetry.Metrics

  alias ServiceRadar.Telemetry, as: ServiceRadarTelemetry
  alias ServiceRadarWebNG.StorageUsage
  alias ServiceRadarWebNG.TenantUsage

  @prometheus_reporter :serviceradar_web_ng_prometheus_metrics
  @duration_buckets_ms [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  # Storage gauges run sizing/manifest SQL, so they poll on their own slower
  # cadence instead of the 10s default poller (design D10: ~once a minute).
  @storage_poller_period to_timeout(minute: 1)

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
            {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
            # Storage/retention gauges poll once a minute (design D10) so the
            # sizing and cold-manifest queries never run on the scrape path.
            {:telemetry_poller,
             measurements: storage_measurements(),
             period: @storage_poller_period,
             name: :serviceradar_web_ng_storage_poller}
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

      # Storage/retention telemetry (OpenSpec add-tiered-telemetry-offload, D10).
      # Each gauge gets its own event so per-table and global emissions never
      # fan out into metrics that lack the measurement.
      storage_gauge("serviceradar.storage.hot_bytes",
        tags: [:table],
        description: "Hot-tier hypertable total bytes per cold-registry table (hypertable_detailed_size)"
      ),
      storage_gauge("serviceradar.storage.database_bytes",
        description: "Size of the current database in bytes (pg_database_size)"
      ),
      storage_gauge("serviceradar.storage.nontelemetry_bytes",
        description: "Database bytes not attributable to cold-registry hypertables (floored at 0)"
      ),
      storage_gauge("serviceradar.storage.ingest_bytes_per_day",
        tags: [:table],
        description:
          "Trailing ingest rate per cold-registry table, from closed-chunk sizes " <>
            "(drop-immune; input to retention-horizon projection)"
      ),
      storage_gauge("serviceradar.storage.cold_bytes",
        tags: [:table],
        description: "Verified cold-tier bytes per table from the cold chunk export manifest"
      ),
      storage_gauge("serviceradar.storage.cold_rows",
        tags: [:table],
        description: "Verified cold-tier row count per table from the cold chunk export manifest"
      ),
      storage_gauge("serviceradar.storage.cold_oldest_available_seconds",
        tags: [:table],
        description: "Oldest verified cold-tier range_start per table as a unix epoch timestamp"
      ),
      storage_gauge("serviceradar.storage.frontier_lag_seconds",
        tags: [:table],
        description: "Seconds between now and the cold completeness frontier per table"
      ),
      storage_gauge("serviceradar.storage.held_chunks",
        tags: [:table],
        description: "Cold-tier manifest chunks pending or exported but not yet verified, per table"
      ),
      storage_gauge("serviceradar.storage.quarantined_chunks",
        tags: [:table],
        description: "Cold-tier manifest chunks quarantined after repeated export failures, per table"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ] ++
      ServiceRadarTelemetry.camera_relay_metrics() ++
      ServiceRadarTelemetry.prefix_tag_metrics()
  end

  # A last_value gauge with a dedicated event name matching the full metric
  # name and a fixed :value measurement, so each storage gauge is emitted
  # independently (per-table tags on some, none on others).
  #
  # `:event_name` is handed the name as a STRING rather than a hand-split list
  # of atoms. Telemetry.Metrics accepts `String.t() | :telemetry.event_name()`
  # and runs either through the same `validate_metric_or_event_name!/1` it uses
  # for the metric name, so this is the library's own parsing rather than a
  # second copy of it -- and it keeps `String.to_atom/1` out of the source,
  # which sobelow flags (DOS.StringToAtom) regardless of the argument being a
  # compile-time literal here.
  defp storage_gauge(metric_name, opts) do
    last_value(
      metric_name,
      Keyword.merge([event_name: metric_name, measurement: :value], opts)
    )
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
      {__MODULE__, :measure_tenant_usage, []}
    ]
  end

  defp storage_measurements do
    [
      {__MODULE__, :measure_storage_usage, []}
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
  Emits storage/retention tier gauges (OpenSpec add-tiered-telemetry-offload,
  design D10). Always-on gauges emit on every run; cold-tier gauges stay
  absent when the cold-tier manifest tables do not exist.
  """
  def measure_storage_usage do
    hot_bytes = StorageUsage.hot_bytes_by_table()
    database_bytes = StorageUsage.database_bytes()
    hot_total = hot_bytes |> Map.values() |> Enum.sum()

    Enum.each(hot_bytes, fn {table, bytes} ->
      emit_storage_gauge(:hot_bytes, bytes, %{table: table})
    end)

    emit_storage_gauge(:database_bytes, database_bytes)
    emit_storage_gauge(:nontelemetry_bytes, max(database_bytes - hot_total, 0))

    Enum.each(StorageUsage.ingest_bytes_per_day_by_table(), fn {table, rate} ->
      emit_storage_gauge(:ingest_bytes_per_day, rate, %{table: table})
    end)

    case StorageUsage.cold_manifest_stats() do
      :absent ->
        :ok

      stats ->
        Enum.each(stats, fn stat ->
          metadata = %{table: stat.table}

          emit_storage_gauge(:cold_bytes, stat.cold_bytes, metadata)
          emit_storage_gauge(:cold_rows, stat.cold_rows, metadata)
          emit_storage_gauge(:held_chunks, stat.held_chunks, metadata)
          emit_storage_gauge(:quarantined_chunks, stat.quarantined_chunks, metadata)

          if stat.oldest_available_seconds do
            emit_storage_gauge(:cold_oldest_available_seconds, stat.oldest_available_seconds, metadata)
          end
        end)
    end

    case StorageUsage.frontier_lag_seconds() do
      :absent ->
        :ok

      lags ->
        Enum.each(lags, fn {table, lag_seconds} ->
          emit_storage_gauge(:frontier_lag_seconds, lag_seconds, %{table: table})
        end)
    end
  end

  defp emit_storage_gauge(gauge, value, metadata \\ %{}) do
    :telemetry.execute([:serviceradar, :storage, gauge], %{value: value}, metadata)
  end
end
