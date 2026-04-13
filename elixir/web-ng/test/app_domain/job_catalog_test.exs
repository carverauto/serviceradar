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
  alias ServiceRadarWebNG.Jobs.JobCatalog

  setup do
    original = Application.get_env(:serviceradar_web_ng, :job_catalog_integration_source_module)

    Application.put_env(
      :serviceradar_web_ng,
      :job_catalog_integration_source_module,
      ServiceRadarWebNG.JobCatalogTest.FakeIntegrationSource
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_web_ng, :job_catalog_integration_source_module)
        value -> Application.put_env(:serviceradar_web_ng, :job_catalog_integration_source_module, value)
      end
    end)

    :ok
  end

  test "manual_jobs exposes source-specific Armis northbound entries" do
    [job] = JobCatalog.manual_jobs()

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

  test "get_job can resolve manual Armis entries from the unified catalog" do
    assert {:ok, job} = JobCatalog.get_job("manual:armis_northbound:source-1")
    assert job.source == :manual
    assert job.integration_source_id == "source-1"
  end

  test "trigger_job delegates manual Armis entries to the worker entrypoint" do
    job = List.first(JobCatalog.manual_jobs())

    assert {:error, :oban_unavailable} = JobCatalog.trigger_job(job)
  end
end
