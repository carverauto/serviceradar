defmodule ServiceRadarCoreElx.TelemetryTest do
  use ExUnit.Case, async: true

  test "uses a stable prometheus reporter name" do
    assert ServiceRadarCoreElx.Telemetry.prometheus_reporter() ==
             :serviceradar_core_elx_prometheus_metrics
  end

  test "exports the shared ServiceRadar telemetry metrics" do
    assert ServiceRadarCoreElx.Telemetry.metrics() == ServiceRadar.Telemetry.metrics()
  end

  test "exports prefix-tag health metrics" do
    metric_names = Enum.map(ServiceRadarCoreElx.Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :prefix_tags, :lookup, :count] in metric_names
    assert [:serviceradar, :prefix_tags, :snapshot_age, :age_seconds] in metric_names
    assert [:serviceradar, :prefix_tags, :snapshot_freshness, :known] in metric_names
    assert [:serviceradar, :prefix_tags, :import, :record_count] in metric_names
  end

  test "prometheus reporter can register the shared metric set" do
    name = :"prometheus_metrics_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             TelemetryMetricsPrometheus.Core.start_link(
               metrics: ServiceRadarCoreElx.Telemetry.metrics(),
               name: name,
               start_async: false
             )

    # start_link links the reporter to this test process. ExUnit runs on_exit
    # after the test process exits, so the link would kill the reporter before
    # the callback can stop it.
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)
  end

  test "prometheus reporter exports the identity reconciliation events it receives" do
    name = :"identity_metrics_#{System.unique_integer([:positive])}"
    instance = "telemetry-test-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             TelemetryMetricsPrometheus.Core.start_link(
               metrics: ServiceRadar.Telemetry.identity_reconciliation_metrics(),
               name: name,
               start_async: false
             )

    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    # The events as DuplicateSweep, MergeEngine, SourceRetirement and PopulationGauges emit them.
    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :run],
      %{
        merges: 2,
        errors: 0,
        blocked_components: 1,
        blocked_merges: 4,
        blocked_unchanged: 3,
        succession_merges: 1,
        succession_reviews: 0,
        successions_skipped: 0,
        successions_deferred: 0
      },
      %{status: :completed, trigger: :scheduled}
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :merge, :guard_blocked],
      %{count: 1},
      %{
        guard: :merge_cooldown,
        reason: "identifier_backfill",
        from_device_id: "sr:telemetry-test-a",
        to_device_id: "sr:telemetry-test-b"
      }
    )

    :telemetry.execute(
      [:serviceradar, :inventory, :source_population],
      %{live_records: 2, current_ids: 1, live_to_current: 2.0},
      %{partition: "default", source: "armis", source_instance: instance}
    )

    :telemetry.execute(
      [:serviceradar, :inventory, :identity_population],
      %{retired_only_records: 5, source_retired_records: 6, released_seed_shells: 7},
      %{}
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(name)
    lines = String.split(scrape, "\n")
    labels = ~s(partition="default",source="armis",source_instance="#{instance}")

    for line <- [
          ~s(serviceradar_identity_reconciler_run_count{status="completed",trigger="scheduled"} 1),
          "serviceradar_identity_reconciler_run_merges 2",
          "serviceradar_identity_reconciler_run_succession_merges 1",
          "serviceradar_identity_reconciler_run_blocked_merges 4",
          "serviceradar_identity_reconciler_run_blocked_unchanged 3",
          ~s(serviceradar_identity_reconciler_merge_guard_blocked_count{guard="merge_cooldown"} 1),
          "serviceradar_inventory_source_population_live_records{#{labels}} 2",
          "serviceradar_inventory_source_population_current_ids{#{labels}} 1",
          "serviceradar_inventory_source_population_live_to_current_ratio{#{labels}} 2.0",
          "serviceradar_inventory_identity_population_retired_only_records 5",
          "serviceradar_inventory_identity_population_source_retired_records 6",
          "serviceradar_inventory_identity_population_released_seed_shells 7"
        ] do
      assert line in lines, "#{line} is not in the scrape:\n#{scrape}"
    end

    # The merged pair is event metadata, not a label.
    refute scrape =~ "telemetry-test-a"
  end
end
