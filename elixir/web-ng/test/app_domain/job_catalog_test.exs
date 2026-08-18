defmodule ServiceRadarWebNG.JobCatalogTest.FakeIntegrationSource do
  @moduledoc false

  def list_by_type(:armis, actor: _actor) do
    {:ok,
     [
       %{
         id: "source-1",
         name: "Primary Armis",
         northbound_last_run_at: ~U[2026-04-13 18:00:00Z]
       }
     ]}
  end
end

defmodule ServiceRadarWebNG.JobCatalogTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Inventory.DeviceHostnameRdnsSettings.Scheduler
  alias ServiceRadar.ObjectStore.RetentionWorker, as: ObjectStoreRetentionWorker
  alias ServiceRadarWebNG.Jobs.JobCatalog

  @moduletag :db_free

  @plugin_blob_retention_worker Module.concat([
                                  "ServiceRadarWebNG",
                                  "Plugins",
                                  "BlobRetentionWorker"
                                ])

  setup do
    original = Application.get_env(:serviceradar_web_ng, :job_catalog_integration_source_module)

    Application.put_env(
      :serviceradar_web_ng,
      :job_catalog_integration_source_module,
      ServiceRadarWebNG.JobCatalogTest.FakeIntegrationSource
    )

    on_exit(fn ->
      case original do
        nil ->
          Application.delete_env(:serviceradar_web_ng, :job_catalog_integration_source_module)

        value ->
          Application.put_env(:serviceradar_web_ng, :job_catalog_integration_source_module, value)
      end
    end)

    :ok
  end

  test "manual_jobs exposes source-specific Armis northbound entries" do
    job = Enum.find(JobCatalog.manual_jobs(), &(&1.id == "manual:armis_northbound:source-1"))

    assert job.id == "manual:armis_northbound:source-1"
    assert job.name == "Armis northbound: Primary Armis"
    assert job.source == :manual
    assert job.cron == "manual"
    assert job.queue == :integrations
    assert job.worker == ArmisNorthboundRunWorker
    assert job.last_run_at == ~U[2026-04-13 18:00:00Z]
    assert job.args_filter == %{"integration_source_id" => "source-1"}
    assert job.integration_source_id == "source-1"
  end

  test "manual_jobs exposes object store retention maintenance entries" do
    jobs = JobCatalog.manual_jobs()

    assert release_job = Enum.find(jobs, &(&1.id == "manual:object_store_release_retention"))
    assert release_job.name == "Object store release retention"
    assert release_job.source == :manual
    assert release_job.cron == "manual"
    assert release_job.queue == :maintenance
    assert release_job.worker == ObjectStoreRetentionWorker
    assert release_job.args_filter == %{"manual" => true}

    assert plugin_job = Enum.find(jobs, &(&1.id == "manual:plugin_blob_retention"))
    assert plugin_job.name == "Plugin blob retention"
    assert plugin_job.source == :manual
    assert plugin_job.cron == "manual"
    assert plugin_job.queue == :web_maintenance
    assert plugin_job.worker == @plugin_blob_retention_worker
    assert plugin_job.args_filter == %{"manual" => true}
  end

  test "get_job can resolve manual Armis entries from the unified catalog" do
    assert {:ok, job} = JobCatalog.get_job("manual:armis_northbound:source-1")
    assert job.source == :manual
    assert job.integration_source_id == "source-1"
  end

  test "get_job can resolve manual retention entries from the unified catalog" do
    assert {:ok, release_job} = JobCatalog.get_job("manual:object_store_release_retention")
    assert release_job.source == :manual
    assert release_job.worker == ObjectStoreRetentionWorker

    assert {:ok, plugin_job} = JobCatalog.get_job("manual:plugin_blob_retention")
    assert plugin_job.source == :manual
    assert plugin_job.worker == @plugin_blob_retention_worker
  end

  test "ash_oban hostname rDNS catalog entry points Run at the scheduler" do
    job =
      Enum.find(
        JobCatalog.ash_oban_jobs(),
        &(&1.resource == ServiceRadar.Inventory.DeviceHostnameRdnsSettings)
      )

    assert job
    assert job.worker == ServiceRadar.Inventory.DeviceHostnameRdnsSettings.Worker
    assert job.scheduler == Scheduler

    assert JobCatalog.ash_oban_trigger_module(job) ==
             Scheduler
  end

  test "trigger_job delegates manual Armis entries to the worker entrypoint" do
    job = Enum.find(JobCatalog.manual_jobs(), &(&1.id == "manual:armis_northbound:source-1"))

    assert {:error, reason} = JobCatalog.trigger_job(job)
    refute reason == :no_worker
  end

  test "trigger_job delegates manual retention entries to worker entrypoints" do
    jobs = JobCatalog.manual_jobs()

    release_job = Enum.find(jobs, &(&1.id == "manual:object_store_release_retention"))
    plugin_job = Enum.find(jobs, &(&1.id == "manual:plugin_blob_retention"))

    assert {:error, release_reason} = JobCatalog.trigger_job(release_job)
    assert {:error, plugin_reason} = JobCatalog.trigger_job(plugin_job)

    refute release_reason == :no_worker
    refute plugin_reason == :no_worker
  end

  @tag :db_free
  test "workers whose last segment is Worker get a parent-module name and copy" do
    capacity =
      JobCatalog.worker_label(ServiceRadar.Observability.CapacityForecasting.Worker)

    assert capacity.name == "Capacity forecasting"
    assert capacity.description =~ "capacity forecast"
    refute capacity.name == ""
    refute capacity.description == "No description available"

    seasonal =
      JobCatalog.worker_label(ServiceRadar.Observability.SeasonalDisposition.Worker)

    assert seasonal.name == "Seasonal disposition"
    assert seasonal.description =~ "seasonal"
    refute seasonal.name == ""
    refute seasonal.description == "No description available"
  end

  @tag :db_free
  test "workers with a descriptive last segment keep a humanized name" do
    label =
      JobCatalog.worker_label(ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer)

    assert label.name == "Edge baseline producer"
    assert is_binary(label.description) and label.description != ""
    refute label.description == "No description available"
  end
end
