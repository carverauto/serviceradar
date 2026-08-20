defmodule ServiceRadar.Observability.DatasetSnapshotPruneTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.DataRetentionWorker
  alias ServiceRadar.Observability.DatasetSnapshotPrune
  alias ServiceRadar.Observability.NetflowOuiDatasetSnapshot
  alias ServiceRadar.Observability.NetflowProviderDatasetSnapshot

  @prune_path "lib/serviceradar/observability/dataset_snapshot_prune.ex"
  @worker_path "lib/serviceradar/observability/data_retention_worker.ex"
  @snapshot_resource_path "lib/serviceradar/observability/netflow_dataset_snapshot_resource.ex"

  test "rejects unknown snapshot tables" do
    assert {:error, {:unknown_snapshot_table, "public.not_a_table"}} =
             DatasetSnapshotPrune.run("public.not_a_table", "netflow_provider_cidrs")
  end

  test "rejects mismatched entry tables" do
    assert {:error, {:entry_table_mismatch, "netflow_provider_cidrs", "netflow_oui_prefixes"}} =
             DatasetSnapshotPrune.run(
               "netflow_provider_dataset_snapshots",
               "netflow_oui_prefixes"
             )
  end

  test "defaults keep one inactive snapshot and a two-day floor" do
    cfg = DatasetSnapshotPrune.config(keep_last: 1, retention_days: 2)

    assert cfg[:keep_last] == 1
    assert cfg[:retention_days] == 2
    assert cfg[:snapshot_limit] == 8
  end

  test "ash resources schedule an hourly prune action" do
    source = File.read!(@snapshot_resource_path)

    assert source =~ "extensions: [AshOban]"
    assert source =~ "schedule :prune_inactive, \"37 * * * *\""
    assert source =~ "action :prune_inactive"
    assert source =~ "queue :maintenance"
    assert source =~ "DatasetSnapshotPrune.run"

    Code.ensure_loaded!(NetflowProviderDatasetSnapshot)
    Code.ensure_loaded!(NetflowOuiDatasetSnapshot)

    assert function_exported?(NetflowProviderDatasetSnapshot, :prune_inactive, 0) or
             function_exported?(NetflowProviderDatasetSnapshot, :prune_inactive, 1) or
             function_exported?(NetflowProviderDatasetSnapshot, :prune_inactive, 2)

    assert function_exported?(NetflowOuiDatasetSnapshot, :prune_inactive, 0) or
             function_exported?(NetflowOuiDatasetSnapshot, :prune_inactive, 1) or
             function_exported?(NetflowOuiDatasetSnapshot, :prune_inactive, 2)
  end

  test "nightly retention worker delegates snapshot cleanup to the batch pruner" do
    worker = File.read!(@worker_path)
    prune = File.read!(@prune_path)

    assert worker =~ "DatasetSnapshotPrune.run"
    assert worker =~ "netflow_provider_dataset_snapshots"
    assert worker =~ "netflow_provider_cidrs"
    assert worker =~ "netflow_oui_dataset_snapshots"
    assert worker =~ "@default_dataset_snapshot_keep_last 1"
    assert worker =~ "@default_dataset_snapshot_retention_days 2"
    assert prune =~ "row_number() OVER (ORDER BY fetched_at DESC NULLS LAST)"
    assert prune =~ "is_active = FALSE"
    refute worker =~ "AND is_active = FALSE"
  end

  test "data retention worker module still exists for the nightly cron" do
    Code.ensure_loaded!(DataRetentionWorker)
    assert function_exported?(DataRetentionWorker, :perform, 1)
  end
end
