defmodule ServiceRadarWebNGWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("serviceradar_web_ng.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("serviceradar_web_ng.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("serviceradar_web_ng.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("serviceradar_web_ng.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("serviceradar_web_ng.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Ash Framework Metrics
      summary("ash.action.stop.duration",
        tags: [:domain, :resource, :action, :action_type],
        unit: {:native, :millisecond},
        description: "Duration of Ash resource actions"
      ),
      counter("ash.action.stop.count",
        tags: [:domain, :resource, :action, :action_type],
        description: "Count of Ash resource actions"
      ),
      summary("ash.query.stop.duration",
        tags: [:domain, :resource],
        unit: {:native, :millisecond},
        description: "Duration of Ash queries"
      ),
      counter("ash.query.stop.count",
        tags: [:domain, :resource],
        description: "Count of Ash queries"
      ),

      # SRQL Metrics
      summary("serviceradar.srql.query.duration",
        tags: [:path, :entity, :status],
        unit: {:native, :millisecond},
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
      last_value("serviceradar.cluster.pollers.count",
        description: "Number of registered pollers in Horde"
      ),
      last_value("serviceradar.cluster.agents.count",
        description: "Number of registered agents in Horde"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # Cluster health measurements
      {__MODULE__, :measure_cluster_health, []}
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

    # Poller registry count (from Horde)
    poller_count =
      try do
        ServiceRadar.ClusterHealth.get_health() |> Map.get(:poller_count, 0)
      catch
        :exit, _ -> 0
      end

    :telemetry.execute(
      [:serviceradar, :cluster, :pollers],
      %{count: poller_count},
      %{}
    )

    # Agent registry count (from Horde)
    agent_count =
      try do
        ServiceRadar.ClusterHealth.get_health() |> Map.get(:agent_count, 0)
      catch
        :exit, _ -> 0
      end

    :telemetry.execute(
      [:serviceradar, :cluster, :agents],
      %{count: agent_count},
      %{}
    )
  end
end
