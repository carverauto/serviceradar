defmodule ServiceRadarWebNGWeb.SRQL.WarehouseQueryInventoryTest do
  @moduledoc """
  Every chart query the product's Elixir query builders send to a warehouse-served entity has a
  matching shape in the StarRocks-vs-CNPG parity inventory
  (`integration_tests/srql_parity/inventory.json`), so the parity harness has compared that
  translation on both backends (openspec change extend-starrocks-to-all-telemetry, task 1.5).

  The builders are driven through their public functions. A loader that takes an SRQL module is
  handed `CapturingSRQL`, which records each query and answers with no rows; a pure builder is
  called directly. `ServiceRadar.Analytics.StarRocks.Readers.dataset_for_entity/1` decides which
  queries are warehouse-served. Row listings (no `bucket`/`agg`/`series`/`stats`/`rollup_stats`)
  are out of scope, as they are for the dashboard definitions the Rust unit tier checks.

  Queries are matched by shape, with the normalization `ServiceRadarWebNG.SRQLParityShape` ports
  from `integration_tests/srql_parity/src/shape.rs`. The first test pins the port to the Rust
  definition through `shape_examples.json`, which the Rust unit tier asserts too.

  When the coverage test fails, add an inventory entry with the reported shape and run the
  parity database tier (`//integration_tests/srql_parity:parity_test`) to see whether the
  backends agree on it.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Observability.AnomalyDisposition.PeakProfile
  alias ServiceRadar.Observability.CapacityForecasting.Source, as: CapacitySource
  alias ServiceRadar.Observability.FlowEndpointScan
  alias ServiceRadar.Observability.NetflowSecurityRefreshWorker
  alias ServiceRadar.Observability.SeasonalDisposition.Source, as: SeasonalSource
  alias ServiceRadarWebNG.SRQLParityShape, as: Shape
  alias ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSummary, as: DashboardNetflowSummary
  alias ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic
  alias ServiceRadarWebNGWeb.DashboardLive.Window
  alias ServiceRadarWebNGWeb.DeviceLive.FlowData
  alias ServiceRadarWebNGWeb.DeviceLive.ICMPData
  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Telemetry
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics
  alias ServiceRadarWebNGWeb.EventLive.AnomalyMetricQueries
  alias ServiceRadarWebNGWeb.Flows.AttributedLive
  alias ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery
  alias ServiceRadarWebNGWeb.LogLive.NetflowPanelQueries
  alias ServiceRadarWebNGWeb.LogLive.NetflowSankey
  alias ServiceRadarWebNGWeb.LogLive.NetflowSummary
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Config, as: VisualizeConfig
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery
  alias ServiceRadarWebNGWeb.ObservabilityHealthLive.Index, as: ObservabilityHealth
  alias ServiceRadarWebNGWeb.SRQL.WarehouseQueryInventoryTest
  alias ServiceRadarWebNGWeb.Stats.Query, as: StatsQuery

  @moduletag :db_free

  @table :warehouse_query_inventory_test_queries
  @device "sr:host-01"
  @devices ["sr:host-01", "sr:host-02"]
  @scope %{permissions: MapSet.new(["observability.metrics.view", "observability.flows.view"])}
  @flows_base "in:flows time:last_1h"

  defmodule CapturingSRQL do
    @moduledoc false
    # The web-ng SRQL module contract (`ServiceRadarWebNG.SRQL.query/2`).
    def query(query, _opts) do
      WarehouseQueryInventoryTest.record(query)
      {:ok, %{"results" => [], "pagination" => %{}}}
    end
  end

  defmodule CapturingRunner do
    @moduledoc false
    # The core runner contract (`ServiceRadar.Observability.SRQLRunner`).
    def query(query, _opts) do
      WarehouseQueryInventoryTest.record(query)
      {:ok, []}
    end

    def query_page(query, _opts) do
      WarehouseQueryInventoryTest.record(query)
      {:ok, %{rows: [], next_cursor: nil}}
    end
  end

  @doc false
  def record(query), do: :ets.insert(@table, {System.unique_integer([:monotonic]), query})

  setup do
    :ets.new(@table, [:named_table, :public, :ordered_set])
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, CapturingSRQL)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :srql_module, previous) end)
    :ok
  end

  test "the Elixir shape port agrees with the Rust definition on every shared example" do
    examples = read_json!("shape_examples.json")

    for {spelling, canonical} <- examples["entities"] do
      assert Shape.canonical_entity(spelling) == canonical, "entity #{inspect(spelling)}"

      assert is_nil(Readers.dataset_for_entity(spelling)) == is_nil(canonical),
             "Readers.dataset_for_entity/1 and the parity table disagree on #{inspect(spelling)}"
    end

    for example <- examples["shapes"] do
      shape = Shape.shape_of(example["query"])
      entity = shape.entity && Shape.canonical_entity(shape.entity)

      assert entity == example["entity"], "entity of #{example["query"]}"
      assert Shape.chart?(shape) == example["chart"], "chart? of #{example["query"]}"
      assert shape.clauses == example["clauses"], "clauses of #{example["query"]}"
      assert shape.modifiers == MapSet.new(example["modifiers"]), "modifiers of #{example["query"]}"
    end
  end

  test "every builder this test drives produces queries" do
    empty = for {builder, drive} <- drivers(), drive.() == [], do: builder
    assert empty == [], "these builders produced no query, so nothing of theirs is checked: #{inspect(empty)}"
  end

  test "every warehouse chart query the product's builders produce has a parity inventory entry" do
    inventory = inventory_shapes()

    checked =
      for {builder, drive} <- drivers(),
          query <- drive.(),
          entity = Readers.entity_for_query(query),
          is_binary(entity) and Readers.dataset_for_entity(entity) != nil,
          shape = Shape.shape_of(query),
          Shape.chart?(shape) do
        canonical = Shape.canonical_entity(entity)

        assert canonical,
               "#{inspect(entity)} is warehouse-served (Readers.dataset_for_entity/1) but has no canonical " <>
                 "parity entity; add it to shape_examples.json and both shape implementations"

        {builder, query, canonical, shape}
      end

    assert checked != [], "no builder produced a warehouse chart query"

    missing =
      checked
      |> Enum.reject(fn {_builder, _query, entity, shape} -> covered?(inventory, entity, shape) end)
      |> Enum.uniq_by(fn {_builder, query, _entity, _shape} -> query end)

    report =
      Enum.map_join(missing, "\n", fn {builder, query, entity, shape} ->
        "  #{builder}\n      #{Shape.describe(%{shape | entity: entity})}\n      #{query}"
      end)

    assert missing == [],
           "#{length(missing)} warehouse chart queries have no inventory entry of the same shape " <>
             "(integration_tests/srql_parity/inventory.json):\n#{report}"
  end

  # Each builder, and how to make it produce its queries.
  defp drivers do
    flows_window = Window.resolve("last_1h", "netflow")

    [
      {"CapacityForecasting.Source.defaults/1",
       fn -> Enum.map(CapacitySource.defaults(include_sources: :all), & &1.query) end},
      {"SeasonalDisposition.Source.defaults/1", fn -> Enum.map(SeasonalSource.defaults(), & &1.query) end},
      {"AnomalyDisposition.PeakProfile.fetcher/2",
       fn ->
         fetch = PeakProfile.fetcher(CapturingRunner)
         capture(fn -> fetch.(%{metric_class: "sysmon.cpu", metric_name: "cpu.usage_percent"}) end)
       end},
      {"FlowEndpointScan.discover/4",
       fn -> capture(fn -> FlowEndpointScan.discover(3_600, 100, CapturingRunner) end) end},
      {"NetflowSecurityRefreshWorker port-scan and port-anomaly queries",
       fn ->
         [
           NetflowSecurityRefreshWorker.port_scan_query(300, 200)
           | Map.values(NetflowSecurityRefreshWorker.port_anomaly_queries(604_800, 300, 200))
         ]
       end},
      {"DashboardLive.Data.NetflowSummary.srql_query/1", fn -> [DashboardNetflowSummary.srql_query(flows_window)] end},
      {"DashboardLive.Data.NetflowTraffic.srql_query/1", fn -> [NetflowTraffic.srql_query(flows_window)] end},
      {"DeviceLive.FlowData.load_device_flow_stats/3",
       fn -> capture(fn -> FlowData.load_device_flow_stats(CapturingSRQL, @device, @scope) end) end},
      {"DeviceLive.ICMPData.load/4 and load_availability/4",
       fn ->
         opts = [time_range: "last_1h", bucket: "5m", aggregate: :avg, limit: 40]

         capture(fn ->
           ICMPData.load(CapturingSRQL, @devices, @scope, opts)
           ICMPData.load_availability(CapturingSRQL, @devices, @scope, opts)
         end)
       end},
      {"DeviceLive.IndexData.Telemetry.metric_presence/2 and icmp_sparklines/2",
       fn ->
         devices = Enum.map(@devices, &%{"uid" => &1})

         capture(fn ->
           Telemetry.metric_presence(@scope, devices)
           Telemetry.icmp_sparklines(@scope, devices)
         end)
       end},
      {"DeviceLive.InterfaceData.load_interfaces/3",
       fn -> capture(fn -> InterfaceData.load_interfaces(CapturingSRQL, @device, @scope) end) end},
      {"InterfaceLive.MetricsQuery.build_snmp_counter_query/4",
       fn -> [MetricsQuery.build_snmp_counter_query(@device, 3, ["ifHCInOctets", "ifHCOutOctets"], [])] end},
      {"DeviceLive.SysmonMetrics.load_metric_sections/4 and load_process_metrics/3",
       fn ->
         filters = [~s|uid:"#{@device}"|]

         capture(fn ->
           SysmonMetrics.load_metric_sections(CapturingSRQL, filters, @scope, time_range: "last_24h", thresholds: %{})
           SysmonMetrics.load_process_metrics(CapturingSRQL, filters, @scope)
         end)
       end},
      {"EventLive.AnomalyMetricQueries.variants/5",
       fn ->
         AnomalyMetricQueries.variants(@device, 3, "ifHCInOctets", true, "last_24h") ++
           AnomalyMetricQueries.variants(@device, nil, "cpu.usage_percent", false, "last_24h")
       end},
      {"Flows.AttributedLive.summary_query/1", fn -> [AttributedLive.summary_query("last_24h")] end},
      {"ObservabilityHealthLive.Index.health_query/0", fn -> [ObservabilityHealth.health_query()] end},
      {"LogLive.NetflowPanelQueries.query/3 (every panel)",
       fn ->
         Enum.map(NetflowPanelQueries.panels(), &NetflowPanelQueries.query(&1, @flows_base, limit: 10, bucket: "5m"))
       end},
      {"LogLive.NetflowSummary.query/1 and NetflowSankey.query/2",
       fn -> [NetflowSummary.query(@flows_base) | Enum.map([16, 24], &NetflowSankey.query(@flows_base, &1))] end},
      {"NetflowVisualize.Query.load_sankey/4 (every prefix and Visualize.Config dimension)",
       fn ->
         capture(fn -> Enum.each(sankey_options(), &NFQuery.load_sankey(CapturingSRQL, @flows_base, @scope, &1)) end)
       end},
      {"Stats.Query rollup and count queries",
       fn ->
         [
           StatsQuery.logs_severity(),
           StatsQuery.logs_severity(service_name: ["svc-alpha", "svc-beta"]),
           StatsQuery.logs_severity_count_query(:error),
           StatsQuery.logs_severity_count_query([:error, :warning], service_name: "svc-alpha"),
           StatsQuery.traces_summary(),
           StatsQuery.metrics_red(),
           StatsQuery.otel_service_count("logs"),
           StatsQuery.anomaly_findings(),
           StatsQuery.services_availability()
         ]
       end}
    ]
  end

  defp sankey_options do
    dims = fn options -> Enum.map(options, fn {_label, value} -> value end) end

    for prefix <- [16, 24, 32],
        src <- dims.(VisualizeConfig.sankey_src_dims()),
        mid <- dims.(VisualizeConfig.sankey_mid_dims()),
        dst <- dims.(VisualizeConfig.sankey_dst_dims()) do
      [prefix: prefix, dims: [src, mid, dst], max_edges: 12]
    end
  end

  # Runs `fun` and returns the queries it sent through a capturing SRQL module, from any process.
  defp capture(fun) do
    :ets.delete_all_objects(@table)
    fun.()
    @table |> :ets.tab2list() |> Enum.map(fn {_seq, query} -> query end)
  end

  defp covered?(inventory, entity, shape) do
    Enum.any?(inventory, fn {entry_entity, entry_shape} ->
      entry_entity == entity and Shape.covered_by?(shape, entry_shape)
    end)
  end

  defp inventory_shapes do
    for %{"query" => query} <- read_json!("inventory.json")["entries"] do
      shape = Shape.shape_of(query)
      {Shape.canonical_entity(shape.entity), shape}
    end
  end

  # A declared Bazel input of this test (//integration_tests/srql_parity), read as data.
  defp read_json!(name) do
    relative = "integration_tests/srql_parity/" <> name

    path =
      Enum.find(
        [
          Path.expand("../../../../../" <> relative, __DIR__),
          Path.join([System.get_env("TEST_SRCDIR") || "", System.get_env("TEST_WORKSPACE") || "_main", relative])
        ],
        &File.exists?/1
      ) || flunk("#{relative} was not staged; declare //integration_tests/srql_parity:#{name} as test data")

    path |> File.read!() |> Jason.decode!()
  end
end
